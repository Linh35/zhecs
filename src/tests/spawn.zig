//! Batch spawn: bringing many entities into being at once, and combining that with the rest.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "spawn fills the slice with live, distinct, empty entities" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var out: [256]Entity = undefined;
    try w.spawn(out.len, &out);

    var seen = std.AutoHashMap(Entity, void).init(testing.allocator);
    defer seen.deinit();
    for (out) |e| {
        try testing.expect(w.isAlive(e));
        try testing.expect(!w.has(e, c.Position)); // spawned bare
        const gop = try seen.getOrPut(e);
        try testing.expect(!gop.found_existing); // all distinct
    }
}

test "spawn of zero is a no-op" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    var out: [4]Entity = undefined;
    try w.spawn(0, &out);
    try testing.expectEqual(@as(usize, 0), w.count(.{c.Position}));
}

test "spawn then give the crowd their components" {
    var w = try World.initCapacity(testing.allocator, .{ .entities = 1000 });
    defer w.deinit();

    var out: [1000]Entity = undefined;
    try w.spawn(out.len, &out);
    for (out, 0..) |e, i| try w.set(e, c.Position{ .x = @floatFromInt(i), .y = 0 });

    try testing.expectEqual(@as(usize, 1000), w.count(.{c.Position}));
}

test "spawn cooperates with a defer scope" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var out: [16]Entity = undefined;
    try w.spawn(out.len, &out);

    w.beginDefer();
    for (out) |e| try w.set(e, c.Health{ .hp = 7 });
    try testing.expectEqual(@as(usize, 0), w.count(.{c.Health})); // queued
    try w.endDefer();

    try testing.expectEqual(@as(usize, 16), w.count(.{c.Health}));
    for (out) |e| try testing.expectEqual(@as(i32, 7), w.get(e, c.Health).?.hp);
}
