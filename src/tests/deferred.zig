//! Deferred commands: structural changes recorded inside a defer scope and replayed when it closes.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;
const c = @import("common.zig");

test "a deferred change is invisible until the scope closes" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    w.beginDefer();
    try w.set(e, c.Position{ .x = 1, .y = 2 });
    try testing.expect(!w.has(e, c.Position)); // queued, not yet applied
    try w.endDefer();

    try testing.expect(w.has(e, c.Position));
    try testing.expectEqual(@as(f32, 1), w.get(e, c.Position).?.x);
}

test "reads inside a scope see committed state, not the queued write" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Health{ .hp = 10 });

    w.beginDefer();
    try w.set(e, c.Health{ .hp = 99 });
    try testing.expectEqual(@as(i32, 10), w.get(e, c.Health).?.hp); // still the old value
    try w.endDefer();
    try testing.expectEqual(@as(i32, 99), w.get(e, c.Health).?.hp);
}

test "queued changes apply in the order they were made" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    w.beginDefer();
    try w.set(e, c.Health{ .hp = 1 });
    try w.set(e, c.Health{ .hp = 2 });
    try w.set(e, c.Health{ .hp = 3 }); // last write wins
    try w.endDefer();
    try testing.expectEqual(@as(i32, 3), w.get(e, c.Health).?.hp);
}

test "add then remove of the same component within a scope nets out to absent" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    w.beginDefer();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    try w.remove(e, c.Position);
    try w.endDefer();
    try testing.expect(!w.has(e, c.Position));
}

test "a delete skips later queued changes aimed at the same entity" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, c.Health{ .hp = 5 });
    w.beginDefer();
    w.delete(e);
    try w.set(e, c.Health{ .hp = 6 }); // applied after the delete: skipped, not an error
    try w.endDefer();
    try testing.expect(!w.isAlive(e));
}

test "entities can be deleted while a query iterates, inside a defer scope" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Health{ .hp = @intCast(i) });
    }

    var ctx = .{ .w = &w };
    w.beginDefer();
    w.each(.{c.Health}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), e: Entity, h: *c.Health) void {
            if (@rem(h.hp, 2) == 0) x.w.delete(e); // delete the even ones
        }
    }.run);
    try w.endDefer();

    try testing.expectEqual(@as(usize, 5), w.count(.{c.Health})); // odds 1,3,5,7,9 remain
}

test "components can be added while a query iterates, inside a defer scope" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const e = try w.entity();
        try w.set(e, c.Position{ .x = 0, .y = 0 });
    }

    var ctx = .{ .w = &w };
    w.beginDefer();
    w.each(.{c.Position}, &ctx, struct {
        fn run(x: @TypeOf(&ctx), e: Entity, _: *c.Position) void {
            x.w.add(e, c.Frozen) catch {};
        }
    }.run);
    try w.endDefer();

    try testing.expectEqual(@as(usize, 6), w.count(.{ c.Position, c.Frozen }));
}

test "nested scopes only apply when the outermost closes" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    w.beginDefer();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    w.beginDefer();
    try w.set(e, c.Velocity{ .x = 0, .y = 0 });
    try w.endDefer(); // inner close: still nothing applied
    try testing.expect(!w.has(e, c.Position));
    try testing.expect(!w.has(e, c.Velocity));
    try w.endDefer(); // outer close: both apply
    try testing.expect(w.has(e, c.Position));
    try testing.expect(w.has(e, c.Velocity));
}

test "observers fire when a deferred change applies, not when it is queued" {
    const S = struct {
        var sets: usize = 0;
        fn onSet(_: *World, _: Entity) void {
            sets += 1;
        }
    };
    S.sets = 0;

    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.observe(c.Position, .on_set, S.onSet);

    const e = try w.entity();
    w.beginDefer();
    try w.set(e, c.Position{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(usize, 0), S.sets); // queued, hook not yet fired
    try w.endDefer();
    try testing.expectEqual(@as(usize, 1), S.sets);
}

test "deferred relationships apply like immediate ones" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    const target = try w.entity();
    w.beginDefer();
    try w.addPair(e, c.Likes, target);
    try testing.expect(!w.hasPair(e, c.Likes, target));
    try w.endDefer();
    try testing.expect(w.hasPair(e, c.Likes, target));
}

test "fuzz: batches of random changes applied in defer scopes match a model" {
    const Shadow = struct { p: bool = false, v: bool = false, h: ?i32 = null, f: bool = false };

    var w = try World.init(testing.allocator);
    defer w.deinit();

    const count = 40;
    var ents: [count]Entity = undefined;
    var model = [_]Shadow{.{}} ** count;
    try w.spawn(count, &ents);

    var prng = std.Random.DefaultPrng.init(0xd1ce_2026);
    const rand = prng.random();

    var batch: usize = 0;
    while (batch < 200) : (batch += 1) {
        const ops = rand.uintLessThan(usize, 12);
        w.beginDefer();
        var k: usize = 0;
        while (k < ops) : (k += 1) {
            const idx = rand.uintLessThan(usize, count);
            const e = ents[idx];
            const m = &model[idx];
            switch (rand.uintLessThan(u8, 6)) {
                0 => {
                    try w.set(e, c.Position{ .x = 0, .y = 0 });
                    m.p = true;
                },
                1 => {
                    const hp = rand.int(i32);
                    try w.set(e, c.Health{ .hp = hp });
                    m.h = hp;
                },
                2 => {
                    try w.add(e, c.Velocity);
                    m.v = true;
                },
                3 => {
                    try w.add(e, c.Frozen);
                    m.f = true;
                },
                4 => {
                    try w.remove(e, c.Position);
                    m.p = false;
                },
                else => {
                    try w.remove(e, c.Health);
                    m.h = null;
                },
            }
        }
        try w.endDefer();

        for (ents, 0..) |e, i| {
            try testing.expectEqual(model[i].p, w.has(e, c.Position));
            try testing.expectEqual(model[i].v, w.has(e, c.Velocity));
            try testing.expectEqual(model[i].f, w.has(e, c.Frozen));
            try testing.expectEqual(model[i].h != null, w.has(e, c.Health));
            if (model[i].h) |hp| try testing.expectEqual(hp, w.get(e, c.Health).?.hp);
        }
    }
}

test "a deferred batch lands exactly like the same batch applied immediately" {
    // Two worlds, the same sequence of add/set/remove. One applies immediately, the other defers.
    // With no deletes in the mix, the deferred replay must reproduce the immediate result exactly.
    var immediate = try World.init(testing.allocator);
    defer immediate.deinit();
    var deferred = try World.init(testing.allocator);
    defer deferred.deinit();

    var ea: [8]Entity = undefined;
    var eb: [8]Entity = undefined;
    for (&ea) |*s| s.* = try immediate.entity();
    for (&eb) |*s| s.* = try deferred.entity();

    deferred.beginDefer();
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        const v: u32 = @intCast(step * 7 + 1);
        // immediate world
        try immediate.set(ea[step], c.Health{ .hp = @intCast(v) });
        if (step % 2 == 0) try immediate.set(ea[step], c.Position{ .x = @floatFromInt(v), .y = 0 });
        if (step % 3 == 0) try immediate.remove(ea[step], c.Health);
        // deferred world, identical sequence
        try deferred.set(eb[step], c.Health{ .hp = @intCast(v) });
        if (step % 2 == 0) try deferred.set(eb[step], c.Position{ .x = @floatFromInt(v), .y = 0 });
        if (step % 3 == 0) try deferred.remove(eb[step], c.Health);
    }
    try deferred.endDefer();

    // Compare the two worlds entity by entity.
    for (ea, eb) |a, b| {
        try testing.expectEqual(immediate.has(a, c.Health), deferred.has(b, c.Health));
        try testing.expectEqual(immediate.has(a, c.Position), deferred.has(b, c.Position));
        if (immediate.has(a, c.Health)) try testing.expectEqual(immediate.get(a, c.Health).?.hp, deferred.get(b, c.Health).?.hp);
        if (immediate.has(a, c.Position)) try testing.expectEqual(immediate.get(a, c.Position).?.x, deferred.get(b, c.Position).?.x);
    }
}
