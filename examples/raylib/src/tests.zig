//! An elaborate, headless integration suite: a small game's worth of systems built on zhecs with
//! raylib's own types as components. No window is opened, so these run anywhere `zig build test`
//! does. They lean on every part of zhecs at once: phases, queries, query handles, relationships,
//! observers, deferred structural change during iteration, batch spawn, and singletons.

const std = @import("std");
const testing = std.testing;
const rl = @import("raylib");
const zhecs = @import("zhecs");
const demo = @import("main.zig"); // the physics scene the windowed demo runs
const World = zhecs.World;
const Entity = zhecs.Entity;

const bounds = rl.Vector2{ .x = 320, .y = 240 };

// Two roles share raylib's Vector2, so each gets its own one-field component type.
const Position = struct { v: rl.Vector2 };
const Velocity = struct { v: rl.Vector2 };
const LocalOffset = struct { v: rl.Vector2 };

// Roles with a unique type go in directly.
const Sprite = struct { tex: rl.Texture2D, tint: rl.Color, origin: rl.Vector2 };
const Health = struct { hp: i32, max: i32 };
const Lifetime = struct { ttl: f32 };
const Camera = rl.Camera2D; // a singleton

const Enemy = struct {};
const Player = struct {};

fn move(w: *World, _: Entity, p: *Position, vel: *Velocity) void {
    const dt = w.delta_time;
    p.v.x += vel.v.x * dt;
    p.v.y += vel.v.y * dt;
}

fn bounce(_: *World, _: Entity, p: *Position, vel: *Velocity) void {
    if (p.v.x < 0) {
        p.v.x = 0;
        vel.v.x = -vel.v.x;
    } else if (p.v.x > bounds.x) {
        p.v.x = bounds.x;
        vel.v.x = -vel.v.x;
    }
    if (p.v.y < 0) {
        p.v.y = 0;
        vel.v.y = -vel.v.y;
    } else if (p.v.y > bounds.y) {
        p.v.y = bounds.y;
        vel.v.y = -vel.v.y;
    }
}

test "a multi-phase pipeline moves and bounces a crowd of raylib-typed entities for many frames" {
    var w = try World.initCapacity(testing.allocator, .{ .entities = 512 });
    defer w.deinit();
    try w.reserve(.{ Position, Velocity }, 512);

    var ids: [512]Entity = undefined;
    try w.spawn(ids.len, &ids);
    var prng = std.Random.DefaultPrng.init(0xa11ce);
    const rand = prng.random();
    for (ids) |e| {
        try w.set(e, Position{ .v = .{ .x = rand.float(f32) * bounds.x, .y = rand.float(f32) * bounds.y } });
        try w.set(e, Velocity{ .v = .{ .x = (rand.float(f32) - 0.5) * 80, .y = (rand.float(f32) - 0.5) * 80 } });
    }

    try w.system(.on_update, "move", .{ Position, Velocity }, move);
    try w.system(.on_validate, "bounce", .{ Position, Velocity }, bounce);

    var frame: usize = 0;
    while (frame < 600) : (frame += 1) try w.progress(1.0 / 60.0);

    // After bouncing, every entity stays inside the field.
    var ctx: struct { ok: bool } = .{ .ok = true };
    w.each(.{Position}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), _: Entity, p: *Position) void {
            if (p.v.x < 0 or p.v.x > bounds.x or p.v.y < 0 or p.v.y > bounds.y) x.ok = false;
        }
    }.run);
    try testing.expect(ctx.ok);
    try testing.expectEqual(@as(usize, 512), w.count(.{ Position, Velocity }));
}

test "a scene hierarchy resolves child world positions through ChildOf" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    // A parent at a known spot, with three children at local offsets.
    const parent = try w.entity();
    try w.set(parent, Position{ .v = .{ .x = 100, .y = 50 } });

    const offsets = [_]rl.Vector2{ .{ .x = 5, .y = 0 }, .{ .x = -5, .y = 10 }, .{ .x = 0, .y = -8 } };
    var kids: [3]Entity = undefined;
    for (&kids, offsets) |*kid, off| {
        kid.* = try w.entity();
        try w.set(kid.*, LocalOffset{ .v = off });
        try w.set(kid.*, Position{ .v = .{ .x = 0, .y = 0 } });
        try w.childOf(kid.*, parent);
    }

    // Resolve each child: world = parent world + local offset. Parents have no LocalOffset, so the
    // query only visits children, and getTarget hands back the parent to read.
    var ctx = .{ .w = &w };
    w.each(.{ Position, LocalOffset }, &ctx, struct {
        fn run(x: @TypeOf(&ctx), e: Entity, p: *Position, off: *LocalOffset) void {
            const par = x.w.parent(e).?;
            const base = x.w.get(par, Position).?.v;
            p.v = .{ .x = base.x + off.v.x, .y = base.y + off.v.y };
        }
    }.run);

    try testing.expectEqual(@as(f32, 105), w.get(kids[0], Position).?.v.x);
    try testing.expectEqual(@as(f32, 60), w.get(kids[1], Position).?.v.y);
    try testing.expectEqual(@as(f32, 42), w.get(kids[2], Position).?.v.y);
}

test "lifetimes expire and the dead are reaped with a deferred delete during iteration" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var ids: [100]Entity = undefined;
    try w.spawn(ids.len, &ids);
    for (ids, 0..) |e, i| {
        try w.set(e, Lifetime{ .ttl = @floatFromInt(i) }); // ttl 0..99 seconds
        try w.set(e, Enemy{});
    }

    // Each tick: age everything by one second, and delete whatever has run out. The delete happens
    // inside the query, which is safe because progress runs systems in a defer scope.
    try w.system(.on_update, "age", .{Lifetime}, struct {
        fn run(world: *World, e: Entity, l: *Lifetime) void {
            l.ttl -= 1;
            if (l.ttl < 0) world.delete(e);
        }
    }.run);

    var tick: usize = 0;
    while (tick < 50) : (tick += 1) try w.progress(1.0);
    // After 50 ticks, the 50 entities that started with ttl 0..49 are gone.
    try testing.expectEqual(@as(usize, 50), w.count(.{Enemy}));
}

test "observers count spawns and deaths as components come and go" {
    const Track = struct {
        var born: usize = 0;
        var died: usize = 0;
        fn onAdd(_: *World, _: Entity) void {
            born += 1;
        }
        fn onRemove(_: *World, _: Entity) void {
            died += 1;
        }
    };
    Track.born = 0;
    Track.died = 0;

    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.observe(Health, .on_add, Track.onAdd);
    try w.observe(Health, .on_remove, Track.onRemove);

    var ids: [30]Entity = undefined;
    try w.spawn(ids.len, &ids);
    for (ids) |e| try w.set(e, Health{ .hp = 100, .max = 100 });
    try testing.expectEqual(@as(usize, 30), Track.born);

    // Kill ten of them through a deferred scope.
    w.beginDefer();
    for (ids[0..10]) |e| try w.remove(e, Health);
    try w.endDefer();
    try testing.expectEqual(@as(usize, 10), Track.died);
    try testing.expectEqual(@as(usize, 20), w.count(.{Health}));
}

test "a reused query handle collects a stable render list across frames" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var ids: [40]Entity = undefined;
    try w.spawn(ids.len, &ids);
    for (ids, 0..) |e, i| {
        try w.set(e, Position{ .v = .{ .x = @floatFromInt(i), .y = 0 } });
        try w.set(e, Sprite{
            .tex = .{ .id = @intCast(i), .width = 16, .height = 16, .mipmaps = 1, .format = .uncompressed_r8g8b8a8 },
            .tint = rl.Color.white,
            .origin = .{ .x = 8, .y = 8 },
        });
    }

    const renderables = try w.query(.{ Position, Sprite });

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(testing.allocator);

    var frame: usize = 0;
    while (frame < 120) : (frame += 1) {
        list.clearRetainingCapacity();
        var ctx = .{ .list = &list, .alloc = testing.allocator };
        renderables.each(&ctx, struct {
            fn run(x: @TypeOf(&ctx), _: Entity, _: *Position, s: *Sprite) void {
                x.list.append(x.alloc, s.tex.id) catch unreachable;
            }
        }.run);
        try testing.expectEqual(@as(usize, 40), list.items.len);
    }
    try testing.expectEqual(@as(usize, 40), renderables.count());
}

test "a Camera2D singleton holds the view and a system pans it" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    try w.setSingleton(Camera{
        .offset = .{ .x = 160, .y = 120 },
        .target = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = 1,
    });

    // A focus entity the camera should track.
    const focus = try w.entity();
    try w.set(focus, Position{ .v = .{ .x = 0, .y = 0 } });
    try w.set(focus, Velocity{ .v = .{ .x = 30, .y = 0 } });
    try w.system(.on_update, "move", .{ Position, Velocity }, move);

    var frame: usize = 0;
    while (frame < 60) : (frame += 1) {
        try w.progress(1.0 / 60.0);
        const p = w.get(focus, Position).?.v;
        w.getSingleton(Camera).?.target = p; // camera follows
    }

    try testing.expectApproxEqAbs(@as(f32, 30), w.getSingleton(Camera).?.target.x, 1e-3);
    try testing.expectEqual(@as(f32, 1), w.getSingleton(Camera).?.zoom);
}

test "the physics scene: a dropped ball settles on the floor, each bounce lower than the last" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const r: demo.Radius = 10;
    const ball = try w.entity();
    try w.set(ball, demo.Position{ .v = .{ .x = demo.width / 2, .y = 40 } });
    try w.set(ball, demo.Velocity{ .v = .{ .x = 0, .y = 0 } });
    try w.set(ball, r);

    try w.system(.on_update, "physics", .{ demo.Position, demo.Velocity, demo.Radius }, demo.step);

    const floor = demo.height - r;
    var bounces: usize = 0;
    var prev_peak: f32 = std.math.inf(f32);
    var last_y: f32 = 40;
    var was_falling = true;

    var frame: usize = 0;
    while (frame < 2400) : (frame += 1) {
        try w.progress(1.0 / 120.0);
        const y = w.get(ball, demo.Position).?.v.y;

        try testing.expect(y <= floor + 0.01); // gravity plus collision never let it sink through

        const falling = y > last_y;
        if (!falling and was_falling) { // an apex: motion just turned from down to up
            const apex_height = floor - y;
            try testing.expect(apex_height <= prev_peak + 0.01); // restitution means peaks only shrink
            prev_peak = apex_height;
            bounces += 1;
        }
        was_falling = falling;
        last_y = y;
    }

    try testing.expect(bounces >= 4); // it really bounced
    try testing.expectApproxEqAbs(floor, w.get(ball, demo.Position).?.v.y, 1.0); // and came to rest
}

test "texture handles ride along through a stack of table moves" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const tex = rl.Texture2D{ .id = 99, .width = 64, .height = 32, .mipmaps = 1, .format = .uncompressed_r8g8b8a8 };
    try w.set(e, Sprite{ .tex = tex, .tint = rl.Color.red, .origin = .{ .x = 0, .y = 0 } });
    // Pile on more components so the entity migrates through several archetypes.
    try w.set(e, Position{ .v = .{ .x = 1, .y = 1 } });
    try w.set(e, Velocity{ .v = .{ .x = 0, .y = 0 } });
    try w.set(e, Health{ .hp = 1, .max = 1 });
    try w.add(e, Player);

    const got = w.get(e, Sprite).?;
    try testing.expectEqual(@as(u32, 99), got.tex.id);
    try testing.expectEqual(@as(c_int, 64), got.tex.width);
    try testing.expectEqual(@as(u8, 230), got.tint.r);
}
