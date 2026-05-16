//! Systems and the phased pipeline, plus lifecycle observers.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "systems run in phase order, then registration order within a phase" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 });

    const Log = struct {
        var seq: [4]u8 = undefined;
        var n: usize = 0;
        fn push(v: u8) void {
            seq[n] = v;
            n += 1;
        }
    };
    Log.n = 0;

    // Registered out of phase order on purpose: load must still run before update before store.
    try w.system(.on_store, "s_store", .{c.Position}, struct {
        fn run(_: *World, _: Entity, _: *c.Position) void {
            Log.push(3);
        }
    }.run);
    try w.system(.on_update, "u_first", .{c.Position}, struct {
        fn run(_: *World, _: Entity, _: *c.Position) void {
            Log.push(1);
        }
    }.run);
    try w.system(.on_update, "u_second", .{c.Position}, struct {
        fn run(_: *World, _: Entity, _: *c.Position) void {
            Log.push(2);
        }
    }.run);
    try w.system(.on_load, "l_load", .{c.Position}, struct {
        fn run(_: *World, _: Entity, _: *c.Position) void {
            Log.push(0);
        }
    }.run);

    w.progress(1.0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, Log.seq[0..Log.n]);
}

test "a system reads delta_time and integrates" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    try w.set(e, c.Velocity{ .x = 10, .y = -4 });

    try w.system(.on_update, "move", .{ c.Position, c.Velocity }, struct {
        fn run(world: *World, _: Entity, p: *c.Position, v: *c.Velocity) void {
            p.x += v.x * world.delta_time;
            p.y += v.y * world.delta_time;
        }
    }.run);

    w.progress(0.1);
    w.progress(0.1);
    try testing.expectApproxEqAbs(@as(f32, 2.0), w.get(e, c.Position).?.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -0.8), w.get(e, c.Position).?.y, 1e-5);
}

// Observer counters live at file scope so the hooks can reach them.
const Obs = struct {
    var adds: usize = 0;
    var sets: usize = 0;
    var removes: usize = 0;
    fn onAdd(_: *World, _: Entity) void {
        adds += 1;
    }
    fn onSet(_: *World, _: Entity) void {
        sets += 1;
    }
    fn onRemove(_: *World, _: Entity) void {
        removes += 1;
    }
};

test "observers: on_add fires once, on_set every set, on_remove on removal" {
    Obs.adds = 0;
    Obs.sets = 0;
    Obs.removes = 0;

    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.observe(c.Position, .on_add, Obs.onAdd);
    try w.observe(c.Position, .on_set, Obs.onSet);
    try w.observe(c.Position, .on_remove, Obs.onRemove);

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 }); // add + set
    try w.set(e, c.Position{ .x = 1, .y = 1 }); // set only
    try w.add(e, c.Position); // already present: no add, no set
    try w.remove(e, c.Position); // remove
    try w.remove(e, c.Position); // already gone: no remove

    try testing.expectEqual(@as(usize, 1), Obs.adds);
    try testing.expectEqual(@as(usize, 2), Obs.sets);
    try testing.expectEqual(@as(usize, 1), Obs.removes);
}

test "an observer only sees events after it is registered" {
    Obs.sets = 0;

    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Position{ .x = 0, .y = 0 }); // before observe: not counted
    try w.observe(c.Position, .on_set, Obs.onSet);
    try w.set(e, c.Position{ .x = 1, .y = 1 }); // after: counted

    try testing.expectEqual(@as(usize, 1), Obs.sets);
}
