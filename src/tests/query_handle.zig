//! Held query handles: a compiled query reused across calls, with self-refreshing match caches.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "a handle iterates the same set as a loose query" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = @floatFromInt(i), .y = 0 });
        if (i % 2 == 0) try w.set(e, c.Velocity{ .x = 1, .y = 0 });
    }

    const q = try w.query(.{ c.Position, c.Velocity });
    try testing.expectEqual(w.count(.{ c.Position, c.Velocity }), q.count());

    var loose: f64 = 0;
    w.each(.{ c.Position, c.Velocity }, &loose, struct {
        fn run(s: *f64, _: Entity, p: *c.Position, _: *c.Velocity) void {
            s.* += p.x;
        }
    }.run);
    var held: f64 = 0;
    q.each(&held, struct {
        fn run(s: *f64, _: Entity, p: *c.Position, _: *c.Velocity) void {
            s.* += p.x;
        }
    }.run);
    try testing.expectEqual(loose, held);
}

test "a handle reused across frames keeps returning the right set" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Health{ .hp = 1 });
    }

    const q = try w.query(.{c.Health});
    var frame: usize = 0;
    while (frame < 10) : (frame += 1) {
        var n: usize = 0;
        q.each(&n, struct {
            fn run(count: *usize, _: Entity, _: *c.Health) void {
                count.* += 1;
            }
        }.run);
        try testing.expectEqual(@as(usize, 5), n);
    }
}

test "a handle notices archetypes created after it was compiled" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const a = try w.entity();
    try w.set(a, c.Health{ .hp = 1 });

    const q = try w.query(.{c.Health});
    try testing.expectEqual(@as(usize, 1), q.count());

    // A new entity in a brand-new archetype (Health + Position) bumps the world's table version.
    const b = try w.entity();
    try w.set(b, c.Health{ .hp = 2 });
    try w.set(b, c.Position{ .x = 0, .y = 0 });

    try testing.expectEqual(@as(usize, 2), q.count()); // the handle refreshed itself
}

test "the chunk form of a handle works too" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = 2, .y = 0 });
    }

    const q = try w.query(.{c.Position});
    var sum: f64 = 0;
    q.run(&sum, struct {
        fn run(s: *f64, _: []const Entity, ps: []c.Position) void {
            for (ps) |p| s.* += p.x;
        }
    }.run);
    try testing.expectEqual(@as(f64, 200), sum);
}

test "two handles over different queries stay independent" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const a = try w.entity();
    try w.set(a, c.Position{ .x = 0, .y = 0 });
    const b = try w.entity();
    try w.set(b, c.Velocity{ .x = 0, .y = 0 });

    const qp = try w.query(.{c.Position});
    const qv = try w.query(.{c.Velocity});
    try testing.expectEqual(@as(usize, 1), qp.count());
    try testing.expectEqual(@as(usize, 1), qv.count());
}
