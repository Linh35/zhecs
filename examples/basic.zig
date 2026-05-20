const std = @import("std");
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { hp: i32 };
const Frozen = struct {}; // a tag (zero-size component)

// A relationship: `(Likes, someEntity)`.
const Likes = struct {};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    try walkthrough(gpa);
    try benchmark(gpa);
}

fn walkthrough(gpa: std.mem.Allocator) !void {
    std.debug.print("== walkthrough ==\n", .{});

    var world = try World.init(gpa);
    defer world.deinit();

    // Entities and components.
    const player = try world.entity();
    try world.set(player, Position{ .x = 0, .y = 0 });
    try world.set(player, Velocity{ .x = 1, .y = 0.5 });
    try world.set(player, Health{ .hp = 100 });

    const rock = try world.entity();
    try world.set(rock, Position{ .x = 10, .y = 10 });
    try world.add(rock, Frozen); // a tag: present or not, no data

    // A singleton holds world-wide data on a reserved entity.
    const Time = struct { elapsed: f32 };
    try world.setSingleton(Time{ .elapsed = 0 });

    // A relationship with an entity target.
    const apples = try world.entity();
    try world.addPair(player, Likes, apples);
    std.debug.print("player likes apples: {}\n", .{world.hasPair(player, Likes, apples)});

    // Parent/child via the built-in ChildOf relationship.
    const sword = try world.entity();
    try world.childOf(sword, player);
    std.debug.print("sword's parent is the player: {}\n", .{world.parent(sword).? == player});

    // A system: move everything that has both Position and Velocity, scaled by delta time.
    try world.system(.on_update, "move", .{ Position, Velocity }, struct {
        fn run(w: *World, _: Entity, p: *Position, v: *Velocity) void {
            p.x += v.x * w.delta_time;
            p.y += v.y * w.delta_time;
        }
    }.run);

    // Advance the world a few frames. The rock has no Velocity, so it does not move.
    var frame: usize = 0;
    while (frame < 10) : (frame += 1) {
        world.getSingleton(Time).?.elapsed += 1.0 / 60.0;
        try world.progress(1.0 / 60.0);
    }

    const pp = world.get(player, Position).?;
    std.debug.print("player after 10 frames: ({d:.3}, {d:.3})\n", .{ pp.x, pp.y });
    std.debug.print("rock stayed put: ({d:.3}, {d:.3})\n", .{ world.get(rock, Position).?.x, world.get(rock, Position).?.y });
    std.debug.print("time elapsed: {d:.3}s\n", .{world.getSingleton(Time).?.elapsed});

    // Ad-hoc iteration with each: count the living, damaged things.
    var alive: usize = 0;
    world.each(.{Health}, &alive, struct {
        fn run(count: *usize, _: Entity, h: *Health) void {
            if (h.hp > 0) count.* += 1;
        }
    }.run);
    std.debug.print("entities with positive health: {d}\n\n", .{alive});
}

fn benchmark(gpa: std.mem.Allocator) !void {
    std.debug.print("== benchmark (ReleaseFast for real numbers) ==\n", .{});

    const N = 1_000_000;
    const FRAMES = 60;

    // Pre-size the world: reserve the entity tables and the Position+Velocity archetype up front,
    // so the build loop below does not reallocate.
    var world = try World.initCapacity(gpa, .{ .entities = N });
    defer world.deinit();
    try world.reserve(.{ Position, Velocity }, N);

    // Build N entities that all carry Position + Velocity.
    const build_start = nowNs();
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const e = try world.entity();
        const f: f32 = @floatFromInt(i % 100);
        try world.set(e, Position{ .x = f, .y = f });
        try world.set(e, Velocity{ .x = 1, .y = -1 });
    }
    const build_ns = nowNs() - build_start;
    std.debug.print("created {d} entities (2 components each) in {d:.1} ms\n", .{ N, ms(build_ns) });

    // Per-row iteration via a registered system, run for FRAMES frames.
    try world.system(.on_update, "move", .{ Position, Velocity }, struct {
        fn run(w: *World, _: Entity, p: *Position, v: *Velocity) void {
            p.x += v.x * w.delta_time;
            p.y += v.y * w.delta_time;
        }
    }.run);

    const each_start = nowNs();
    var frame: usize = 0;
    while (frame < FRAMES) : (frame += 1) try world.progress(1.0 / 60.0);
    const each_ns = nowNs() - each_start;
    report("each (per row)", each_ns, N * FRAMES);

    // The same work through the chunk API, where the inner loop is ours and can vectorize.
    const run_start = nowNs();
    frame = 0;
    while (frame < FRAMES) : (frame += 1) {
        world.run(.{ Position, Velocity }, 1.0 / 60.0, struct {
            fn run(dt: f32, _: []const Entity, ps: []Position, vs: []Velocity) void {
                for (ps, vs) |*p, v| {
                    p.x += v.x * dt;
                    p.y += v.y * dt;
                }
            }
        }.run);
    }
    const run_ns = nowNs() - run_start;
    report("run  (per chunk)", run_ns, N * FRAMES);

    // Read the result back so the optimizer cannot elide the writes.
    var checksum: f64 = 0;
    world.each(.{Position}, &checksum, struct {
        fn run(sum: *f64, _: Entity, p: *Position) void {
            sum.* += p.x;
        }
    }.run);
    std.debug.print("  checksum (sum of x): {d:.0}\n", .{checksum});

    // Structural churn: toggle a tag on/off across many entities, which moves them between
    // archetypes. The cached add/remove edges keep this from allocating after the first move.
    const Marked = struct {};
    const churn_start = nowNs();
    var toggled: usize = 0;
    world.each(.{Position}, &toggled, struct {
        fn run(count: *usize, _: Entity, _: *Position) void {
            count.* += 1;
        }
    }.run);
    // Re-collect entities to toggle (avoid structural change during each).
    var ids = try std.ArrayList(Entity).initCapacity(gpa, N);
    defer ids.deinit(gpa);
    world.each(.{Velocity}, &ids, struct {
        fn run(list: *std.ArrayList(Entity), e: Entity, _: *Velocity) void {
            list.appendAssumeCapacity(e);
        }
    }.run);
    for (ids.items) |e| try world.add(e, Marked);
    for (ids.items) |e| try world.remove(e, Marked);
    const churn_ns = nowNs() - churn_start;
    std.debug.print("toggled a tag on {d} entities (add+remove, 2 archetype moves each) in {d:.1} ms\n", .{ ids.items.len, ms(churn_ns) });
}

fn report(label: []const u8, ns: u64, updates: u64) void {
    const u: f64 = @floatFromInt(updates);
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    std.debug.print("  {s}: {d:.1} ms, {d:.2} ns/update, {d:.0} M updates/sec\n", .{ label, ms(ns), @as(f64, @floatFromInt(ns)) / u, u / secs / 1e6 });
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
