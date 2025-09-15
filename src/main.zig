const std = @import("std");

const jxl = @import("jxl.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |arg| {
        var image: jxl.Image = .empty;
        defer image.deinit(gpa);
        try jxl.load(gpa, arg, &image);
        std.debug.print("image: {}×{}×{} ({} bytes)\n", .{ image.cols, image.rows, image.channels, image.data.len });
        const quality: f32 = if (args.next()) |q| std.fmt.parseFloat(f32, q) catch 100 else 100;
        try jxl.save(gpa, image, "output.jxl", quality);
    } else {
        std.debug.print("pass a JPEG XL and an optiional quality\n", .{});
        return;
    }
}
