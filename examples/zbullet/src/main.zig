//! zhecs glued to the Bullet physics engine through zig-gamedev's zbullet. Each entity holds the
//! handles to its rigid body and collision shape as components; a zhecs query syncs every body's
//! world position back into a Position component after each physics step. The tests are headless,
//! so they run anywhere `zig build test` does, and they assert real physical behaviour: spheres
//! fall, land, and settle on a floor, and a launched body rises and comes back down.

const std = @import("std");
const testing = std.testing;
const zbt = @import("zbullet");
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

// The physics handles, stored on the entity. Bullet owns the memory behind them; teardown frees it,
// since a table move only copies the handle.
const RigidBody = struct { body: zbt.Body, shape: zbt.Shape };
// The body's world position, copied out of Bullet each step so ECS systems can read it cheaply.
const Position = struct { v: [3]f32 };

// A 3x4 transform (Bullet's layout): identity rotation, translation in the last three slots.
fn at(x: f32, y: f32, z: f32) [12]f32 {
    return .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, x, y, z };
}

// Copy each body's world position into its Position component.
fn syncPositions(w: *World) void {
    w.each(.{ RigidBody, Position }, {}, struct {
        fn run(_: void, _: Entity, rb: *RigidBody, p: *Position) void {
            var t: [12]f32 = undefined;
            rb.body.getGraphicsWorldTransform(&t);
            p.v = .{ t[9], t[10], t[11] };
        }
    }.run);
}

test "spheres fall under gravity and settle on a static floor, synced into ECS positions" {
    zbt.init(testing.allocator);
    defer zbt.deinit();

    const world = zbt.initWorld();
    defer world.deinit(); // asserts the world is empty, so every body is removed before this runs
    world.setGravity(&.{ 0, -10, 0 });

    // A static floor: a wide box centred at the origin with half-height 1, so its top is at y = 1.
    const floor_top: f32 = 1;
    const ground_shape = zbt.initBoxShape(&.{ 50, 1, 50 });
    const ground_tf = at(0, 0, 0);
    const ground = zbt.initBody(0, &ground_tf, ground_shape.asShape()); // mass 0 means immovable
    world.addBody(ground);

    var w = try World.init(testing.allocator);
    defer w.deinit();

    const radius: f32 = 0.5;
    var ids: [16]Entity = undefined;
    try w.spawn(ids.len, &ids);
    for (ids, 0..) |e, i| {
        const fi: f32 = @floatFromInt(i);
        const shape = zbt.initSphereShape(radius);
        const tf = at(fi * 2 - 16, 20 + fi * 2, 0); // spread out and stacked in height
        const body = zbt.initBody(1.0, &tf, shape.asShape());
        body.setRestitution(0.3);
        world.addBody(body);
        try w.set(e, RigidBody{ .body = body, .shape = shape.asShape() });
        try w.set(e, Position{ .v = .{ 0, 0, 0 } });
    }

    // Record the starting heights to confirm the spheres actually fell.
    syncPositions(&w);
    var start_high: usize = 0;
    var ctx0 = .{ .n = &start_high };
    w.each(.{Position}, &ctx0, struct {
        fn run(x: @TypeOf(&ctx0), _: Entity, p: *Position) void {
            if (p.v[1] > 15) x.n.* += 1;
        }
    }.run);
    try testing.expectEqual(@as(usize, 16), start_high);

    // Simulate five seconds at 60 Hz, syncing positions into the ECS after each step.
    var step: usize = 0;
    while (step < 300) : (step += 1) {
        _ = world.stepSimulation(1.0 / 60.0, .{});
        syncPositions(&w);
    }

    // Every sphere has come to rest on the floor (centre at floor_top + radius) and none sank below.
    const rest_y = floor_top + radius;
    var resting: usize = 0;
    var sunk = false;
    var ctx = .{ .rest = &resting, .sunk = &sunk };
    w.each(.{Position}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, p: *Position) void {
            if (p.v[1] < rest_y - 0.25) x.sunk.* = true; // would mean it fell through the floor
            if (@abs(p.v[1] - rest_y) < 0.25) x.rest.* += 1;
        }
    }.run);
    try testing.expect(!sunk);
    try testing.expectEqual(@as(usize, 16), resting);

    // Teardown: bodies must leave the world and be freed before world.deinit and zbt.deinit.
    var cleanup = .{ .world = world };
    w.each(.{RigidBody}, &cleanup, struct {
        fn run(x: @TypeOf(&cleanup), _: Entity, rb: *RigidBody) void {
            x.world.removeBody(rb.body);
            rb.body.deinit();
            rb.shape.deinit();
        }
    }.run);
    world.removeBody(ground);
    ground.deinit();
    ground_shape.deinit();
}

test "a launched body rises against gravity then falls back, tracked through the ECS" {
    zbt.init(testing.allocator);
    defer zbt.deinit();

    const world = zbt.initWorld();
    defer world.deinit();
    world.setGravity(&.{ 0, -10, 0 });

    const shape = zbt.initSphereShape(0.5);
    const tf = at(0, 0, 0);
    const body = zbt.initBody(1.0, &tf, shape.asShape());
    world.addBody(body);
    body.setLinearVelocity(&.{ 0, 12, 0 }); // launch straight up

    var w = try World.init(testing.allocator);
    defer w.deinit();
    const e = try w.entity();
    try w.set(e, RigidBody{ .body = body, .shape = shape.asShape() });
    try w.set(e, Position{ .v = .{ 0, 0, 0 } });

    var peak: f32 = 0;
    var step: usize = 0;
    while (step < 200) : (step += 1) {
        _ = world.stepSimulation(1.0 / 60.0, .{});
        syncPositions(&w);
        peak = @max(peak, w.get(e, Position).?.v[1]);
    }

    try testing.expect(peak > 4); // it climbed under its launch speed
    try testing.expect(w.get(e, Position).?.v[1] < peak - 1); // and later came back down

    world.removeBody(body);
    body.deinit();
    shape.deinit();
}
