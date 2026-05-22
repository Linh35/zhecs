//! Interop with other libraries. Components are plain Zig types, so types from a graphics, audio,
//! or physics library drop in as components without ceremony. These types are shaped like the ones
//! a binding such as zig-raylib exposes (vectors, colours, texture and sound handles, matrices,
//! callbacks), so the suite proves they store and read back correctly across table moves.
//!
//! One caveat the tests make concrete: a table move copies component bytes directly, so a component
//! that owns a resource (a GPU texture, an audio buffer) is copied by its handle, not duplicated,
//! and zhecs does not free it for you. Unload such resources yourself when you remove or delete.

const std = @import("std");
const testing = std.testing;
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

// raylib-shaped value types.
const Vector2 = extern struct { x: f32, y: f32 };
const Vector3 = extern struct { x: f32, y: f32, z: f32 };
const Color = extern struct { r: u8, g: u8, b: u8, a: u8 };
const Rectangle = extern struct { x: f32, y: f32, width: f32, height: f32 };
const Matrix = extern struct { m: [16]f32 }; // 64 bytes, 4-byte aligned

// A texture handle: an id into the graphics driver plus some metadata, exactly the kind of POD
// handle a renderer hands back. Storing it by value is the correct, intended use.
const Texture2D = extern struct { id: u32, width: i32, height: i32, mipmaps: i32, format: i32 };

// A component that owns a pointer into a resource the library manages.
const AudioBuffer = struct { samples: [*]f32, len: usize };

// Animation state as an enum plus a frame cursor.
const AnimState = enum(u8) { idle, walk, run, jump };
const Animation = struct { state: AnimState, frame: u16, frames: [8]u16 };

// A behaviour component holding a function pointer, as a scripting or callback layer might.
const Behaviour = struct { tick: *const fn (Entity) void };

test "graphics value types store and read back across a table move" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, Vector2{ .x = 3, .y = 4 });
    try w.set(e, Color{ .r = 10, .g = 20, .b = 30, .a = 255 });
    try w.set(e, Rectangle{ .x = 1, .y = 2, .width = 64, .height = 32 });
    try w.set(e, Texture2D{ .id = 7, .width = 256, .height = 256, .mipmaps = 1, .format = 4 });
    try w.set(e, Vector3{ .x = 0, .y = 1, .z = 0 }); // each set moves the entity to a wider table

    try testing.expectEqual(@as(f32, 3), w.get(e, Vector2).?.x);
    try testing.expectEqual(@as(u8, 255), w.get(e, Color).?.a);
    try testing.expectEqual(@as(f32, 64), w.get(e, Rectangle).?.width);
    try testing.expectEqual(@as(u32, 7), w.get(e, Texture2D).?.id);
    try testing.expectEqual(@as(f32, 1), w.get(e, Vector3).?.y);
}

test "a 64-byte matrix component survives moves intact" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    var mat: Matrix = .{ .m = undefined };
    for (&mat.m, 0..) |*v, i| v.* = @floatFromInt(i);
    try w.set(e, mat);
    try w.set(e, Vector2{ .x = 0, .y = 0 }); // move

    const got = w.get(e, Matrix).?;
    for (got.m, 0..) |v, i| try testing.expectEqual(@as(f32, @floatFromInt(i)), v);
}

test "a component that owns a pointer keeps the handle across a move (shallow copy, as intended)" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var samples = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const e = try w.entity();
    try w.set(e, AudioBuffer{ .samples = &samples, .len = samples.len });
    try w.set(e, Vector2{ .x = 0, .y = 0 }); // move to a wider table

    const buf = w.get(e, AudioBuffer).?;
    try testing.expectEqual(@as(usize, 4), buf.len);
    try testing.expectEqual(@as(f32, 0.3), buf.samples[2]); // the pointer still reaches the data
}

test "enums, fixed arrays, and function pointers all work as components" {
    const H = struct {
        var ticked: usize = 0;
        fn tick(_: Entity) void {
            ticked += 1;
        }
    };
    H.ticked = 0;

    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    try w.set(e, Animation{ .state = .walk, .frame = 2, .frames = .{ 0, 1, 2, 3, 4, 5, 6, 7 } });
    try w.set(e, Behaviour{ .tick = H.tick });

    try testing.expectEqual(AnimState.walk, w.get(e, Animation).?.state);
    try testing.expectEqual(@as(u16, 3), w.get(e, Animation).?.frames[3]);

    w.get(e, Behaviour).?.tick(e); // call the stored callback
    try testing.expectEqual(@as(usize, 1), H.ticked);
}

test "a render-style pass reads several library components through a query" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const e = try w.entity();
        try w.set(e, Vector2{ .x = @floatFromInt(i), .y = 0 });
        try w.set(e, Texture2D{ .id = @intCast(i), .width = 16, .height = 16, .mipmaps = 1, .format = 4 });
    }

    var drawn: usize = 0;
    var id_sum: u64 = 0;
    var ctx = .{ .drawn = &drawn, .ids = &id_sum };
    w.run(.{ Vector2, Texture2D }, &ctx, struct {
        fn run(x: @TypeOf(&ctx), ents: []const Entity, pos: []Vector2, tex: []Texture2D) void {
            x.drawn.* += ents.len;
            for (pos, tex) |p, t| {
                _ = p;
                x.ids.* += t.id;
            }
        }
    }.run);

    try testing.expectEqual(@as(usize, 50), drawn);
    try testing.expectEqual(@as(u64, 49 * 50 / 2), id_sum); // 0 + 1 + ... + 49
}
