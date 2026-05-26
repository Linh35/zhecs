//! zhecs driving a raylib window: a bin of balls falling under gravity and bouncing off the floor
//! and walls, losing a little energy each hit. Physics is a zhecs system, drawing is a query, and
//! the components are raylib's own types. Two of them, position and velocity, are a Vector2 in
//! different roles, so each gets its own one-field type; the radius and colour have a single role
//! and go in as they are.
//!
//! `zig build run` opens the window. `zig build test` runs the headless suite in tests.zig, which
//! needs no display and is what proves the integration in CI.

const std = @import("std");
const rl = @import("raylib");
const zhecs = @import("zhecs");

const World = zhecs.World;
const Entity = zhecs.Entity;

pub const width = 800;
pub const height = 450;
pub const gravity = 900; // pixels per second squared
pub const restitution = 0.78; // fraction of speed kept after a bounce

pub const Position = struct { v: rl.Vector2 };
pub const Velocity = struct { v: rl.Vector2 };
pub const Radius = f32;
pub const Tint = rl.Color;

// Integrate one ball under gravity and resolve floor and wall contacts. Shared by the demo and the
// physics test, so it carries no windowing.
pub fn step(w: *World, _: Entity, p: *Position, vel: *Velocity, r: *Radius) void {
    const dt = w.delta_time;
    vel.v.y += gravity * dt;
    p.v.x += vel.v.x * dt;
    p.v.y += vel.v.y * dt;

    if (p.v.y > height - r.*) {
        p.v.y = height - r.*;
        vel.v.y = -vel.v.y * restitution;
    }
    if (p.v.x < r.*) {
        p.v.x = r.*;
        vel.v.x = -vel.v.x * restitution;
    } else if (p.v.x > width - r.*) {
        p.v.x = width - r.*;
        vel.v.x = -vel.v.x * restitution;
    }
}

pub fn main() !void {
    var world = try World.init(std.heap.page_allocator);
    defer world.deinit();

    var prng = std.Random.DefaultPrng.init(0x2026_0602);
    const rand = prng.random();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const e = try world.entity();
        try world.set(e, Position{ .v = .{ .x = rand.float(f32) * width, .y = rand.float(f32) * height * 0.5 } });
        try world.set(e, Velocity{ .v = .{ .x = (rand.float(f32) - 0.5) * 120, .y = 0 } });
        try world.set(e, @as(Radius, 4 + rand.float(f32) * 12));
        try world.set(e, rl.Color.init(rand.int(u8), rand.int(u8), rand.int(u8), 255));
    }

    try world.system(.on_update, "physics", .{ Position, Velocity, Radius }, step);

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

// The elaborate, headless integration suite lives in tests.zig and runs under `zig build test`.
comptime {
    if (@import("builtin").is_test) _ = @import("tests.zig");
}
