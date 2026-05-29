const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zgui_dep = b.dependency("zgui", .{ .target = target, .optimize = optimize });
    const zhecs = b.dependency("zhecs", .{ .target = target }).module("zhecs");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zgui", .module = zgui_dep.module("root") }, .{ .name = "zhecs", .module = zhecs } },
    });
    mod.linkLibrary(zgui_dep.artifact("imgui"));
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the headless zgui integration tests").dependOn(&b.addRunArtifact(tests).step);
}
