const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const zhecs = b.dependency("zhecs", .{ .target = target }).module("zhecs");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "zhecs", .module = zhecs },
        },
    });

    // `zig build run` opens the windowed demo.
    const exe = b.addExecutable(.{ .name = "zhecs-raylib", .root_module = mod });
    exe.root_module.linkLibrary(raylib_artifact);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the windowed demo").dependOn(&run.step);

    // `zig build test` runs the headless integration checks (no window needed).
    const tests = b.addTest(.{ .root_module = mod });
    tests.root_module.linkLibrary(raylib_artifact);
    b.step("test", "Run the headless integration tests").dependOn(&b.addRunArtifact(tests).step);
}
