# zhecs

An entity component system for Zig 0.16, small enough to read in an afternoon and quick enough to lean on. The design borrows its vocabulary from [flecs](https://github.com/SanderMertens/flecs): a world that holds entities, components that are plain data, tags, relationships between entities, queries, observers, and a pipeline of systems that runs in phases. The implementation is the Zig version of those ideas, written to feel native to the language rather than translated into it.

It is a first draft. The core is complete and well tested. A handful of larger features are still ahead, and they are listed plainly near the end so you know what you are getting.

## The idea

You describe the things in your world by the data they carry. A position, a velocity, a hit point total. In zhecs each of those is an ordinary Zig type, and you attach values to entities by that type:

```zig
const Position = struct { x: f32, y: f32 };
try world.set(player, Position{ .x = 0, .y = 0 });
const here = world.get(player, Position).?;
```

There is no registration step and no string lookup at the call site. You hand the library a type and it does the bookkeeping. Underneath, every type is given a stable runtime identifier the first time it is seen, and that identifier is what lets the harder features work: relationships that point at other entities, the ability to ask an entity which components it carries, and the tables that make iteration fast.

That last part is worth dwelling on. Entities that carry the same set of components are stored together in one table, with a tightly packed column for each component. Walking a query is then a walk down a few columns that sit next to each other in memory, which is the kind of access a modern processor rewards. Adding or removing a component moves an entity from one table to another, and the cost of that move is the price you pay for the speed of the reads.

## Building

You need Zig 0.16.

```sh
zig build test                              # run every test
zig build example                           # build and run the walkthrough plus a benchmark
zig build example -Doptimize=ReleaseFast    # the benchmark with numbers worth quoting
```

To use it from another project, expose the module in your `build.zig` and import it by name:

```zig
exe.root_module.addImport("zhecs", zhecs_dep.module("zhecs"));
```

```zig
const zhecs = @import("zhecs");
```

## A walk through the world

Create a world against an allocator and remember to free it. The world owns a single arena, so freeing is one quiet operation rather than a long unwinding.

```zig
var world = try zhecs.World.init(allocator);
defer world.deinit();
```

Entities are handles. You make them, give them components, read those components back, and delete them when they have served their purpose. A deleted handle stays dead even if its slot is reused, because each slot carries a generation that moves on after a delete.

```zig
const e = try world.entity();
try world.set(e, Position{ .x = 1, .y = 2 });
try world.set(e, Velocity{ .x = 0.5, .y = 0 });

world.getMut(e, Position).?.x += 10;
try world.remove(e, Velocity);
world.delete(e);
```

A component with no fields is a tag. It says something is true of an entity without carrying any data, and it costs no storage.

```zig
const Frozen = struct {};
try world.add(e, Frozen);
if (world.has(e, Frozen)) { ... }
```

### Asking questions

The plainest way to walk the entities that match a set of components is an iterator. `view` gives you one, and inside the loop `it.get(T)` hands back a pointer to the current entity's `T`. Nothing to thread through, just a loop that reads its own scope.

```zig
var it = world.view(.{ Position, Velocity });
while (it.next()) |entity| {
    const p = it.get(Position);
    const v = it.get(Velocity);
    p.x += v.x;
    p.y += v.y;
    _ = entity;
}
```

If you prefer a callback, `each` hands your function one entity at a time with a typed pointer per term, along with a context value of your choosing.

```zig
world.each(.{ Position, Velocity }, {}, struct {
    fn run(_: void, ent: zhecs.Entity, p: *Position, v: *Velocity) void {
        p.x += v.x;
        p.y += v.y;
        _ = ent;
    }
}.run);
```

For the fastest sweep over a large set, `run` hands your function whole column slices for each matching table at once and leaves the inner loop to you. Because the loop body is yours and the slices are contiguous, the compiler is free to vectorize it.

```zig
world.run(.{ Position, Velocity }, dt, struct {
    fn run(step: f32, ents: []const zhecs.Entity, ps: []Position, vs: []Velocity) void {
        for (ps, vs) |*p, v| {
            p.x += v.x * step;
            p.y += v.y * step;
        }
        _ = ents;
    }
}.run);
```

A query matches any entity that has at least the components you name. An entity carrying Position, Velocity and Health still answers a query for Position alone. The order of the terms never changes which entities match, and `world.count(.{ ... })` gives you the size of a match without iterating it.

### Systems and the pipeline

A system is a query with a job and a place in the frame. You register it against a phase, and `progress` runs every system once, phase by phase, in the order the phases are declared. Within a phase, systems run in the order you registered them. A system receives the world as its first argument, so it can read `world.delta_time` and time its work to the frame.

```zig
try world.system(.on_update, "move", .{ Position, Velocity }, struct {
    fn run(w: *zhecs.World, _: zhecs.Entity, p: *Position, v: *Velocity) void {
        p.x += v.x * w.delta_time;
        p.y += v.y * w.delta_time;
    }
}.run);

try world.progress(1.0 / 60.0);
```

The phases are `on_load`, `post_load`, `pre_update`, `on_update`, `on_validate`, `post_update`, `pre_store`, and `on_store`, and they run in that sequence. A whole `progress` pass runs inside a defer scope, described next, so a system may add, remove, and delete freely while it runs. Those changes take effect once the pass finishes. During a frame, systems speak to one another through component values, which they edit in place through the pointers a query hands them.

### Reusable queries

If you run the same query many times, compile it once into a handle. The handle keeps the resolved component ids and a pointer to its match cache, so each sweep skips the small amount of work the loose `each` does to find them. It refreshes itself when a new kind of table appears, and it stays valid for the life of the world.

```zig
const movers = try world.query(.{ Position, Velocity });
// later, every frame
movers.each(dt, moveFn);
var it = movers.iterator(); // or walk it with a while loop, like world.view
const n = movers.count();
```

### Spawning a crowd

When you need many entities at once, `spawn` makes them in one go and grows the entity tables a single time rather than once per entity. The new entities arrive bare, ready to be given their parts.

```zig
var ids: [1000]zhecs.Entity = undefined;
try world.spawn(ids.len, &ids);
for (ids) |e| try world.set(e, Position{ .x = 0, .y = 0 });
```

## Changing the world while it iterates

Adding a component to an entity moves it to another table, which would pull the ground from under a query that is walking that table. To make this safe, open a defer scope. While one is open, the structural calls (`add`, `set`, `remove`, `addPair`, `removePair`, `delete`) record what you asked for rather than doing it at once, and the recorded changes are applied in order when the outermost scope closes. Reads in the meantime see the world as it stands, so a value you queue with `set` is not visible until the scope closes. Observers fire when the change lands, not when you queue it.

```zig
world.beginDefer();
world.each(.{ Health }, &world, struct {
    fn run(w: *zhecs.World, e: zhecs.Entity, h: *Health) void {
        if (h.hp <= 0) w.delete(e); // recorded, applied after the sweep
    }
}.run);
try world.endDefer();
```

Systems do not need to do this themselves, since `progress` already runs them inside a scope.

### Relationships

An entity can be related to another entity. A child to its parent, a creature to the thing it likes, an item to its owner. A relationship is named by a type and points at a target entity, and you can add several of them, ask whether one holds, and read a target back.

```zig
const Likes = struct {};
try world.addPair(e, Likes, apple);
try world.addPair(e, Likes, pear);
const fav = world.getTarget(e, Likes); // ?Entity

try world.childOf(child, parent);       // the built-in ChildOf relationship
const mum = world.parent(child);        // ?Entity
```

A relationship records its target by slot, so the handle you read back carries that slot's present generation. If the target has been deleted, the handle you get is not alive, and you can check that with `isAlive`. Hold on to targets you care about in your own structures rather than trusting the relationship to keep them alive for you.

### Singletons and observers

Some data belongs to the world rather than to any one entity. The time of day, the strength of gravity. Store it on the world as a singleton.

```zig
const Gravity = struct { v: f32 };
try world.setSingleton(Gravity{ .v = 9.8 });
const g = world.getSingleton(Gravity).?;
```

When you want to react to a change rather than poll for it, register an observer. It fires when a component is added to an entity, when it is set, or when it is removed.

```zig
try world.observe(Position, .on_set, struct {
    fn hook(w: *zhecs.World, ent: zhecs.Entity) void { _ = w; _ = ent; }
}.hook);
```

## Memory

A world keeps one arena and takes every lasting allocation from it. Nothing is freed or shrunk while the world lives. Deleting an entity keeps the slot for the next one, removing a component keeps the column it leaves behind, and the tables and indexes only ever grow. That single fact is why the arena suits the job so well, and why `deinit` is one reset rather than a careful teardown. The base allocator you pass in is touched only for the short-lived scratch the library needs while reshaping a signature.

If you know the shape of your workload, say so up front and the steady state will allocate nothing at all. `World.initCapacity` reserves the entity tables, and `reserve` grows a particular table to hold a number of entities before you create them.

```zig
var world = try zhecs.World.initCapacity(allocator, .{ .entities = 1_000_000 });
defer world.deinit();
try world.reserve(.{ Position, Velocity }, 1_000_000);
```

Two caches keep the common paths quiet. A query remembers the tables it matched and rebuilds that list only when a new table appears, so iterating the same query every frame neither scans nor allocates. Each table remembers where adding or removing a given component leads, so repeated structural changes follow a cached edge instead of sorting and hashing a fresh signature.

## How fast

From `zig build example -Doptimize=ReleaseFast` on an Apple aarch64 laptop, one million entities each carrying a position and a velocity:

```
created 1000000 entities (2 components each) in ~75 ms
each (per row):   ~50 ms, ~0.83 ns/update, ~1.2 billion updates/sec
run  (per chunk): ~19 ms, ~0.32 ns/update, ~3.1 billion updates/sec
toggled a tag on 1000000 entities (add and remove, two table moves each) in ~70 ms
```

The per-row form is already close to memory bandwidth. The per-chunk form is faster again because the inner loop is plain Zig over contiguous slices, which the compiler vectorizes.

## Working with other libraries

A component is any Zig type, so the types a graphics, audio, or physics library hands you become components without a wrapper. A binding such as zig-raylib gives you vectors, colours, rectangles, matrices, texture handles, and sound handles, and each of those goes straight into the world.

```zig
const rl = @import("raylib");
try world.set(player, rl.Vector2{ .x = 0, .y = 0 });
try world.set(player, sprite); // rl.Texture2D, a handle into the graphics driver
```

A render pass is then a query, and a physics step is another. There is one thing to keep in mind. A component that owns a resource, a texture on the card or a buffer of audio, is held by its handle, and a table move copies that handle rather than the resource behind it. The world does not free it for you. When you remove such a component or delete its entity, unload the resource yourself, the same way you would if you held it in a plain struct. Component move and destroy hooks, which would automate this, are on the road ahead.

There are working examples under `examples/`, each a small project of its own that depends on a real library and on this one, so the core stays free of dependencies. Every example has a `zig build test` that runs headless, which is what proves the integration in CI.

- `examples/raylib` ([raylib-zig](https://github.com/raylib-zig/raylib-zig)): a bin of balls falling under gravity and bouncing, with raylib's `Vector2`, `Color`, `Texture2D`, and `Camera2D` as components. `zig build run` opens the window; the tests cover a multi-phase pipeline, a scene hierarchy through `ChildOf`, lifetimes reaped with deferred deletes, a reused render query, and the physics itself.
- `examples/zbullet` ([zbullet](https://github.com/zig-gamedev/zbullet)): real Bullet physics. Each entity holds its rigid-body and shape handles, and a system syncs body transforms back into a position component. The tests drop spheres onto a floor and launch a body into an arc.
- `examples/zgui` ([zgui](https://github.com/zig-gamedev/zgui)): a Dear ImGui entity inspector with no graphics backend. The tests build the UI from ECS state and assert on the draw data ImGui produces.
- `examples/zsdl` ([zsdl](https://github.com/zig-gamedev/zsdl)): SDL's rectangle, point, and colour types as components, with ECS-driven axis-aligned collision. No SDL calls, so it links nothing and runs headless.
- `examples/platformer` (raylib-zig): a small platformer. The player runs and jumps under gravity, collides with platforms by axis-separated AABB resolution, and dies on contact with a patrolling enemy. `zig build run` plays it; the tests cover the physics, jumping, wall collision, enemy death, and patrol turns, all headless.

One thing the raylib example shows in passing: a position and a velocity are both a `Vector2`, and since a component is identified by its type, give each its own one-field wrapper. Types that play a single role, a colour or a texture, go in as they are.

## What is not here yet

The draft stops at a coherent core, and the edges are honest about it.

Relationships are exclusive and carry no data of their own. There are no query operators yet, so you cannot ask for the absence of a component, an optional one, an alternative, or a wildcard target. A table move copies component bytes directly, which assumes plain data with no move or destroy logic, so resource-owning components are your responsibility to unload. Component alignment above sixteen bytes is rejected at compile time.

The road ahead, roughly in order: query operators and wildcard relationships, relationship data and traversal, prefabs and instancing, component move and destroy hooks, and a choice of storage backend.

## Layout

```
build.zig          the build, with module, example, and test steps
build.zig.zon      the package manifest
src/zhecs.zig      the library and its internal tests
src/tests.zig      pulls in the public test suite
src/tests/         the suite, one file per topic
examples/basic.zig a walkthrough and a benchmark
examples/raylib/   a windowed raylib physics demo, its own small project
examples/zbullet/  a Bullet physics integration
examples/zgui/     a Dear ImGui entity inspector
examples/zsdl/     SDL types with ECS-driven collision
examples/platformer/ a playable platformer: physics, AABB, enemy death
```
