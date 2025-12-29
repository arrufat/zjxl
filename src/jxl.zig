const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jxl = @cImport({
    @cInclude("jxl/decode.h");
    @cInclude("jxl/encode.h");
    @cInclude("jxl/resizable_parallel_runner.h");
    @cInclude("jxl/thread_parallel_runner.h");
});

pub const Image = struct {
    rows: usize,
    cols: usize,
    channels: usize,
    data: []u8,
    pub fn deinit(self: Image, gpa: Allocator) void {
        gpa.free(self.data);
    }
    pub const empty: Image = .{ .rows = 0, .cols = 0, .channels = 0, .data = &[_]u8{} };
};

const PixelFormat = enum {
    grayscale,
    grayscale_alpha,
    rgb,
    rgb_alpha,

    pub fn hasAlpha(self: PixelFormat) bool {
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

fn decoderVersion() std.SemanticVersion {
    const version = jxl.JxlDecoderVersion();
    const patch = version % 1000;
    const minor = ((version - patch) / 1000) % 1000;
    const major = version / 1000000;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn encoderVersion() std.SemanticVersion {
    const version = jxl.JxlEncoderVersion();
    const major = version / 1000000;
    const minor = (version - major * 1000000) / 1000;
    const patch = version - major * 1000000 - minor * 1000;
    return .{ .major = major, .minor = minor, .patch = patch };
}

pub fn load(io: Io, gpa: Allocator, filename: []const u8, image: *Image) !void {
    const file = try Io.Dir.cwd().readFileAlloc(io, filename, gpa, .limited(100 * 1024 * 1024));
    defer gpa.free(file);

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
        std.log.err("JxlDecoderSetInput failed\n", .{});
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
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(gpa);
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
            try pixels.resize(gpa, basic_info.xsize * basic_info.ysize * format.num_channels);
            const pixels_ptr: *void = @ptrCast(pixels.items.ptr);
            const pixels_size = pixels.items.len * @sizeOf(u8);
            if (jxl.JXL_DEC_SUCCESS != jxl.JxlDecoderSetImageOutBuffer(dec, &format, pixels_ptr, pixels_size)) {
                std.log.err("JxlDecoderSetImageOutBuffer failed\n", .{});
            }
        } else if (status == jxl.JXL_DEC_FULL_IMAGE or status == jxl.JXL_DEC_SUCCESS) {
            // We have either decoded a full image (there might be more if it's an animation) or all decoding successfully finished.
            image.rows = basic_info.ysize;
            image.cols = basic_info.xsize;
            image.channels = basic_info.num_color_channels + basic_info.num_extra_channels;
            image.data = try pixels.toOwnedSlice(gpa);
            return;
        } else {
            std.log.err("Unknown JxlDecoder status\n", .{});
            return;
        }
    }
}

pub fn save(io: Io, gpa: Allocator, image: Image, filename: []const u8, quality: f32) !void {
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
        .num_channels = @intCast(image.channels),
        .data_type = jxl.JXL_TYPE_UINT8,
        .endianness = jxl.JXL_NATIVE_ENDIAN,
        .@"align" = 0,
    };

    var basic_info: jxl.JxlBasicInfo = undefined;
    jxl.JxlEncoderInitBasicInfo(&basic_info);
    basic_info.xsize = @intCast(image.cols);
    basic_info.ysize = @intCast(image.rows);
    basic_info.bits_per_sample = 8;
    switch (image.channels) {
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
    basic_info.num_extra_channels = if (image.channels % 2 == 0) 1 else 0;
    basic_info.uses_original_profile = if (quality == 100) jxl.JXL_TRUE else jxl.JXL_FALSE;

    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetBasicInfo(enc, &basic_info)) {
        std.log.err("JxlEncoderSetBasicInfo failed\n", .{});
        return;
    }

    var color_encoding: jxl.JxlColorEncoding = undefined;
    const is_gray: c_int = if (pixel_format.num_channels < 3) 1 else 0;
    jxl.JxlColorEncodingSetToSRGB(&color_encoding, is_gray);

    if (jxl.JXL_ENC_SUCCESS != jxl.JxlEncoderSetColorEncoding(enc, &color_encoding)) {
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
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    try compressed.resize(gpa, 64);
    var next_out: [*c]u8 = compressed.items.ptr;
    var avail_out = compressed.items.len - (@intFromPtr(next_out) - @intFromPtr(compressed.items.ptr));
    var process_result: c_uint = @intCast(jxl.JXL_ENC_NEED_MORE_OUTPUT);
    while (process_result == jxl.JXL_ENC_NEED_MORE_OUTPUT) {
        process_result = jxl.JxlEncoderProcessOutput(enc, &next_out, &avail_out);
        if (process_result == jxl.JXL_ENC_NEED_MORE_OUTPUT) {
            const offset: usize = @intFromPtr(next_out) - @intFromPtr(compressed.items.ptr);
            try compressed.resize(gpa, compressed.items.len * 2);
            next_out = @intFromPtr(compressed.items.ptr) + offset;
            avail_out = compressed.items.len - offset;
        }
    }
    var file = try Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);
    try file_writer.interface.writeAll(compressed.items);
    try file_writer.interface.flush();
}
