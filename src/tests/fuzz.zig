//! A deterministic fuzz test: drive the world with random operations and, after every batch,
//! compare it against an independent reference model. This is the strongest guard against bugs in
//! archetype moves, swap-remove record fixups, and cache invalidation.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

// Three data components and one tag, mirrored by the model below.
const FA = struct { v: u32 };
const FB = struct { v: u32 };
const FC = struct { v: u32 };
const FT = struct {}; // tag

const Shadow = struct {
    a: ?u32 = null,
    b: ?u32 = null,
    c: ?u32 = null,
    t: bool = false,
};

test "fuzz: the world matches an independent model across thousands of random operations" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var live: std.ArrayList(Entity) = .empty;
    defer live.deinit(testing.allocator);

    var model = std.AutoHashMap(Entity, Shadow).init(testing.allocator);
    defer model.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed_1234_abcd);
    const rand = prng.random();

    var step: usize = 0;
    while (step < 6000) : (step += 1) {
        const choice = rand.uintLessThan(u8, 100);
        if (choice < 30 or live.items.len == 0) {
            const e = try w.entity();
            try live.append(testing.allocator, e);
            try model.put(e, .{});
        } else if (choice < 45) {
            const idx = rand.uintLessThan(usize, live.items.len);
            const e = live.swapRemove(idx);
            w.delete(e);
            _ = model.remove(e);
        } else {
            const idx = rand.uintLessThan(usize, live.items.len);
            const e = live.items[idx];
            const m = model.getPtr(e).?;
            switch (rand.uintLessThan(u8, 8)) {
                0 => {
                    const v = rand.int(u32);
                    try w.set(e, FA{ .v = v });
                    m.a = v;
                },
                1 => {
                    const v = rand.int(u32);
                    try w.set(e, FB{ .v = v });
                    m.b = v;
                },
                2 => {
                    const v = rand.int(u32);
                    try w.set(e, FC{ .v = v });
                    m.c = v;
                },
                3 => {
                    try w.add(e, FT);
                    m.t = true;
                },
                4 => {
                    try w.remove(e, FA);
                    m.a = null;
                },
                5 => {
                    try w.remove(e, FB);
                    m.b = null;
                },
                6 => {
                    try w.remove(e, FC);
                    m.c = null;
                },
                else => {
                    try w.remove(e, FT);
                    m.t = false;
                },
            }
        }

        if (step % 25 == 0) try verify(&w, &model); // full checks are costly, so sample them
    }
    try verify(&w, &model);

    // Counts derived from the model must match the world's own counts.
    var count_a: usize = 0;
    var count_t: usize = 0;
    var it = model.valueIterator();
    while (it.next()) |s| {
        if (s.a != null) count_a += 1;
        if (s.t) count_t += 1;
    }
    try testing.expectEqual(count_a, w.count(.{FA}));
    try testing.expectEqual(count_t, w.count(.{FT}));
}

fn verify(w: *World, model: *std.AutoHashMap(Entity, Shadow)) !void {
    var it = model.iterator();
    while (it.next()) |entry| {
        const e = entry.key_ptr.*;
        const s = entry.value_ptr.*;
        try testing.expect(w.isAlive(e));

        try testing.expectEqual(s.a != null, w.has(e, FA));
        if (s.a) |v| try testing.expectEqual(v, w.get(e, FA).?.v);

        try testing.expectEqual(s.b != null, w.has(e, FB));
        if (s.b) |v| try testing.expectEqual(v, w.get(e, FB).?.v);

        try testing.expectEqual(s.c != null, w.has(e, FC));
        if (s.c) |v| try testing.expectEqual(v, w.get(e, FC).?.v);

        try testing.expectEqual(s.t, w.has(e, FT));
    }
}
