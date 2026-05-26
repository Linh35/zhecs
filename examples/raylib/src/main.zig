//! zhecs driving a raylib window. Entities carry a position, a velocity, a radius, and a colour;
//! a system moves them and bounces them off the edges; a query draws them. The components show two
//! ways to use a library's types: wrap a type when it plays more than one role (a position and a
//! velocity are both a Vector2, so they need distinct component types), and use a type directly
//! when its role is unique (the colour and the radius).
//!
//! `zig build run` opens the window. `zig build test` runs the headless checks at the bottom, which
//! need no display, so they are what proves the integration in CI.

const std = @import("std");
const rl = @import("raylib");
const zhecs = @import("zhecs");

const World = zhecs.World;
const Entity = zhecs.Entity;

const width = 800;
const height = 450;

// Distinct component types that happen to share raylib's Vector2 as their payload.
const Position = struct { v: rl.Vector2 };
const Velocity = struct { v: rl.Vector2 };
// Used directly, since each plays a single role.
const Radius = f32;
const Tint = rl.Color;

// Move every mover and keep it on screen. Reads delta time from the world.
fn move(w: *World, _: Entity, p: *Position, vel: *Velocity) void {
    const dt = w.delta_time;
    p.v.x += vel.v.x * dt;
    p.v.y += vel.v.y * dt;
    if (p.v.x < 0 or p.v.x > width) vel.v.x = -vel.v.x;
    if (p.v.y < 0 or p.v.y > height) vel.v.y = -vel.v.y;
}

pub fn main() !void {
    var world = try World.init(std.heap.page_allocator);
    defer world.deinit();

    var prng = std.Random.DefaultPrng.init(0x2026_0602);
    const rand = prng.random();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const e = try world.entity();
        try world.set(e, Position{ .v = .{ .x = rand.float(f32) * width, .y = rand.float(f32) * height } });
        try world.set(e, Velocity{ .v = .{ .x = (rand.float(f32) - 0.5) * 200, .y = (rand.float(f32) - 0.5) * 200 } });
        try world.set(e, @as(Radius, 2 + rand.float(f32) * 6));
        try world.set(e, rl.Color.init(rand.int(u8), rand.int(u8), rand.int(u8), 255));
    }

    try world.system(.on_update, "move", .{ Position, Velocity }, move);

    rl.initWindow(width, height, "zhecs + raylib");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        try world.progress(rl.getFrameTime());

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.ray_white);
        world.each(.{ Position, Radius, Tint }, {}, struct {
            fn draw(_: void, _: Entity, p: *Position, r: *Radius, t: *Tint) void {
                rl.drawCircleV(p.v, r.*, t.*);
            }
        }.draw);
    }
}

// --- headless integration tests (no window) ------------------------------------------------------

const testing = std.testing;

test "raylib types live as zhecs components and a system steps them" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, Position{ .v = .{ .x = 0, .y = 0 } });
    try w.set(e, Velocity{ .v = .{ .x = 10, .y = -4 } });
    try w.set(e, rl.Color.red); // a raylib type used directly as a component

    try w.system(.on_update, "move", .{ Position, Velocity }, move);
    try w.progress(1.0);

    try testing.expectEqual(@as(f32, 10), w.get(e, Position).?.v.x);
    try testing.expectEqual(@as(f32, -4), w.get(e, Position).?.v.y);
    try testing.expectEqual(@as(u8, 230), w.get(e, rl.Color).?.r); // raylib red
}

test "a query and a chunk sweep over raylib-typed components" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const e = try w.entity();
        try w.set(e, Position{ .v = .{ .x = @floatFromInt(i), .y = 0 } });
        try w.set(e, rl.Rectangle{ .x = 0, .y = 0, .width = 8, .height = 8 }); // another raylib type, directly
    }

    try testing.expectEqual(@as(usize, 64), w.count(.{ Position, rl.Rectangle }));

    var sum: f64 = 0;
    w.run(.{Position}, &sum, struct {
        fn run(s: *f64, _: []const Entity, ps: []Position) void {
            for (ps) |p| s.* += p.v.x;
        }
    }.run);
    try testing.expectEqual(@as(f64, 63 * 64 / 2), sum);
}
