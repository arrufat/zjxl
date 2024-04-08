const std = @import("std");
const jxl = @cImport({
    @cInclude("jxl/decode.h");
    @cInclude("jxl/encode.h");
    @cInclude("jxl/resizable_parallel_runner.h");
    @cInclude("jxl/thread_parallel_runner.h");
});

pub const JxlImage = struct {
    rows: usize,
    cols: usize,
    depth: usize,
    data: []u8,
    pub fn deinit(self: JxlImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const PixelFormat = enum {
    grayscale,
    grayscale_alpha,
    rgb,
    rgb_alpha,

    pub fn has_alpha(self: PixelFormat) bool {
        return switch (self) {
            .grayscale_alpha, .rgb_alpha => true,
            .grayscale, .rgb => false,
        };
    }

    pub fn isGrayscale(self: PixelFormat) bool {
        return switch (self) {
            .grayscale, .grayscale_alpha => true,
            .rgb, .rgb_alpha => false,
        };
    }

    pub fn channels(self: PixelFormat) usize {
        return switch (self) {
            .grayscale => 1,
            .grayscale_alpha => 2,
            .rgb => 3,
            .rgb_alpha => 4,
        };
    }

    pub fn fromChannels(ch: usize) PixelFormat {
        return switch (ch) {
            1 => .grayscale,
            2 => .grayscale_alpha,
            3 => .rgb,
            4 => .rgb_alpha,
        };
    }
};

fn jxlDecoderVersion() std.SemanticVersion {
    const version = jxl.JxlDecoderVersion();
    const patch = version % 1000;
    const minor = ((version - patch) / 1000) % 1000;
    const major = version / 1000000;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn jxlEncoderVersion() std.SemanticVersion {
    const version = jxl.JxlEncoderVersion();
    const major = version / 1000000;
    const minor = (version - major * 1000000) / 1000;
    const patch = version - major * 1000000 - minor * 1000;
    return .{ .major = major, .minor = minor, .patch = patch };
}

pub fn loadJxlImage(allocator: std.mem.Allocator, filename: []const u8, image: *JxlImage) !void {
    std.debug.print("libjxl decoder: {}\n", .{jxlDecoderVersion()});
    const file = try std.fs.cwd().readFileAlloc(allocator, filename, 100 * 1024 * 1024);
    defer allocator.free(file);

    const signature = jxl.JxlSignatureCheck(file.ptr, file.len);
    if (signature != jxl.JXL_SIG_CODESTREAM and signature != jxl.JXL_SIG_CONTAINER) {
        std.log.err("JxlSignatureCheck failed\n", .{});
        return;
    }

    const runner = jxl.JxlResizableParallelRunnerCreate(null);
    defer jxl.JxlResizableParallelRunnerDestroy(runner);
    const dec: ?*jxl.JxlDecoder = jxl.JxlDecoderCreate(null);
    defer jxl.JxlDecoderDestroy(dec);
    if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderSubscribeEvents(
        dec,
        jxl.JXL_DEC_BASIC_INFO | jxl.JXL_DEC_FULL_IMAGE,
    )) {
        std.log.err("JxlDecoderSubscribeEvents failed\n", .{});
        return;
    }

    if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderSetInput(dec, file.ptr, file.len)) {
        std.debug.print("JxlDecoderSetInput failed\n", .{});
        jxl.JxlDecoderCloseInput(dec);
        return;
    }
    jxl.JxlDecoderCloseInput(dec);
    var basic_info: jxl.JxlBasicInfo = undefined;
    var format: jxl.JxlPixelFormat = .{
        .num_channels = 4,
        .data_type = jxl.JXL_TYPE_UINT8,
        .endianness = jxl.JXL_NATIVE_ENDIAN,
        .@"align" = 0,
    };
    var pixels = std.ArrayList(u8).init(allocator);
    defer pixels.deinit();
    while (true) {
        const status = jxl.JxlDecoderProcessInput(dec);
        if (status == jxl.JXL_DEC_ERROR) {
            std.log.err("JxlDecoderProcessInput failed\n", .{});
            return;
        } else if (status == jxl.JXL_DEC_NEED_MORE_INPUT) {
            std.log.err("JxlDecoderProcessInput expected more input\n", .{});
            return;
        } else if (status == jxl.JXL_DEC_BASIC_INFO) {
            if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderGetBasicInfo(dec, &basic_info)) {
                std.log.err("JxlDecoderGetBasicInfo failed\n", .{});
                return;
            }
            format.num_channels = basic_info.num_color_channels + basic_info.num_extra_channels;
            const num_threads = jxl.JxlResizableParallelRunnerSuggestThreads(basic_info.xsize, basic_info.ysize);
            jxl.JxlResizableParallelRunnerSetThreads(runner, num_threads);
            // std.debug.print("image size: {d}×{d}\n", .{ info.xsize, info.ysize });
        } else if (status == jxl.JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            var buffer_size: usize = undefined;
            if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderImageOutBufferSize(dec, &format, &buffer_size)) {
                std.log.err("JxlDecoderImageOutBufferSize failed\n", .{});
                return;
            }
            if (buffer_size != basic_info.xsize * basic_info.ysize * (basic_info.num_color_channels + basic_info.num_extra_channels)) {
                std.log.err("JxlDecoderImageOutBufferSize failed: got {} instead of {} bytes\n", .{
                    buffer_size,
                    basic_info.xsize * basic_info.ysize * (basic_info.num_color_channels + basic_info.num_extra_channels),
                });
                return;
            }
            // std.debug.print("buffer size: {d}\n", .{buffer_size});
            try pixels.resize(basic_info.xsize * basic_info.ysize * format.num_channels);
            // std.debug.print("pixels size: {d}\n", .{pixels.items.len});
            // std.debug.print("format: {any}\n", .{format});
            const pixels_ptr: *void = @ptrCast(pixels.items.ptr);
            const pixels_size = pixels.items.len * @sizeOf(u8);
            if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderSetImageOutBuffer(dec, &format, pixels_ptr, pixels_size)) {
                std.log.err("JxlDecoderSetImageOutBuffer failed\n", .{});
            }
        } else if (status == jxl.JXL_DEC_FULL_IMAGE) {
            // Nothing to do. Do not yet return. If the image is an animation, more
            // full frames may be decoded. This example only keeps the last one.
        } else if (status == jxl.JXL_DEC_SUCCESS) {
            // All decoding successfully finished.
            // It's not required to call JxlDecoderReleaseInput(dec.get()) here since
            // the decoder will be destroyed.
            image.rows = basic_info.ysize;
            image.cols = basic_info.xsize;
            image.depth = basic_info.num_color_channels + basic_info.num_extra_channels;
            image.data = try pixels.toOwnedSlice();
            return;
        } else {
            std.log.err("Unknown JxlDecoder status\n", .{});
            return;
        }
    }
}

pub fn saveJxlImage(allocator: std.mem.Allocator, image: JxlImage, filename: []const u8, quality: f32) !void {
    const enc = jxl.JxlEncoderCreate(null);
    defer jxl.JxlEncoderDestroy(enc);
    const num_threads = jxl.JxlThreadParallelRunnerDefaultNumWorkerThreads();
    const runner = jxl.JxlThreadParallelRunnerCreate(null, num_threads);
    defer jxl.JxlThreadParallelRunnerDestroy(runner);
    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetParallelRunner(enc, jxl.JxlThreadParallelRunner, runner)) {
        std.log.err("JxlEncoderSetParallelRunner failed\n", .{});
        return;
    }

    const pixel_format: jxl.JxlPixelFormat = .{
        .num_channels = @intCast(image.depth),
        .data_type = jxl.JXL_TYPE_UINT8,
        .endianness = jxl.JXL_NATIVE_ENDIAN,
        .@"align" = 0,
    };

    var basic_info: jxl.JxlBasicInfo = undefined;
    jxl.JxlEncoderInitBasicInfo(&basic_info);
    basic_info.xsize = @intCast(image.cols);
    basic_info.ysize = @intCast(image.rows);
    basic_info.bits_per_sample = 8;
    switch (image.depth) {
        1 => {
            basic_info.num_color_channels = 1;
            basic_info.num_extra_channels = 0;
            basic_info.alpha_bits = 0;
            basic_info.alpha_exponent_bits = 0;
        },
        2 => {
            basic_info.num_color_channels = 1;
            basic_info.num_extra_channels = 1;
            basic_info.alpha_bits = basic_info.bits_per_sample;
            basic_info.alpha_exponent_bits = 0;
        },
        3 => {
            basic_info.num_color_channels = 3;
            basic_info.num_extra_channels = 0;
            basic_info.alpha_bits = 0;
            basic_info.alpha_exponent_bits = 0;
        },
        4 => {
            basic_info.num_color_channels = 3;
            basic_info.num_extra_channels = 1;
            basic_info.alpha_bits = basic_info.bits_per_sample;
            basic_info.alpha_exponent_bits = 0;
        },
        else => @panic("unsupported number of channels"),
    }
    basic_info.num_extra_channels = if (image.depth % 2 == 0) 1 else 0;
    basic_info.uses_original_profile = if (quality == 100) jxl.JXL_TRUE else jxl.JXL_FALSE;

    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetBasicInfo(enc, &basic_info)) {
        std.log.err("JxlEncoderSetBasicInfo failed\n", .{});
        return;
    }

    var color_encoding: jxl.JxlColorEncoding = undefined;
    const is_gray: c_int = if (pixel_format.num_channels < 3) 1 else 0;
    jxl.JxlColorEncodingSetToSRGB(&color_encoding, is_gray);

    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetColorEncoding(enc, &color_encoding)) {
        std.log.err("{any}", .{color_encoding});
        std.log.err("JxlEncoderSetColorEncoding failed\n", .{});
        return;
    }

    const frame_settings = jxl.JxlEncoderFrameSettingsCreate(enc, null);
    const distance = jxl.JxlEncoderDistanceFromQuality(quality);
    if (jxl.EXIT_SUCCESS != jxl.JxlEncoderSetFrameDistance(frame_settings, distance)) {
        std.log.err("JxlEncoderSetFrameDistance failed\n", .{});
        return;
    }
    if (distance == 0) {
        if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetFrameLossless(frame_settings, jxl.JXL_TRUE)) {
            std.log.err("JxlEncoderSetFrameLossless failed\n", .{});
            return;
        }
    }

    const pixels_ptr: *void = @ptrCast(image.data.ptr);
    const pixels_size = image.data.len;
    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderAddImageFrame(frame_settings, &pixel_format, pixels_ptr, pixels_size)) {
        std.log.err("JxlEncoderAddImageFrame failed\n", .{});
        return;
    }
    jxl.JxlEncoderCloseInput(enc);
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    try compressed.resize(64);
    var next_out: [*c]u8 = compressed.items.ptr;
    var avail_out = compressed.items.len - (@intFromPtr(next_out) - @intFromPtr(compressed.items.ptr));
    var process_result: c_uint = @intCast(jxl.JXL_ENC_NEED_MORE_OUTPUT);
    while (process_result == jxl.JXL_ENC_NEED_MORE_OUTPUT) {
        process_result = jxl.JxlEncoderProcessOutput(enc, &next_out, &avail_out);
        if (process_result == jxl.JXL_ENC_NEED_MORE_OUTPUT) {
            const offset: usize = @intFromPtr(next_out) - @intFromPtr(compressed.items.ptr);
            try compressed.resize(compressed.items.len * 2);
            next_out = @intFromPtr(compressed.items.ptr) + offset;
            avail_out = compressed.items.len - offset;
        }
    }
    var file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const writer = bw.writer();
    try writer.writeAll(compressed.items);
    try bw.flush();
}
