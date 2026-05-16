//! Entity lifecycle: creation, liveness, deletion, and slot recycling.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "empty world: queries and counts are quiet, singletons are absent" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    try testing.expectEqual(@as(usize, 0), w.count(.{c.Position}));

    var hit: usize = 0;
    w.each(.{c.Position}, &hit, struct {
        fn run(n: *usize, _: Entity, _: *c.Position) void {
            n.* += 1;
        }
    }.run);
    try testing.expectEqual(@as(usize, 0), hit);

    try testing.expect(w.getSingleton(c.Health) == null);
}

test "entity lifecycle: create, alive, delete, double delete is harmless" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try testing.expect(w.isAlive(e));

    w.delete(e);
    try testing.expect(!w.isAlive(e));

    w.delete(e); // deleting a dead handle must not panic or corrupt anything
    try testing.expect(!w.isAlive(e));
}

test "recycled slot gives a fresh generation and the old handle stays dead" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const a = try w.entity();
    try w.set(a, c.Position{ .x = 1, .y = 1 });
    w.delete(a);

    const b = try w.entity(); // reuses a's index with a higher generation
    try testing.expect(w.isAlive(b));
    try testing.expect(!w.isAlive(a));
    try testing.expect(w.get(a, c.Position) == null); // dead handle reads nothing
}
