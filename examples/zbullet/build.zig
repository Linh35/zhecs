const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zbullet = b.dependency("zbullet", .{ .target = target, .optimize = optimize }).module("root");
    const zhecs = b.dependency("zhecs", .{ .target = target }).module("zhecs");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zbullet", .module = zbullet }, .{ .name = "zhecs", .module = zhecs } },
    });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the headless physics integration tests").dependOn(&b.addRunArtifact(tests).step);
}
