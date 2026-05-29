//! zhecs feeding Dear ImGui through zig-gamedev's zgui, with no graphics backend. The tests build
//! an entity inspector window each frame and ask ImGui to produce its draw data, then assert on
//! that data. No window or GPU is opened, so they run under `zig build test` anywhere; the draw
//! data is the proof that ECS state actually reached the UI.

const std = @import("std");
const testing = std.testing;
const zgui = @import("zgui");
const zhecs = @import("zhecs");
const World = zhecs.World;
const Entity = zhecs.Entity;

const Health = struct { hp: i32 };
const Name = struct { id: u32 };

// Build one inspector frame listing every entity that has Health, and return the draw data ImGui
// produced for it. Headless: no backend consumes the data, we only measure it.
fn inspectorFrame(w: *World) zgui.DrawData {
    zgui.io.setIniFilename(null); // headless: do not write an imgui.ini to disk
    // Tell ImGui the (absent) renderer manages textures itself, so a headless frame needs no
    // uploaded font atlas. This is the same flag zgui sets in its own no-backend tests.
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    zgui.io.setDisplaySize(1280, 720);
    zgui.io.setDeltaTime(1.0 / 60.0);
    zgui.newFrame();

    if (zgui.begin("Entities", .{})) {
        var ctx = .{ .shown = @as(usize, 0) };
        _ = &ctx;
        w.each(.{ Name, Health }, &ctx, struct {
            fn run(_: @TypeOf(&ctx), _: Entity, n: *Name, h: *Health) void {
                zgui.text("entity {d}: {d} hp", .{ n.id, h.hp });
            }
        }.run);
    }
    zgui.end();

    zgui.render();
    return zgui.getDrawData();
}

test "an entity inspector turns ECS state into ImGui draw data" {
    zgui.init(testing.allocator);
    defer zgui.deinit();
    _ = zgui.io.addFontDefault(null); // a font atlas so text has glyphs to emit

    var w = try World.init(testing.allocator);
    defer w.deinit();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const e = try w.entity();
        try w.set(e, Name{ .id = i });
        try w.set(e, Health{ .hp = @intCast(100 - i) });
    }

    _ = inspectorFrame(&w); // warm-up: ImGui prepares its font texture on the first frame
    const dd = inspectorFrame(&w);
    try testing.expect(dd.valid);
    try testing.expect(dd.cmd_lists_count >= 1);
    try testing.expect(dd.total_vtx_count > 0); // the text produced geometry
}

test "more entities mean more geometry: the UI tracks the world" {
    zgui.init(testing.allocator);
    defer zgui.deinit();
    _ = zgui.io.addFontDefault(null);

    var w = try World.init(testing.allocator);
    defer w.deinit();

    _ = inspectorFrame(&w); // warm-up frame before measuring

    // A small world first.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const e = try w.entity();
        try w.set(e, Name{ .id = i });
        try w.set(e, Health{ .hp = 50 });
    }
    const small = inspectorFrame(&w).total_vtx_count;

    // Grow it and rebuild the same inspector.
    while (i < 40) : (i += 1) {
        const e = try w.entity();
        try w.set(e, Name{ .id = i });
        try w.set(e, Health{ .hp = 50 });
    }
    const large = inspectorFrame(&w).total_vtx_count;

    try testing.expect(small > 0);
    try testing.expect(large > small); // every extra row of text added vertices
    try testing.expectEqual(@as(usize, 40), w.count(.{ Name, Health }));
}
