const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module other packages import as `@import("zhecs")`.
    const zhecs = b.addModule("zhecs", .{
        .root_source_file = b.path("src/zhecs.zig"),
        .target = target,
    });

    // `zig build example` runs the worked example against the library.
    const example = b.addExecutable(.{
        .name = "zhecs-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // the benchmark reads a monotonic clock via libc clock_gettime
            .imports = &.{.{ .name = "zhecs", .module = zhecs }},
        }),
    });
    b.installArtifact(example);

    const run = b.addRunArtifact(example);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("example", "Run the worked example and benchmark").dependOn(&run.step);

    // `zig build test` runs two test binaries: the unit tests embedded in the library (which can
    // reach internal details), and the public-API test suite in src/tests.zig.
    const test_step = b.step("test", "Run all tests");

    const lib_tests = b.addTest(.{ .root_module = zhecs });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const suite = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zhecs", .module = zhecs }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(suite).step);
}
