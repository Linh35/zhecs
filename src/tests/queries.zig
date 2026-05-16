//! Queries: superset matching, the per-row and per-chunk iterators, tags, and re-entrancy.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "a query matches every superset archetype" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const just_a = try w.entity();
    try w.set(just_a, c.Position{ .x = 0, .y = 0 });

    const ab = try w.entity();
    try w.set(ab, c.Position{ .x = 0, .y = 0 });
    try w.set(ab, c.Velocity{ .x = 0, .y = 0 });

    const abc = try w.entity();
    try w.set(abc, c.Position{ .x = 0, .y = 0 });
    try w.set(abc, c.Velocity{ .x = 0, .y = 0 });
    try w.set(abc, c.Health{ .hp = 0 });

    try testing.expectEqual(@as(usize, 3), w.count(.{c.Position}));
    try testing.expectEqual(@as(usize, 2), w.count(.{ c.Position, c.Velocity }));
    try testing.expectEqual(@as(usize, 1), w.count(.{ c.Position, c.Velocity, c.Health }));
}

test "run and each agree, and run can mutate through the column slices" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = @floatFromInt(i), .y = 0 });
        if (i % 2 == 0) try w.set(e, c.Velocity{ .x = 1, .y = 0 });
    }

    var each_sum: f64 = 0;
    w.each(.{c.Position}, &each_sum, struct {
        fn run(s: *f64, _: Entity, p: *c.Position) void {
            s.* += p.x;
        }
    }.run);

    var run_sum: f64 = 0;
    w.run(.{c.Position}, &run_sum, struct {
        fn run(s: *f64, _: []const Entity, ps: []c.Position) void {
            for (ps) |p| s.* += p.x;
        }
    }.run);

    try testing.expectEqual(each_sum, run_sum);

    w.run(.{ c.Position, c.Velocity }, {}, struct {
        fn run(_: void, _: []const Entity, ps: []c.Position, vs: []c.Velocity) void {
            for (ps, vs) |*p, v| p.x += v.x;
        }
    }.run);
    try testing.expectEqual(@as(usize, 50), w.count(.{ c.Position, c.Velocity }));
}

test "tags work as zero-size components in queries" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e1 = try w.entity();
    const e2 = try w.entity();
    try w.add(e1, c.Frozen);
    try w.set(e1, c.Position{ .x = 0, .y = 0 });
    try w.set(e2, c.Position{ .x = 0, .y = 0 });

    try testing.expectEqual(@as(usize, 1), w.count(.{ c.Position, c.Frozen }));

    var seen: usize = 0;
    w.run(.{c.Frozen}, &seen, struct {
        fn run(n: *usize, ents: []const Entity, _: []c.Frozen) void {
            n.* += ents.len;
        }
    }.run);
    try testing.expectEqual(@as(usize, 1), seen);
}

test "nested each over different queries is safe" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = 0, .y = 0 });
        try w.set(e, c.Health{ .hp = 1 });
    }

    var pairs: usize = 0;
    var ctx = .{ .w = &w, .pairs = &pairs };
    w.each(.{c.Position}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, _: *c.Position) void {
            x.w.each(.{c.Health}, x.pairs, struct {
                fn inner(p: *usize, _: Entity, _: *c.Health) void {
                    p.* += 1;
                }
            }.inner);
        }
    }.run);
    try testing.expectEqual(@as(usize, 25), pairs); // 5 outer x 5 inner
}
