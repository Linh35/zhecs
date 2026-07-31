//! `Without(T)` exclusion terms: archetype-level filtering, cache keys, and late registration.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

const Without = zhecs.Without;

test "Without excludes archetypes that hold the excluded component" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const ab = try w.entity();
    try w.set(ab, c.Position{ .x = 0, .y = 0 });
    try w.set(ab, c.Velocity{ .x = 1, .y = 1 });

    const abc = try w.entity();
    try w.set(abc, c.Position{ .x = 0, .y = 0 });
    try w.set(abc, c.Velocity{ .x = 2, .y = 2 });
    try w.set(abc, c.Health{ .hp = 10 });

    const a = try w.entity();
    try w.set(a, c.Position{ .x = 3, .y = 3 });

    try testing.expectEqual(@as(usize, 1), w.count(.{ c.Position, c.Velocity, Without(c.Health) }));
    try testing.expectEqual(@as(usize, 1), w.count(.{ c.Position, Without(c.Velocity) }));
    // Health is registered: an exclusion-only query counts every entity without it. The world's
    // componentless singleton also matches, hence 3 (ab, a, singleton) rather than 2.
    try testing.expectEqual(@as(usize, 3), w.count(.{Without(c.Health)}));

    var seen: usize = 0;
    var it = w.view(.{ c.Position, c.Velocity, Without(c.Health) });
    while (it.next()) |e| {
        _ = e;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "Without agrees across every query entry point" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = @floatFromInt(i), .y = 0 });
        if (i % 2 == 0) try w.set(e, c.Velocity{ .x = 1, .y = 0 });
        if (i % 4 == 0) try w.set(e, c.Health{ .hp = 1 });
    }

    const terms = .{ c.Position, Without(c.Health) };
    try testing.expectEqual(@as(usize, 75), w.count(terms));

    var view_sum: usize = 0;
    var v = w.view(terms);
    while (v.next()) |_| view_sum += 1;
    try testing.expectEqual(@as(usize, 75), view_sum);

    var each_sum: usize = 0;
    w.each(terms, &each_sum, struct {
        fn run(s: *usize, _: Entity, _: *c.Position) void {
            s.* += 1;
        }
    }.run);
    try testing.expectEqual(@as(usize, 75), each_sum);

    var run_sum: usize = 0;
    w.run(terms, &run_sum, struct {
        fn run(s: *usize, ents: []const Entity, _: []c.Position) void {
            s.* += ents.len;
        }
    }.run);
    try testing.expectEqual(@as(usize, 75), run_sum);

    var par_sum: usize = 0;
    w.parallel(terms, &par_sum, struct {
        fn run(s: *usize, ents: []const Entity, _: []c.Position) void {
            s.* += ents.len;
        }
    }.run);
    try testing.expectEqual(@as(usize, 75), par_sum);

    const q = try w.query(terms);
    try testing.expectEqual(@as(usize, 75), q.count());
}

test "Without filters types registered after the query handle was built" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e1 = try w.entity();
    try w.set(e1, c.Position{ .x = 1, .y = 0 });
    const e2 = try w.entity();
    try w.set(e2, c.Position{ .x = 2, .y = 0 });

    const terms = .{ c.Position, Without(c.Health) };
    const q = try w.query(terms);
    try testing.expectEqual(@as(usize, 2), q.count());

    try w.set(e2, c.Health{ .hp = 5 });
    try testing.expectEqual(@as(usize, 1), q.count());
    try testing.expectEqual(@as(usize, 1), w.count(terms));
}

test "Without of a never-registered type matches everything" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    const f = try w.entity();
    try w.set(f, c.Position{ .x = 0, .y = 0 });
    try w.set(f, c.Velocity{ .x = 0, .y = 0 });

    // Frozen is never added to any entity: the exclusion is trivially satisfied.
    try testing.expectEqual(@as(usize, 2), w.count(.{ c.Position, Without(c.Frozen) }));
}
