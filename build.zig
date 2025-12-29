const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "zjxl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jxl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.link_libc = true;
    lib.root_module.linkSystemLibrary("jxl", .{ .needed = true });
    lib.root_module.linkSystemLibrary("jxl_cms", .{});
    lib.root_module.linkSystemLibrary("jxl_threads", .{});
    lib.root_module.strip = optimize != .Debug;
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zjxl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkLibrary(lib);
    exe.root_module.strip = optimize != .Debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
