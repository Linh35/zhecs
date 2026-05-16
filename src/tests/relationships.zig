//! Relationships (pairs), singletons, and pre-allocation hints.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "relationships: distinct targets coexist, removal is per target" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const apple = try w.entity();
    const pear = try w.entity();
    try w.addPair(e, c.Likes, apple);
    try w.addPair(e, c.Likes, pear);
    try testing.expect(w.hasPair(e, c.Likes, apple));
    try testing.expect(w.hasPair(e, c.Likes, pear));

    try w.removePair(e, c.Likes, apple);
    try testing.expect(!w.hasPair(e, c.Likes, apple));
    try testing.expect(w.hasPair(e, c.Likes, pear));
}

test "two relationships of different kinds to the same target are independent" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const thing = try w.entity();
    try w.addPair(e, c.Likes, thing);
    try w.addPair(e, c.Owns, thing);
    try testing.expect(w.hasPair(e, c.Likes, thing));
    try testing.expect(w.hasPair(e, c.Owns, thing));

    try w.removePair(e, c.Likes, thing);
    try testing.expect(!w.hasPair(e, c.Likes, thing));
    try testing.expect(w.hasPair(e, c.Owns, thing));
}

test "ChildOf and parent, including a self relationship" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const mom = try w.entity();
    const kid = try w.entity();
    try w.childOf(kid, mom);
    try testing.expectEqual(mom, w.parent(kid).?);

    const loop = try w.entity();
    try w.childOf(loop, loop); // permitted; just a pair pointing at itself
    try testing.expectEqual(loop, w.parent(loop).?);
    try testing.expect(w.parent(mom) == null);
}

test "a relationship to a deleted target reports the target as no longer alive" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const target = try w.entity();
    try w.addPair(e, c.Owns, target);
    w.delete(target);

    const t = w.getTarget(e, c.Owns).?; // still recorded by index
    try testing.expect(!w.isAlive(t)); // but the generation no longer matches
}

test "singletons: set, overwrite, and several distinct kinds" {
    const Gravity = struct { v: f32 };
    const Tick = struct { n: u64 };

    var w = try World.init(testing.allocator);
    defer w.deinit();

    try w.setSingleton(Gravity{ .v = 9.8 });
    try w.setSingleton(Tick{ .n = 1 });
    try testing.expectEqual(@as(f32, 9.8), w.getSingleton(Gravity).?.v);

    w.getSingleton(Tick).?.n = 42;
    try testing.expectEqual(@as(u64, 42), w.getSingleton(Tick).?.n);

    try w.setSingleton(Gravity{ .v = 1.6 }); // overwrite
    try testing.expectEqual(@as(f32, 1.6), w.getSingleton(Gravity).?.v);
}

test "reserve and initCapacity are transparent: identical behaviour, just fewer growths" {
    var w = try World.initCapacity(testing.allocator, .{ .entities = 1000 });
    defer w.deinit();
    try w.reserve(.{ c.Position, c.Velocity }, 1000);
    try w.reserve(.{ c.Position, c.Velocity }, 1000); // idempotent

    var i: usize = 0;
    while (i < 1500) : (i += 1) { // exceed the reservation to prove growth still works
        const e = try w.entity();
        try w.set(e, c.Position{ .x = @floatFromInt(i), .y = 0 });
        try w.set(e, c.Velocity{ .x = 1, .y = 0 });
    }
    try testing.expectEqual(@as(usize, 1500), w.count(.{ c.Position, c.Velocity }));
}
