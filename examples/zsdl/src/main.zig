//! zhecs using SDL's geometry and colour types as components, through zig-gamedev's zsdl. These
//! tests do not open a window or call into SDL, so they link nothing and run headless: the point is
//! that SDL's value types drop into the ECS and that systems over them behave correctly. The scene
//! is a flock of rectangles that move, bounce off the field walls, and report axis-aligned overlaps.

const std = @import("std");
const testing = std.testing;
const sdl = @import("sdl"); // zsdl3
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

const field = sdl.FRect{ .x = 0, .y = 0, .w = 640, .h = 480 };

const Bounds = sdl.FRect; // x, y, w, h in floats: the sprite's box, used directly
const Velocity = struct { v: sdl.FPoint };
const Tint = sdl.Color;

// Axis-aligned overlap of two SDL rectangles.
fn overlaps(a: Bounds, b: Bounds) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

// Move a box and keep it inside the field, reversing velocity at the walls.
fn moveAndBounce(w: *World, _: Entity, b: *Bounds, vel: *Velocity) void {
    const dt = w.delta_time;
    b.x += vel.v.x * dt;
    b.y += vel.v.y * dt;
    if (b.x < field.x) {
        b.x = field.x;
        vel.v.x = -vel.v.x;
    } else if (b.x + b.w > field.w) {
        b.x = field.w - b.w;
        vel.v.x = -vel.v.x;
    }
    if (b.y < field.y) {
        b.y = field.y;
        vel.v.y = -vel.v.y;
    } else if (b.y + b.h > field.h) {
        b.y = field.h - b.h;
        vel.v.y = -vel.v.y;
    }
}

test "SDL rectangles as components: overlap detection is correct" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const a = try w.entity();
    try w.set(a, Bounds{ .x = 0, .y = 0, .w = 10, .h = 10 });
    const b = try w.entity();
    try w.set(b, Bounds{ .x = 5, .y = 5, .w = 10, .h = 10 }); // overlaps a
    const c = try w.entity();
    try w.set(c, Bounds{ .x = 100, .y = 100, .w = 10, .h = 10 }); // far away

    try testing.expect(overlaps(w.get(a, Bounds).?.*, w.get(b, Bounds).?.*));
    try testing.expect(!overlaps(w.get(a, Bounds).?.*, w.get(c, Bounds).?.*));
}

test "an ECS broadphase counts overlapping pairs over a deterministic layout" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    // A column of boxes on a 10px stride, each 15px tall, so every box overlaps only its neighbour.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const e = try w.entity();
        const fy: f32 = @floatFromInt(i);
        try w.set(e, Bounds{ .x = 0, .y = fy * 10, .w = 20, .h = 15 });
        try w.set(e, Tint{ .r = 255, .g = 0, .b = 0, .a = 255 });
    }

    // Gather every box, then count overlapping pairs: the classic ECS gather-then-process shape.
    var boxes: std.ArrayList(Bounds) = .empty;
    defer boxes.deinit(testing.allocator);
    var ctx = .{ .list = &boxes, .alloc = testing.allocator };
    w.each(.{Bounds}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, b: *Bounds) void {
            x.list.append(x.alloc, b.*) catch unreachable;
        }
    }.run);

    var pairs: usize = 0;
    for (boxes.items, 0..) |b1, idx| {
        for (boxes.items[idx + 1 ..]) |b2| {
            if (overlaps(b1, b2)) pairs += 1;
        }
    }
    try testing.expectEqual(@as(usize, 7), pairs); // a touching chain of eight has seven neighbour pairs
}

test "a movement system keeps SDL rects inside the field across many frames" {
    var w = try World.initCapacity(testing.allocator, .{ .entities = 200 });
    defer w.deinit();
    try w.reserve(.{ Bounds, Velocity }, 200);

    var ids: [200]Entity = undefined;
    try w.spawn(ids.len, &ids);
    var prng = std.Random.DefaultPrng.init(0x5d1);
    const rand = prng.random();
    for (ids) |e| {
        try w.set(e, Bounds{ .x = rand.float(f32) * 600, .y = rand.float(f32) * 440, .w = 16, .h = 16 });
        try w.set(e, Velocity{ .v = .{ .x = (rand.float(f32) - 0.5) * 300, .y = (rand.float(f32) - 0.5) * 300 } });
    }

    try w.system(.on_update, "move", .{ Bounds, Velocity }, moveAndBounce);
    var frame: usize = 0;
    while (frame < 400) : (frame += 1) try w.progress(1.0 / 60.0);

    var inside: usize = 0;
    var ctx = .{ .n = &inside };
    w.each(.{Bounds}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, b: *Bounds) void {
            if (b.x >= field.x and b.y >= field.y and b.x + b.w <= field.w + 0.01 and b.y + b.h <= field.h + 0.01) x.n.* += 1;
        }
    }.run);
    try testing.expectEqual(@as(usize, 200), inside);
}

test "a reused query handle checks overlaps against a player box" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const Player = struct {};
    const player = try w.entity();
    try w.set(player, Bounds{ .x = 0, .y = 0, .w = 30, .h = 30 });
    try w.add(player, Player);

    // Three obstacles straddle the origin where the player sits; two are far away.
    const spots = [_]sdl.FPoint{
        .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 5 }, .{ .x = -5, .y = 20 },
        .{ .x = 200, .y = 200 }, .{ .x = 400, .y = 100 },
    };
    for (spots) |s| {
        const e = try w.entity();
        try w.set(e, Bounds{ .x = s.x, .y = s.y, .w = 8, .h = 8 });
    }

    const boxes = try w.query(.{Bounds});
    const pbox = w.get(player, Bounds).?.*;
    var touching: usize = 0;
    var ctx = .{ .player = pbox, .hits = &touching };
    boxes.each(&ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, b: *Bounds) void {
            if (b.w == 30 and b.h == 30) return; // skip the player's own box
            if (overlaps(x.player, b.*)) x.hits.* += 1;
        }
    }.run);
    try testing.expectEqual(@as(usize, 3), touching);
}
