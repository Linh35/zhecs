const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl = b.dependency("zsdl", .{ .target = target, .optimize = optimize }).module("zsdl3");
    const zhecs = b.dependency("zhecs", .{ .target = target }).module("zhecs");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "sdl", .module = sdl }, .{ .name = "zhecs", .module = zhecs } },
    });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the headless zsdl integration tests").dependOn(&b.addRunArtifact(tests).step);
}
