//! A small platformer on zhecs and raylib. The player runs and jumps under gravity, collides with
//! solid platforms by axis-separated AABB resolution, and dies the moment its box touches an enemy.
//! Enemies patrol between bounds. The game logic (gravity, collision, patrol, death) is plain
//! functions over the world with no raylib calls, so the tests at the bottom run headless and check
//! the real behaviour; `main` adds input and drawing on top. `zig build run` plays it.

const std = @import("std");
const rl = @import("raylib");
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

const screen_w = 800;
const screen_h = 450;
const gravity = 1400; // px/s^2
const move_speed = 220; // px/s
const jump_speed = 560; // px/s

// A body's box is a raylib Rectangle (x, y, width, height). Players, enemies, and platforms all
// have one; tags say which is which.
const Body = rl.Rectangle;
const Motion = struct { vx: f32 = 0, vy: f32 = 0, grounded: bool = false };
const Patrol = struct { min_x: f32, max_x: f32 };

const Player = struct {};
const Enemy = struct {};
const Solid = struct {};
const Dead = struct {};

fn overlaps(a: Body, b: Body) bool {
    return a.x < b.x + b.width and a.x + a.width > b.x and a.y < b.y + b.height and a.y + a.height > b.y;
}

// Copy the boxes of every entity that has `Tag` into `buf`, returning how many were written.
fn gather(w: *World, comptime Tag: type, buf: []Body) usize {
    var ctx: struct { buf: []Body, n: usize } = .{ .buf = buf, .n = 0 };
    w.each(.{ Tag, Body }, &ctx, struct {
        fn run(x: *@TypeOf(ctx), _: Entity, _: *Tag, b: *Body) void {
            if (x.n < x.buf.len) {
                x.buf[x.n] = b.*;
                x.n += 1;
            }
        }
    }.run);
    return ctx.n;
}

// Advance every moving body by `dt`: gravity, then move and resolve against the solids one axis at
// a time. Landing on top of a solid sets `grounded`, which is what gates jumping.
fn physicsStep(w: *World, dt: f32) void {
    var solid_buf: [64]Body = undefined;
    const solids = solid_buf[0..gather(w, Solid, &solid_buf)];

    var ctx: struct { solids: []const Body, dt: f32 } = .{ .solids = solids, .dt = dt };
    w.each(.{ Body, Motion }, &ctx, struct {
        fn run(x: *@TypeOf(ctx), _: Entity, b: *Body, m: *Motion) void {
            m.vy += gravity * x.dt;

            b.x += m.vx * x.dt;
            for (x.solids) |s| {
                if (!overlaps(b.*, s)) continue;
                b.x = if (m.vx > 0) s.x - b.width else s.x + s.width;
                m.vx = 0;
            }

            m.grounded = false;
            b.y += m.vy * x.dt;
            for (x.solids) |s| {
                if (!overlaps(b.*, s)) continue;
                if (m.vy > 0) {
                    b.y = s.y - b.height;
                    m.grounded = true;
                } else {
                    b.y = s.y + s.height;
                }
                m.vy = 0;
            }
        }
    }.run);
}

// Turn enemies around when they reach the edge of their patrol range.
fn enemyStep(w: *World) void {
    w.each(.{ Enemy, Body, Motion, Patrol }, {}, struct {
        fn run(_: void, _: Entity, _: *Enemy, b: *Body, m: *Motion, p: *Patrol) void {
            if (b.x <= p.min_x and m.vx < 0) m.vx = -m.vx;
            if (b.x + b.width >= p.max_x and m.vx > 0) m.vx = -m.vx;
        }
    }.run);
}

// Any player whose box touches an enemy gets the Dead tag. The add is deferred so it is safe to do
// while the query iterates.
fn deathCheck(w: *World) !void {
    var enemy_buf: [64]Body = undefined;
    const enemies = enemy_buf[0..gather(w, Enemy, &enemy_buf)];

    w.beginDefer();
    defer w.endDefer() catch {};
    var ctx: struct { w: *World, enemies: []const Body } = .{ .w = w, .enemies = enemies };
    w.each(.{ Player, Body }, &ctx, struct {
        fn run(x: *@TypeOf(ctx), e: Entity, _: *Player, b: *Body) void {
            for (x.enemies) |en| {
                if (overlaps(b.*, en)) {
                    x.w.add(e, Dead) catch {};
                    return;
                }
            }
        }
    }.run);
}

pub fn main() !void {
    var world = try World.init(std.heap.page_allocator);
    defer world.deinit();

    // Ground and a couple of floating platforms.
    inline for (.{
        Body{ .x = 0, .y = 420, .width = screen_w, .height = 30 },
        Body{ .x = 120, .y = 330, .width = 160, .height = 20 },
        Body{ .x = 420, .y = 260, .width = 180, .height = 20 },
    }) |plat| {
        const e = try world.entity();
        try world.set(e, plat);
        try world.add(e, Solid);
    }

    const player = try world.entity();
    try world.set(player, Body{ .x = 60, .y = 360, .width = 28, .height = 40 });
    try world.set(player, Motion{});
    try world.add(player, Player);

    inline for (.{
        .{ Body{ .x = 440, .y = 220, .width = 30, .height = 30 }, Patrol{ .min_x = 420, .max_x = 600 } },
        .{ Body{ .x = 140, .y = 290, .width = 30, .height = 30 }, Patrol{ .min_x = 120, .max_x = 280 } },
    }) |spec| {
        const e = try world.entity();
        try world.set(e, spec[0]);
        try world.set(e, Motion{ .vx = 60 });
        try world.set(e, spec[1]);
        try world.add(e, Enemy);
    }

    rl.initWindow(screen_w, screen_h, "zhecs platformer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const alive = !world.has(player, Dead);

        if (alive) {
            const m = world.getMut(player, Motion).?;
            m.vx = 0;
            if (rl.isKeyDown(.right)) m.vx = move_speed;
            if (rl.isKeyDown(.left)) m.vx = -move_speed;
            if (rl.isKeyPressed(.space) and m.grounded) m.vy = -jump_speed;

            enemyStep(&world);
            physicsStep(&world, dt);
            try deathCheck(&world);
        } else if (rl.isKeyPressed(.r)) {
            try world.remove(player, Dead);
            world.getMut(player, Body).?.* = .{ .x = 60, .y = 360, .width = 28, .height = 40 };
            world.getMut(player, Motion).?.* = .{};
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.init(30, 30, 40, 255));

        var solids: [64]Body = undefined;
        for (solids[0..gather(&world, Solid, &solids)]) |s| rl.drawRectangleRec(s, rl.Color.init(90, 90, 110, 255));
        var enemies: [64]Body = undefined;
        for (enemies[0..gather(&world, Enemy, &enemies)]) |en| rl.drawRectangleRec(en, rl.Color.red);
        rl.drawRectangleRec(world.get(player, Body).?.*, if (alive) rl.Color.init(80, 200, 120, 255) else rl.Color.init(120, 120, 120, 255));

        if (!alive) rl.drawText("You died. Press R to respawn.", 250, 200, 20, rl.Color.ray_white);
    }
}

// --- headless game-logic tests -------------------------------------------------------------------

const testing = std.testing;

fn ground(w: *World, rect: Body) !void {
    const e = try w.entity();
    try w.set(e, rect);
    try w.add(e, Solid);
}

test "the player falls under gravity and lands on a platform, becoming grounded" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try ground(&w, .{ .x = 0, .y = 300, .width = 400, .height = 20 });

    const p = try w.entity();
    try w.set(p, Body{ .x = 100, .y = 0, .width = 20, .height = 20 });
    try w.set(p, Motion{});
    try w.add(p, Player);

    var i: usize = 0;
    while (i < 240) : (i += 1) physicsStep(&w, 1.0 / 60.0);

    const b = w.get(p, Body).?;
    try testing.expectApproxEqAbs(@as(f32, 280), b.y, 0.5); // rests on the platform top (300 - 20)
    try testing.expect(w.get(p, Motion).?.grounded);
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(p, Motion).?.vy, 0.001);
}

test "a grounded player that jumps rises and then lands again" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try ground(&w, .{ .x = 0, .y = 300, .width = 400, .height = 20 });
    const p = try w.entity();
    try w.set(p, Body{ .x = 100, .y = 280, .width = 20, .height = 20 });
    try w.set(p, Motion{ .grounded = true });
    try w.add(p, Player);

    physicsStep(&w, 1.0 / 60.0); // settle on the ground
    w.getMut(p, Motion).?.vy = -jump_speed; // jump

    var min_y: f32 = 280;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        physicsStep(&w, 1.0 / 60.0);
        min_y = @min(min_y, w.get(p, Body).?.y);
    }
    try testing.expect(min_y < 240); // it climbed at least 40px
    try testing.expectApproxEqAbs(@as(f32, 280), w.get(p, Body).?.y, 0.5); // and came back to rest
}

test "a moving player is stopped by a wall instead of passing through it" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try ground(&w, .{ .x = 0, .y = 200, .width = 400, .height = 200 }); // floor to run along
    try ground(&w, .{ .x = 200, .y = 0, .width = 20, .height = 200 }); // a wall rising from the floor

    const p = try w.entity();
    try w.set(p, Body{ .x = 100, .y = 180, .width = 20, .height = 20 }); // standing on the floor
    try w.set(p, Motion{ .vx = 300 });
    try w.add(p, Player);

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        w.getMut(p, Motion).?.vx = 300; // keep pushing right
        physicsStep(&w, 1.0 / 60.0);
    }
    try testing.expectApproxEqAbs(@as(f32, 180), w.get(p, Body).?.x, 0.5); // stopped at wall.x - width (200 - 20)
}

test "touching an enemy kills the player, and staying clear keeps it alive" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const enemy = try w.entity();
    try w.set(enemy, Body{ .x = 100, .y = 100, .width = 30, .height = 30 });
    try w.add(enemy, Enemy);

    const p = try w.entity();
    try w.set(p, Body{ .x = 500, .y = 100, .width = 20, .height = 20 }); // far from the enemy
    try w.add(p, Player);

    try deathCheck(&w);
    try testing.expect(!w.has(p, Dead)); // clear, still alive

    w.getMut(p, Body).?.* = .{ .x = 110, .y = 110, .width = 20, .height = 20 }; // step onto the enemy
    try deathCheck(&w);
    try testing.expect(w.has(p, Dead)); // dead on contact
}

test "an enemy reverses direction at the edge of its patrol range" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, Body{ .x = 270, .y = 100, .width = 30, .height = 30 }); // right edge: 300 == max_x
    try w.set(e, Motion{ .vx = 60 });
    try w.set(e, Patrol{ .min_x = 100, .max_x = 300 });
    try w.add(e, Enemy);

    enemyStep(&w);
    try testing.expect(w.get(e, Motion).?.vx < 0); // turned back from the right edge

    w.getMut(e, Body).?.x = 100; // left edge
    enemyStep(&w);
    try testing.expect(w.get(e, Motion).?.vx > 0); // turned back from the left edge
}
