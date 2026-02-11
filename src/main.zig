const std = @import("std");

const jxl = @import("jxl.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    _ = args.skip();
    if (args.next()) |arg| {
        var image: jxl.Image = .empty;
        defer image.deinit(init.gpa);
        try jxl.load(init.io, init.gpa, arg, &image);
        std.debug.print("image: {}×{}×{} ({} bytes)\n", .{ image.cols, image.rows, image.channels, image.data.len });
        const quality: f32 = if (args.next()) |q| std.fmt.parseFloat(f32, q) catch 100 else 100;
        try jxl.save(init.io, init.gpa, image, "output.jxl", quality);
    } else {
        std.debug.print("pass a JPEG XL and an optional quality\n", .{});
    }
}
