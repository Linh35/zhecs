const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rl_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    const zhecs = b.dependency("zhecs", .{ .target = target }).module("zhecs");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "raylib", .module = rl_dep.module("raylib") }, .{ .name = "zhecs", .module = zhecs } },
    });
    mod.linkLibrary(rl_dep.artifact("raylib"));
    const exe = b.addExecutable(.{ .name = "zhecs-platformer", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Play the platformer").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the headless game-logic tests").dependOn(&b.addRunArtifact(tests).step);
}
