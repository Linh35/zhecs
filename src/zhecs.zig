//! zhecs - a small archetype Entity Component System for Zig 0.16, with a flecs-inspired API.
//!
//! Hybrid typing: you work with plain Zig types as components (comptime-typed, no anyopaque at the
//! call site), while internally each type is assigned a stable runtime id. That runtime id is what
//! lets relationships, archetype tables, and per-entity component sets work the way flecs does.
//!
//! Storage is archetype based: entities that share the exact same set of components live together
//! in one table, one densely packed column per component. Iterating a query walks those columns,
//! which is cache friendly. Adding or removing a component moves an entity to another table.
//!
//! Memory: a world owns one arena. Nothing is freed or shrunk during its life (deletes keep their
//! capacity, archetypes and maps only grow), so every persistent allocation comes from that arena
//! and `deinit` is a single arena reset. The base allocator is used only for short-lived scratch.
//! Lean on `initCapacity` and `reserve` to pre-size the tables, after which steady state allocates
//! nothing. See the README for the design, semantics, and the roadmap of features not here yet.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An entity handle. The low 32 bits are an index into the entity table, the high 32 bits are a
/// generation counter that is bumped on delete, so a stale handle to a recycled slot is detected.
pub const Entity = enum(u64) { none = 0, _ };

/// A component or relationship id as stored in an archetype signature. A plain component id is just
/// its dense registry index. A relationship pair sets the high bit and packs (relation, target).
pub const Id = u64;

/// Pipeline phases, run in this declaration order by `progress`. Mirrors flecs' built-in phases.
pub const Phase = enum { on_load, post_load, pre_update, on_update, on_validate, post_update, pre_store, on_store };

/// Lifecycle events an observer can react to.
pub const Event = enum { on_add, on_set, on_remove };

/// An observer callback. It receives the world and the entity the event happened on.
pub const Hook = *const fn (*World, Entity) void;

/// Built-in relationship tag for parent/child hierarchies: `world.childOf(child, parent)`.
pub const ChildOf = struct {};

/// Up-front sizing hints. All optional; correctness never depends on them.
pub const Options = struct {
    /// Reserve room for about this many entity records, so creating up to that many entities does
    /// not grow the per-entity tables. Component columns still grow on demand (see `reserve`).
    entities: usize = 0,
};

const PAIR_FLAG: u64 = 1 << 63;
const RELATION_MASK: u64 = 0x7fff_ffff; // 31 bits of relation id, between the flag and the target

// --- entity bit twiddling ------------------------------------------------------------------------

inline fn entityIndex(e: Entity) u32 {
    return @truncate(@intFromEnum(e));
}
inline fn entityGen(e: Entity) u32 {
    return @truncate(@intFromEnum(e) >> 32);
}
inline fn makeEntity(index: u32, generation: u32) Entity {
    return @enumFromInt((@as(u64, generation) << 32) | index);
}

// --- type identity -------------------------------------------------------------------------------

// Each distinct Zig type gets its own static byte; its address is a stable, unique key for the
// type at runtime. We map that key to a small dense component index in the world's registry.
fn typeKey(comptime T: type) usize {
    const Holder = struct {
        const Tag = T; // ties the struct to T so each type gets its own `marker`
        var marker: u8 = 0;
    };
    return @intFromPtr(&Holder.marker);
}

// --- internal storage ----------------------------------------------------------------------------

const ComponentMeta = struct {
    size: usize,
    alignment: usize,
    name: []const u8,
    hooks: [3]?Hook = .{ null, null, null }, // indexed by @intFromEnum(Event)
};

const Record = struct {
    archetype: u32,
    row: u32,
    generation: u32,
    alive: bool,
};

// Component bytes live in a u8 buffer, but a component may need more than byte alignment. We align
// every column buffer to MAX_ALIGN, which covers all standard scalar and SIMD-free types. Because
// @sizeOf is always a multiple of @alignOf, a base aligned to MAX_ALIGN makes every row aligned to
// its component too. Components needing more are rejected at compile time in `componentId`.
const MAX_ALIGN = 16;
const ColumnBytes = std.ArrayListAligned(u8, .fromByteUnits(MAX_ALIGN));

const Column = struct {
    id: Id,
    size: usize,
    data: ColumnBytes = .empty,
};

const Archetype = struct {
    signature: []Id, // sorted ascending, owned by the arena; also the lookup-map key
    columns: []Column, // one per signature entry, in the same order; tags have size 0
    entities: std.ArrayList(Entity) = .empty,
    // Cached transitions: from this archetype, adding/removing a given id lands in archetype N.
    // Archetypes are never destroyed, so these indices stay valid for the life of the world.
    add_edges: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    remove_edges: std.AutoHashMapUnmanaged(Id, u32) = .empty,

    // Binary search: the signature is kept sorted, so this is O(log n) in the component count.
    fn columnIndex(self: *const Archetype, id: Id) ?usize {
        var lo: usize = 0;
        var hi: usize = self.signature.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.signature[mid];
            if (v < id) {
                lo = mid + 1;
            } else if (v > id) {
                hi = mid;
            } else {
                return mid;
            }
        }
        return null;
    }

    // Append one zeroed row across every column and record its entity. Returns the new row index.
    fn pushRow(self: *Archetype, gpa: Allocator, e: Entity) !usize {
        const row = self.entities.items.len;
        try self.entities.append(gpa, e);
        for (self.columns) |*c| {
            if (c.size > 0) try c.data.appendNTimes(gpa, 0, c.size);
        }
        return row;
    }

    // Remove a row by moving the last row into its place (swap remove). Returns the entity that
    // was moved, so the caller can fix that entity's stored row, or .none if `row` was last.
    fn swapRemoveRow(self: *Archetype, row: usize) Entity {
        const last = self.entities.items.len - 1;
        var moved: Entity = .none;
        if (row != last) {
            for (self.columns) |*c| {
                if (c.size == 0) continue;
                const s = c.size;
                @memcpy(c.data.items[row * s ..][0..s], c.data.items[last * s ..][0..s]);
            }
            self.entities.items[row] = self.entities.items[last];
            moved = self.entities.items[row];
        }
        self.entities.items.len = last;
        for (self.columns) |*c| {
            if (c.size > 0) c.data.items.len = last * c.size;
        }
        return moved;
    }
};

const SystemEntry = struct {
    phase: Phase,
    name: []const u8,
    run: *const fn (*World) void,
};

// A cached query result: the archetypes that matched, valid as long as `version` equals the
// world's archetype version (which only changes when a new archetype is created).
const QueryCache = struct {
    version: u64,
    matched: std.ArrayList(u32) = .empty,
};

const SigContext = struct {
    pub fn hash(_: SigContext, key: []const Id) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: SigContext, a: []const Id, b: []const Id) bool {
        return std.mem.eql(Id, a, b);
    }
};

const ArchetypeMap = std.HashMapUnmanaged([]const Id, u32, SigContext, std.hash_map.default_max_load_percentage);
const QueryMap = std.HashMapUnmanaged([]const Id, *QueryCache, SigContext, std.hash_map.default_max_load_percentage);

// --- the world -----------------------------------------------------------------------------------

pub const World = struct {
    gpa: Allocator, // base allocator: backs the arena and serves short-lived scratch buffers
    arena: std.heap.ArenaAllocator, // owns every persistent allocation; freed in one shot by deinit
    archetypes: std.ArrayList(Archetype) = .empty,
    archetype_map: ArchetypeMap = .empty,
    records: std.ArrayList(Record) = .empty,
    free_ids: std.ArrayList(u32) = .empty,
    component_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty, // typeKey -> dense component index
    component_meta: std.ArrayList(ComponentMeta) = .empty,
    systems: std.ArrayList(SystemEntry) = .empty,
    delta_time: f32 = 0,
    singleton: Entity = .none, // a reserved entity that holds singleton components
    // Bumped whenever a new archetype is created, so cached queries know to refresh.
    archetype_version: u64 = 0,
    query_cache: QueryMap = .empty,

    pub fn init(gpa: Allocator) !World {
        return initCapacity(gpa, .{});
    }

    /// Like `init`, but pre-sizes the tables from `options` so a known workload allocates less.
    pub fn initCapacity(gpa: Allocator, options: Options) !World {
        var world = World{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer world.arena.deinit();
        const a = world.arena.allocator();
        if (options.entities > 0) {
            try world.records.ensureTotalCapacity(a, options.entities);
            try world.free_ids.ensureTotalCapacity(a, options.entities);
        }
        // Archetype 0 is the empty table; every entity with no components lives here.
        _ = try world.getOrCreateArchetype(&.{});
        // A dedicated entity to carry singleton components.
        world.singleton = try world.entity();
        return world;
    }

    pub fn deinit(self: *World) void {
        self.arena.deinit(); // one free reclaims archetypes, columns, maps, records, everything
    }

    // The arena that owns every persistent allocation. Always derived from the current `self`, so
    // the world is safe to return and move by value (no stored allocator points back into it).
    inline fn mem(self: *World) Allocator {
        return self.arena.allocator();
    }

    // --- entities --------------------------------------------------------------------------------

    /// Create a fresh, empty entity.
    pub fn entity(self: *World) !Entity {
        if (self.free_ids.pop()) |i| {
            const rec = &self.records.items[i];
            rec.alive = true;
            rec.archetype = 0;
            const e = makeEntity(i, rec.generation);
            rec.row = @intCast(try self.archetypes.items[0].pushRow(self.mem(), e));
            return e;
        }
        const i: u32 = @intCast(self.records.items.len);
        try self.records.append(self.mem(), .{ .archetype = 0, .row = 0, .generation = 0, .alive = true });
        const e = makeEntity(i, 0);
        self.records.items[i].row = @intCast(try self.archetypes.items[0].pushRow(self.mem(), e));
        return e;
    }

    /// Delete an entity and all of its components. Its handle becomes stale (a later `isAlive`
    /// returns false even if the slot is reused, thanks to the generation bump).
    pub fn delete(self: *World, e: Entity) void {
        const rec = self.recordPtr(e) orelse return;
        const arch_index = rec.archetype;
        const row = rec.row;
        rec.alive = false;
        rec.generation +%= 1;
        const moved = self.archetypes.items[arch_index].swapRemoveRow(row);
        if (moved != .none) self.recordPtr(moved).?.row = row;
        // Best effort: if recycling the id fails to allocate, the slot simply is not reused.
        self.free_ids.append(self.mem(), entityIndex(e)) catch {};
    }

    pub fn isAlive(self: *World, e: Entity) bool {
        return self.recordPtr(e) != null;
    }

    // --- components ------------------------------------------------------------------------------

    /// Add component `T` to `e` with a zeroed value, if it is not already present.
    pub fn add(self: *World, e: Entity, comptime T: type) !void {
        const id = try self.componentId(T);
        const had = self.has(e, T);
        try self.addId(e, id);
        if (!had) self.fireHook(id, e, .on_add);
    }

    /// Add or overwrite component `value` on `e`. Fires on_add (if newly added) then on_set.
    pub fn set(self: *World, e: Entity, value: anytype) !void {
        const T = @TypeOf(value);
        const id = try self.componentId(T);
        const had = self.has(e, T);
        try self.addId(e, id);
        if (@sizeOf(T) > 0) {
            const rec = self.recordPtr(e).?;
            const arch = &self.archetypes.items[rec.archetype];
            const ci = arch.columnIndex(id).?;
            const s = @sizeOf(T);
            @memcpy(arch.columns[ci].data.items[rec.row * s ..][0..s], std.mem.asBytes(&value));
        }
        if (!had) self.fireHook(id, e, .on_add);
        self.fireHook(id, e, .on_set);
    }

    /// Read-only pointer to `e`'s component `T`, or null if it does not have one.
    pub fn get(self: *World, e: Entity, comptime T: type) ?*const T {
        return self.getMut(e, T);
    }

    /// Mutable pointer to `e`'s component `T`, or null if it does not have one.
    pub fn getMut(self: *World, e: Entity, comptime T: type) ?*T {
        const id = self.lookupComponent(T) orelse return null;
        const rec = self.recordPtr(e) orelse return null;
        const arch = &self.archetypes.items[rec.archetype];
        const ci = arch.columnIndex(id) orelse return null;
        return columnPtr(T, &arch.columns[ci], rec.row);
    }

    pub fn has(self: *World, e: Entity, comptime T: type) bool {
        const id = self.lookupComponent(T) orelse return false;
        const rec = self.recordPtr(e) orelse return false;
        return self.archetypes.items[rec.archetype].columnIndex(id) != null;
    }

    /// Remove component `T` from `e`, if present. Fires on_remove.
    pub fn remove(self: *World, e: Entity, comptime T: type) !void {
        const id = self.lookupComponent(T) orelse return;
        if (!self.has(e, T)) return;
        try self.removeId(e, id);
        self.fireHook(id, e, .on_remove);
    }

    // --- singletons ------------------------------------------------------------------------------

    pub fn setSingleton(self: *World, value: anytype) !void {
        try self.set(self.singleton, value);
    }
    pub fn getSingleton(self: *World, comptime T: type) ?*T {
        return self.getMut(self.singleton, T);
    }

    // --- relationships (exclusive pairs) ---------------------------------------------------------

    /// Add the relationship `(Relation, target)` to `e`, for example `(ChildOf, parent)`.
    pub fn addPair(self: *World, e: Entity, comptime Relation: type, target: Entity) !void {
        try self.addId(e, try self.pairId(Relation, target));
    }
    pub fn removePair(self: *World, e: Entity, comptime Relation: type, target: Entity) !void {
        try self.removeId(e, try self.pairId(Relation, target));
    }
    pub fn hasPair(self: *World, e: Entity, comptime Relation: type, target: Entity) bool {
        const rel = self.lookupComponent(Relation) orelse return false;
        const rec = self.recordPtr(e) orelse return false;
        const pid = PAIR_FLAG | (rel << 32) | entityIndex(target);
        return self.archetypes.items[rec.archetype].columnIndex(pid) != null;
    }
    /// The target of the first `Relation` pair on `e`, or null. Exclusive-relationship convenience.
    ///
    /// The pair stores only the target's index, so the returned handle carries the target slot's
    /// current generation. If that target was deleted, `isAlive` on the result is false; if the
    /// slot was then recycled, this returns the new occupant. Hold targets you care about elsewhere.
    pub fn getTarget(self: *World, e: Entity, comptime Relation: type) ?Entity {
        const rel = self.lookupComponent(Relation) orelse return null;
        const rec = self.recordPtr(e) orelse return null;
        for (self.archetypes.items[rec.archetype].signature) |s| {
            if (s & PAIR_FLAG != 0 and (s >> 32) & RELATION_MASK == rel) {
                const ti: u32 = @truncate(s);
                if (ti < self.records.items.len) return makeEntity(ti, self.records.items[ti].generation);
            }
        }
        return null;
    }
    pub fn childOf(self: *World, e: Entity, the_parent: Entity) !void {
        try self.addPair(e, ChildOf, the_parent);
    }
    pub fn parent(self: *World, e: Entity) ?Entity {
        return self.getTarget(e, ChildOf);
    }

    // --- observers -------------------------------------------------------------------------------

    /// Register a hook to run whenever `event` happens for component `T`. One hook per (T, event).
    pub fn observe(self: *World, comptime T: type, event: Event, hook: Hook) !void {
        const id = try self.componentId(T);
        self.component_meta.items[@intCast(id)].hooks[@intFromEnum(event)] = hook;
    }

    // --- queries ---------------------------------------------------------------------------------

    /// Run `func` for every entity that has all of `terms`, one entity at a time. `func` is called
    /// as `func(ctx, Entity, *T0, *T1, ...)`, with one mutable column pointer per term, in order.
    ///
    /// Do not add or remove components, or delete entities, from inside `func` in this draft;
    /// structural changes during iteration are not deferred yet and would move rows underneath you.
    pub fn each(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype) void {
        self.visit(terms, ctx, func, iterArchetype);
    }

    /// Like `each`, but `func` is called once per matching archetype with whole column slices:
    /// `func(ctx, []const Entity, []T0, []T1, ...)`. The loop body is yours, so the compiler can
    /// vectorize it. This is the fastest way to sweep large sets. Same no-structural-change rule.
    pub fn run(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype) void {
        self.visit(terms, ctx, func, runArchetype);
    }

    /// Number of live entities that have all of `terms`.
    pub fn count(self: *World, comptime terms: anytype) usize {
        const n = terms.len;
        if (n == 0) return 0;
        var ids: [n]Id = undefined;
        inline for (terms, 0..) |T, i| ids[i] = self.lookupComponent(T) orelse return 0;
        var total: usize = 0;
        const matched = self.matchedArchetypes(ids) catch {
            var ai: usize = 0;
            while (ai < self.archetypes.items.len) : (ai += 1) {
                if (archetypeMatches(&self.archetypes.items[ai], ids)) total += self.archetypes.items[ai].entities.items.len;
            }
            return total;
        };
        for (matched) |ai| total += self.archetypes.items[ai].entities.items.len;
        return total;
    }

    // Shared driver for each/run: resolve term ids, find matching archetypes (cached), and hand
    // each one to `visitor`. Falls back to a full scan if the cache cannot be built (out of memory).
    inline fn visit(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype, comptime visitor: anytype) void {
        const n = terms.len;
        if (n == 0) return;
        var ids: [n]Id = undefined;
        inline for (terms, 0..) |T, i| {
            // A term never registered cannot be on any entity, so there is nothing to iterate.
            ids[i] = self.lookupComponent(T) orelse return;
        }
        const matched = self.matchedArchetypes(ids) catch {
            var ai: usize = 0;
            while (ai < self.archetypes.items.len) : (ai += 1) {
                const arch = &self.archetypes.items[ai];
                if (archetypeMatches(arch, ids)) visitor(arch, terms, ids, ctx, func);
            }
            return;
        };
        for (matched) |ai| visitor(&self.archetypes.items[ai], terms, ids, ctx, func);
    }

    // --- systems / pipeline ----------------------------------------------------------------------

    /// Register a system that runs in `phase`. `func` has the same shape as an `each` callback but
    /// with the world as its context: `func(*World, Entity, *T0, ...)`, so it can read
    /// `world.delta_time`. Systems run in registration order within a phase.
    pub fn system(self: *World, phase: Phase, name: []const u8, comptime terms: anytype, comptime func: anytype) !void {
        const Trampoline = struct {
            fn run(w: *World) void {
                w.each(terms, w, func);
            }
        };
        try self.systems.append(self.mem(), .{ .phase = phase, .name = name, .run = Trampoline.run });
    }

    /// Advance the world by `dt` seconds: run every system, phase by phase, in declaration order.
    pub fn progress(self: *World, dt: f32) void {
        self.delta_time = dt;
        for (std.enums.values(Phase)) |ph| {
            for (self.systems.items) |s| {
                if (s.phase == ph) s.run(self);
            }
        }
    }

    // --- pre-allocation --------------------------------------------------------------------------

    /// Ensure the archetype that has exactly `terms` exists and can hold `n` entities without
    /// reallocating. A pure optimization for known workloads; correctness does not depend on it.
    pub fn reserve(self: *World, comptime terms: anytype, n: usize) !void {
        const k = terms.len;
        var ids: [k]Id = undefined;
        inline for (terms, 0..) |T, i| ids[i] = try self.componentId(T);
        std.mem.sort(Id, &ids, {}, std.sort.asc(Id));
        const ai = try self.getOrCreateArchetype(&ids);
        const arch = &self.archetypes.items[ai];
        try arch.entities.ensureTotalCapacity(self.mem(), n);
        for (arch.columns) |*c| {
            if (c.size > 0) try c.data.ensureTotalCapacity(self.mem(), n * c.size);
        }
    }

    // --- internals -------------------------------------------------------------------------------

    fn recordPtr(self: *World, e: Entity) ?*Record {
        const i = entityIndex(e);
        if (i >= self.records.items.len) return null;
        const r = &self.records.items[i];
        if (!r.alive or r.generation != entityGen(e)) return null;
        return r;
    }

    fn componentId(self: *World, comptime T: type) !Id {
        comptime if (@alignOf(T) > MAX_ALIGN) @compileError("component '" ++ @typeName(T) ++ "' needs alignment > " ++ std.fmt.comptimePrint("{d}", .{MAX_ALIGN}) ++ "; raise MAX_ALIGN in zhecs");
        const gop = try self.component_ids.getOrPut(self.mem(), typeKey(T));
        if (!gop.found_existing) {
            const index: u32 = @intCast(self.component_meta.items.len);
            try self.component_meta.append(self.mem(), .{
                .size = @sizeOf(T),
                .alignment = @alignOf(T),
                .name = @typeName(T),
            });
            gop.value_ptr.* = index;
        }
        return gop.value_ptr.*;
    }

    fn lookupComponent(self: *World, comptime T: type) ?Id {
        if (self.component_ids.get(typeKey(T))) |i| return i;
        return null;
    }

    // Return the archetype indices matching the given term ids, cached across calls. On a cache hit
    // with an unchanged archetype version this does not allocate: it sorts the tiny term array on
    // the stack to form the key and looks it up.
    fn matchedArchetypes(self: *World, term_ids: anytype) ![]const u32 {
        var key = term_ids; // copy; sorting canonicalizes so term order does not fork the cache
        std.mem.sort(Id, &key, {}, std.sort.asc(Id));

        if (self.query_cache.getContext(&key, .{})) |qc| {
            if (qc.version != self.archetype_version) try self.refreshQuery(qc, term_ids);
            return qc.matched.items;
        }

        const owned = try self.mem().dupe(Id, &key);
        const qc = try self.mem().create(QueryCache);
        qc.* = .{ .version = self.archetype_version -% 1, .matched = .empty }; // mismatch forces refresh
        try self.query_cache.putContext(self.mem(), owned, qc, .{});
        try self.refreshQuery(qc, term_ids);
        return qc.matched.items;
    }

    fn refreshQuery(self: *World, qc: *QueryCache, term_ids: anytype) !void {
        qc.matched.clearRetainingCapacity();
        var ai: u32 = 0;
        while (ai < self.archetypes.items.len) : (ai += 1) {
            if (archetypeMatches(&self.archetypes.items[ai], term_ids)) try qc.matched.append(self.mem(), ai);
        }
        qc.version = self.archetype_version;
    }

    fn pairId(self: *World, comptime Relation: type, target: Entity) !Id {
        const rel = try self.componentId(Relation);
        return PAIR_FLAG | (rel << 32) | entityIndex(target);
    }

    fn sizeOfId(self: *World, id: Id) usize {
        if (id & PAIR_FLAG != 0) return 0; // pairs are tags in this draft
        return self.component_meta.items[@intCast(id)].size;
    }

    fn fireHook(self: *World, id: Id, e: Entity, event: Event) void {
        if (id & PAIR_FLAG != 0) return;
        if (self.component_meta.items[@intCast(id)].hooks[@intFromEnum(event)]) |h| h(self, e);
    }

    fn getOrCreateArchetype(self: *World, signature: []const Id) !u32 {
        if (self.archetype_map.getContext(signature, .{})) |existing| return existing;

        const sig = try self.mem().dupe(Id, signature);
        const cols = try self.mem().alloc(Column, sig.len);
        for (sig, 0..) |id, i| cols[i] = .{ .id = id, .size = self.sizeOfId(id), .data = .empty };

        const index: u32 = @intCast(self.archetypes.items.len);
        try self.archetypes.append(self.mem(), .{ .signature = sig, .columns = cols });
        try self.archetype_map.putContext(self.mem(), sig, index, .{});
        self.archetype_version += 1; // any cached query may now have a new archetype to match
        return index;
    }

    fn addId(self: *World, e: Entity, id: Id) !void {
        const from = (self.recordPtr(e) orelse return error.EntityNotAlive).archetype;
        if (self.archetypes.items[from].columnIndex(id) != null) return; // already present
        const to = try self.archetypeAfterAdd(from, id);
        try self.moveEntity(e, from, to);
    }

    fn removeId(self: *World, e: Entity, id: Id) !void {
        const from = (self.recordPtr(e) orelse return error.EntityNotAlive).archetype;
        if (self.archetypes.items[from].columnIndex(id) == null) return; // not present
        const to = try self.archetypeAfterRemove(from, id);
        try self.moveEntity(e, from, to);
    }

    // The archetype reached by adding `id` to `from`, taking the cached edge when there is one. The
    // scratch signature is short-lived, so it comes from the base allocator and is freed at once.
    fn archetypeAfterAdd(self: *World, from: u32, id: Id) !u32 {
        if (self.archetypes.items[from].add_edges.get(id)) |to| return to;

        const old_sig = self.archetypes.items[from].signature;
        const buf = try self.gpa.alloc(Id, old_sig.len + 1);
        defer self.gpa.free(buf);
        var k: usize = 0;
        var inserted = false;
        for (old_sig) |s| {
            if (!inserted and id < s) {
                buf[k] = id;
                k += 1;
                inserted = true;
            }
            buf[k] = s;
            k += 1;
        }
        if (!inserted) buf[k] = id;

        const to = try self.getOrCreateArchetype(buf);
        try self.archetypes.items[from].add_edges.put(self.mem(), id, to);
        return to;
    }

    // The archetype reached by removing `id` from `from`, taking the cached edge when there is one.
    fn archetypeAfterRemove(self: *World, from: u32, id: Id) !u32 {
        if (self.archetypes.items[from].remove_edges.get(id)) |to| return to;

        const old_sig = self.archetypes.items[from].signature;
        const buf = try self.gpa.alloc(Id, old_sig.len - 1);
        defer self.gpa.free(buf);
        var k: usize = 0;
        for (old_sig) |s| {
            if (s != id) {
                buf[k] = s;
                k += 1;
            }
        }

        const to = try self.getOrCreateArchetype(buf);
        try self.archetypes.items[from].remove_edges.put(self.mem(), id, to);
        return to;
    }

    // Move an entity from one archetype to another, carrying over the components both tables share.
    fn moveEntity(self: *World, e: Entity, from: u32, to: u32) !void {
        const old_row = self.recordPtr(e).?.row;
        const new_row = try self.archetypes.items[to].pushRow(self.mem(), e);

        const a = &self.archetypes.items[from];
        const b = &self.archetypes.items[to];
        for (a.signature, 0..) |id, ai| {
            const s = a.columns[ai].size;
            if (s == 0) continue;
            if (b.columnIndex(id)) |bi| {
                @memcpy(b.columns[bi].data.items[new_row * s ..][0..s], a.columns[ai].data.items[old_row * s ..][0..s]);
            }
        }

        const moved = self.archetypes.items[from].swapRemoveRow(old_row);
        if (moved != .none) self.recordPtr(moved).?.row = @intCast(old_row);

        const rec = self.recordPtr(e).?;
        rec.archetype = to;
        rec.row = @intCast(new_row);
    }
};

fn columnPtr(comptime T: type, col: *Column, row: usize) *T {
    if (@sizeOf(T) == 0) return @ptrFromInt(@alignOf(T)); // zero-size: a valid non-null pointer, deref is a no-op
    const s = @sizeOf(T);
    return @ptrCast(@alignCast(col.data.items.ptr + row * s));
}

fn columnSlice(comptime T: type, col: *Column, len: usize) []T {
    if (@sizeOf(T) == 0) {
        const p: [*]T = @ptrFromInt(@alignOf(T));
        return p[0..len];
    }
    const p: [*]T = @ptrCast(@alignCast(col.data.items.ptr));
    return p[0..len];
}

// Does this archetype hold every one of the given component ids?
fn archetypeMatches(arch: *const Archetype, term_ids: anytype) bool {
    inline for (0..term_ids.len) |i| {
        if (arch.columnIndex(term_ids[i]) == null) return false;
    }
    return true;
}

// Per-row visitor: call `func(ctx, entity, *T0, ...)` for each row. Column indices are resolved
// once per archetype, so the row loop is just pointer arithmetic and the call.
inline fn iterArchetype(arch: *Archetype, comptime terms: anytype, term_ids: anytype, ctx: anytype, comptime func: anytype) void {
    const n = terms.len;
    const cnt = arch.entities.items.len;
    if (cnt == 0) return;
    var cols: [n]usize = undefined;
    inline for (0..n) |i| cols[i] = arch.columnIndex(term_ids[i]).?;

    var row: usize = 0;
    while (row < cnt) : (row += 1) {
        var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
        args[0] = ctx;
        args[1] = arch.entities.items[row];
        inline for (terms, 0..) |T, i| {
            args[2 + i] = columnPtr(T, &arch.columns[cols[i]], row);
        }
        @call(.auto, func, args);
    }
}

// Per-chunk visitor: call `func(ctx, []const Entity, []T0, ...)` once with the whole archetype's
// column slices, leaving the inner loop to the caller so the compiler can vectorize it.
inline fn runArchetype(arch: *Archetype, comptime terms: anytype, term_ids: anytype, ctx: anytype, comptime func: anytype) void {
    const cnt = arch.entities.items.len;
    if (cnt == 0) return;
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = ctx;
    args[1] = arch.entities.items[0..cnt];
    inline for (terms, 0..) |T, i| {
        const ci = arch.columnIndex(term_ids[i]).?;
        args[2 + i] = columnSlice(T, &arch.columns[ci], cnt);
    }
    @call(.auto, func, args);
}

// --- internal tests ------------------------------------------------------------------------------
// Broader behavioural coverage, obscure edge cases, and the fuzz model test live in src/tests.zig
// (public API). These few check things easiest to assert next to the implementation.

const testing = std.testing;

test "smoke: set, get, has, remove carries surviving components across the table move" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    const e = try w.entity();
    try w.set(e, Position{ .x = 1, .y = 2 });
    try w.set(e, Velocity{ .x = 3, .y = 4 });
    try testing.expectEqual(@as(f32, 1), w.get(e, Position).?.x);
    w.getMut(e, Position).?.x = 9;
    try testing.expectEqual(@as(f32, 9), w.get(e, Position).?.x);

    try w.remove(e, Velocity);
    try testing.expect(!w.has(e, Velocity));
    try testing.expect(w.has(e, Position));
}

test "pair id encoding keeps relation and target recoverable and never collides with plain ids" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const Likes = struct {};
    const target = try w.entity();
    const rel = try w.componentId(Likes);
    const pid = try w.pairId(Likes, target);

    try testing.expect(pid & PAIR_FLAG != 0); // pairs are flagged
    try testing.expect(rel & PAIR_FLAG == 0); // plain ids are not
    try testing.expectEqual(rel, (pid >> 32) & RELATION_MASK);
    try testing.expectEqual(entityIndex(target), @as(u32, @truncate(pid)));
}

fn WideComp(comptime i: usize) type {
    return struct {
        const slot = i; // makes each instantiation a distinct component type
        v: u32,
    };
}

test "binary-search columnIndex resolves every id in a wide signature" {
    var w = try World.init(testing.allocator);
    defer w.deinit();

    const e = try w.entity();
    inline for (0..32) |i| try w.set(e, WideComp(i){ .v = @intCast(i) });
    // After 32 table moves, every component must still be present and intact.
    inline for (0..32) |i| {
        try testing.expect(w.has(e, WideComp(i)));
        try testing.expectEqual(@as(u32, @intCast(i)), w.get(e, WideComp(i)).?.v);
    }
}
