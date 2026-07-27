const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.linkSystemLibrary("jxl", .{ .needed = true });
    const c_mod = tc.createModule();

    const lib = b.addLibrary(.{
        .name = "zjxl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jxl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("c", c_mod);
    lib.root_module.link_libc = true;
    lib.root_module.linkSystemLibrary("jxl", .{ .needed = true });
    lib.root_module.linkSystemLibrary("jxl_cms", .{});
    lib.root_module.linkSystemLibrary("jxl_threads", .{});
    lib.root_module.strip = optimize != .debug;
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zjxl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // The self-hosted x86_64 linker can't handle the .sframe relocations
        // (R_X86_64_PC64) emitted by GCC 16's crt1.o, so use LLVM + LLD.
        .use_llvm = true,
        .use_lld = true,
    });
    exe.root_module.linkLibrary(lib);
    exe.root_module.addImport("c", c_mod);
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
