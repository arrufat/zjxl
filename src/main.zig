const std = @import("std");

const JxlImage = @import("jxl.zig").JxlImage;
const loadJxlImage = @import("jxl.zig").loadJxlImage;
const saveJxlImage = @import("jxl.zig").saveJxlImage;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |arg| {
        var image: JxlImage = undefined;
        defer image.deinit(allocator);
        try loadJxlImage(allocator, arg, &image);
        std.debug.print("image: {}×{}×{} ({} bytes)\n", .{ image.cols, image.rows, image.channels, image.data.len });
        const quality: f32 = if (args.next()) |q| std.fmt.parseFloat(f32, q) catch 100 else 100;
        try saveJxlImage(allocator, image, "output.jxl", quality);
    } else {
        std.debug.print("pass a JPEG XL and an optiional quality\n", .{});
        return;
    }
}
