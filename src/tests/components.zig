//! Component storage: set, get, has, remove, table moves, alignment, size, and wide signatures.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "overwriting a component updates in place without adding a second copy" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Health{ .hp = 10 });
    try w.set(e, c.Health{ .hp = 7 });

    try testing.expectEqual(@as(i32, 7), w.get(e, c.Health).?.hp);
    try testing.expectEqual(@as(usize, 1), w.count(.{c.Health}));
}

test "add then set, and removing components not present, behave as expected" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.add(e, c.Health); // zero-initialised
    try testing.expectEqual(@as(i32, 0), w.get(e, c.Health).?.hp);

    try w.set(e, c.Health{ .hp = 5 });
    try testing.expectEqual(@as(i32, 5), w.get(e, c.Health).?.hp);

    try w.remove(e, c.Position); // never had it
    try testing.expect(w.has(e, c.Health));
}

test "queries and reads of never-registered components are empty, not errors" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const Unseen = struct { v: u8 };

    try testing.expect(!w.has(e, Unseen));
    try testing.expect(w.get(e, Unseen) == null);
    try w.remove(e, Unseen); // no-op
    try testing.expectEqual(@as(usize, 0), w.count(.{Unseen}));
}

test "removing the last component returns an entity to the empty table but keeps it alive" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 3, .y = 4 });
    try w.remove(e, c.Position);

    try testing.expect(w.isAlive(e));
    try testing.expect(!w.has(e, c.Position));
    try testing.expectEqual(@as(usize, 0), w.count(.{c.Position}));
}

test "component order does not fork the archetype: A,B and B,A share one table" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e1 = try w.entity();
    try w.set(e1, c.Position{ .x = 1, .y = 1 });
    try w.set(e1, c.Velocity{ .x = 2, .y = 2 });

    const e2 = try w.entity();
    try w.set(e2, c.Velocity{ .x = 2, .y = 2 });
    try w.set(e2, c.Position{ .x = 1, .y = 1 });

    try testing.expectEqual(@as(usize, 2), w.count(.{ c.Position, c.Velocity }));
    try testing.expectEqual(@as(usize, 2), w.count(.{ c.Velocity, c.Position }));
}

test "term order is independent: pointers map to the right component either way" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    try w.set(e, c.Velocity{ .x = 0, .y = 0 });

    w.each(.{ c.Velocity, c.Position }, {}, struct {
        fn run(_: void, _: Entity, v: *c.Velocity, p: *c.Position) void {
            v.x = 11;
            p.x = 22;
        }
    }.run);

    try testing.expectEqual(@as(f32, 11), w.get(e, c.Velocity).?.x);
    try testing.expectEqual(@as(f32, 22), w.get(e, c.Position).?.x);
}

test "swap-remove relocates the last row and fixes its record" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const a = try w.entity();
    const b = try w.entity();
    try w.set(a, c.Health{ .hp = 1 });
    try w.set(b, c.Health{ .hp = 2 }); // a and b share the {Health} table; b is the last row

    w.delete(a); // b swaps into a's row
    try testing.expect(w.isAlive(b));
    try testing.expectEqual(@as(i32, 2), w.get(b, c.Health).?.hp); // b's data followed it
    try testing.expectEqual(@as(usize, 1), w.count(.{c.Health}));
}

test "over-aligned components round-trip through get and through a chunk slice" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Aligned{ .lead = 7, .big = 0xdead_beef_cafe });
    try w.set(e, c.Position{ .x = 1, .y = 1 }); // force a move so the column is rebuilt elsewhere

    const got = w.get(e, c.Aligned).?;
    try testing.expectEqual(@as(u8, 7), got.lead);
    try testing.expectEqual(@as(u128, 0xdead_beef_cafe), got.big);

    var seen_big: u128 = 0;
    var seen_len: usize = 0;
    var ctx = .{ .big = &seen_big, .len = &seen_len };
    w.run(.{c.Aligned}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), ents: []const Entity, items: []c.Aligned) void {
            x.len.* = ents.len;
            if (items.len > 0) x.big.* = items[0].big;
        }
    }.run);
    try testing.expectEqual(@as(usize, 1), seen_len);
    try testing.expectEqual(@as(u128, 0xdead_beef_cafe), seen_big);
}

test "large components survive table moves intact" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    var big: c.Big = .{ .bytes = undefined };
    for (&big.bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try w.set(e, big);
    try w.set(e, c.Health{ .hp = 1 }); // move to a wider table

    const got = w.get(e, c.Big).?;
    for (got.bytes, 0..) |byte, i| try testing.expectEqual(@as(u8, @truncate(i)), byte);
}

test "removing a component from the middle of a wide signature keeps the rest" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    inline for (0..16) |i| try w.set(e, c.Comp(i){ .v = @intCast(i * 10) });

    try w.remove(e, c.Comp(8)); // pull one out of the middle
    inline for (0..16) |i| {
        if (i == 8) {
            try testing.expect(!w.has(e, c.Comp(i)));
        } else {
            try testing.expectEqual(@as(u32, @intCast(i * 10)), w.get(e, c.Comp(i)).?.v);
        }
    }
}
