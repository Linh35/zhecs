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
//! nothing.

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

pub const PAIR_FLAG: u64 = 1 << 63;
const RELATION_MASK: u64 = 0x7fff_ffff; // 31 bits of relation id, between the flag and the target

/// Comptime-stable component ID + bitset query signatures.
/// `ComptimeIds(.{Transform, Velocity, AI})` → comptime `id(T)`, `signatureOf(.{T0, T1})`,
/// and `matches(archetype, query)` bitset superset test. Drops runtime hashing for registered types.
/// See shared/ComptimeIds.zig for the prototype; this is the zhecs wire-up.
pub fn ComptimeIds(comptime component_types: anytype) type {
  const count: usize = @typeInfo(@TypeOf(component_types)).@"struct".fields.len;
  return struct {
    pub const num_components = count;
    pub const Signature = std.bit_set.IntegerBitSet(count);

    /// Comptime-stable id for a component type = its index in the registry tuple.
    pub fn id(comptime T: type) usize {
      inline for (component_types, 0..) |C, i| {
        if (C == T) return i;
      }
      @compileError("component not registered: " ++ @typeName(T));
    }

    /// Comptime signature (bitmask) for a set of component types.
    pub fn signatureOf(comptime types: anytype) Signature {
      var sig = Signature.initEmpty();
      inline for (types) |T| {
        sig.set(id(T));
      }
      return sig;
    }

    /// Does `archetype` contain every component in `query`? Branchless bitmask superset test.
    pub fn matches(archetype: Signature, query: Signature) bool {
      return archetype.supersetOf(query);
    }
  };
}

/// SoA field wrapper: mark a query term as "extract only this field".
/// `systemRun(.{SoaField(Transform, .position)})` → `[]f32` (dense, per-entity field slice)
/// instead of `[]Transform`. The column storage is unchanged; the view extracts per-field slices.
/// The `field` is a struct field enum value (e.g. `.position` from `std.meta.FieldEnum(T)`).
pub fn SoaField(comptime T: type, comptime field: anytype) type {
  return struct {
    pub const _Component = T;
    pub const _Field = field;
  };
}

/// Column-pass over a single field of a component type - SoA-shaped access.
/// The `func` receives `(ctx, []FieldType)` - a dense slice of just that field.
pub fn runSoa(
  self: *World,
  comptime T: type,
  comptime field: anytype,
  ctx: anytype,
  comptime func: anytype,
) void {
  const term_id = self.lookupComponent(T) orelse return;
  const FieldType = std.meta.fieldInfo(T, field).type;
  const field_offset: usize = @offsetOf(T, @tagName(field));
  const stride: usize = @sizeOf(T);
  var ai: usize = 0;
  while (ai < self.archetypes.items.len) : (ai += 1) {
    const arch = &self.archetypes.items[ai];
    if (arch.columnIndex(term_id) == null) continue;
    const col_idx = arch.columnIndex(term_id).?;
    const col = &arch.columns[col_idx];
    const len = arch.entities.items.len;
    if (len == 0) continue;
    // Build dense field slice: for each row, extract the field value
    // The stride-based pointer math gives us the field pointer for each row.
    const data_base: [*]const u8 = @ptrCast(@alignCast(col.data.items.ptr));
    var i: usize = 0;
    var field_slice: std.ArrayListUnmanaged(FieldType) = .empty;
    // Reserve up front - `.empty` has zero capacity, so the appendAssumeCapacity loop below would
    // write out of bounds without this (latent: runSoa has no callers yet).
    field_slice.ensureTotalCapacityPrecise(self.mem(), len) catch continue;
    defer field_slice.deinit(self.mem());
    while (i < len) : (i += 1) {
      const row_base = data_base + i * stride;
      const field_ptr: *const FieldType = @ptrFromInt(@intFromPtr(row_base) + field_offset);
      field_slice.appendAssumeCapacity(field_ptr.*);
    }
    func(ctx, field_slice.items);
  }
}

/// Vectorized column-pass: apply an elementwise op over a field slice in SIMD lanes.
/// `N` = vector width (e.g. 4 for 4-lane f32), `op` = `fn(@Vector(N, Elem)) @Vector(N, Elem)`.
/// Falls back to scalar for the tail. Mirrors `Soa.vectorize(N, op)` from shared/Soa.zig.
pub fn runVectorized(
  self: *World,
  comptime T: type,
  comptime field: anytype,
  comptime N: usize,
  comptime op: anytype,
) void {
  const term_id = self.lookupComponent(T) orelse return;
  const FieldType = std.meta.fieldInfo(T, field).type;
  const field_offset: usize = @offsetOf(T, @tagName(field));
  const stride: usize = @sizeOf(T);
  var ai: usize = 0;
  while (ai < self.archetypes.items.len) : (ai += 1) {
    const arch = &self.archetypes.items[ai];
    if (arch.columnIndex(term_id) == null) continue;
    const col_idx = arch.columnIndex(term_id).?;
    const col = &arch.columns[col_idx];
    const len = arch.entities.items.len;
    if (len == 0) continue;
    // Extract field slice and vectorize in-place
    const data_base: [*]u8 = @ptrCast(@alignCast(col.data.items.ptr));
    var i: usize = 0;
    var field_slice: std.ArrayListUnmanaged(FieldType) = .empty;
    // Reserve up front - `.empty` has zero capacity (latent: runVectorized has no callers yet).
    field_slice.ensureTotalCapacityPrecise(self.mem(), len) catch continue;
    defer field_slice.deinit(self.mem());
    while (i < len) : (i += 1) {
      const row_base = data_base + i * stride;
      const field_ptr: *FieldType = @ptrFromInt(@intFromPtr(row_base) + field_offset);
      field_slice.appendAssumeCapacity(field_ptr.*);
    }
    // Apply vectorized op (inline of Soa.vectorize)
    {
      var vi: usize = 0;
      while (vi + N <= field_slice.items.len) : (vi += N) {
        const v: @Vector(N, FieldType) = field_slice.items[vi..][0..N].*;
        field_slice.items[vi..][0..N].* = op(v);
      }
      while (vi < field_slice.items.len) : (vi += 1) {
        const one: @Vector(N, FieldType) = @splat(field_slice.items[vi]);
        field_slice.items[vi] = op(one)[0];
      }
    }
    // Write back to column
    i = 0;
    while (i < len) : (i += 1) {
      const row_base = data_base + i * stride;
      const field_ptr: *FieldType = @ptrFromInt(@intFromPtr(row_base) + field_offset);
      field_ptr.* = field_slice.items[i];
    }
  }
}

// --- entity bit twiddling ------------------------------------------------------------------------

pub inline fn entityIndex(e: Entity) u32 {
  return @truncate(@intFromEnum(e));
}
inline fn entityGen(e: Entity) u32 {
  return @truncate(@intFromEnum(e) >> 32);
}
inline fn makeEntity(index: u32, generation: u32) Entity {
  return @enumFromInt((@as(u64, generation) << 32) | index);
}

/// Encode a `(Relation, target)` pair id from a relation's dense component id and target entity.
/// Centralized so the bit layout (PAIR_FLAG | rel<<32 | target_index) lives in exactly one place.
inline fn pairIdOf(rel: Id, target: Entity) Id {
  return PAIR_FLAG | (rel << 32) | entityIndex(target);
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
const MAX_ALIGN = 64;
const ColumnBytes = std.ArrayListAligned(u8, .fromByteUnits(MAX_ALIGN));

/// Default rows-per-chunk for `World.runParallel` when the caller passes `chunk = 0`. Chosen so a
/// chunk is a big-enough unit of work to amortize task dispatch, yet small enough to balance load
/// across worker threads.
pub const default_parallel_chunk: usize = 1024;
/// Upper bound on tasks `runParallel` spawns PER archetype - the chunk is grown past the requested
/// size if needed so a very large archetype can't over-fragment into thousands of micro-tasks
/// (dispatch overhead + executor stalls). Keep it a small multiple of the worker count.
pub const max_parallel_ranges: usize = 64;

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
  // world's structural_version; bumped so iterators detect the move.
  fn pushRow(self: *Archetype, gpa: Allocator, e: Entity, version: *u64) !usize {
    version.* +%= 1;
    const row = self.entities.items.len;
    try self.entities.append(gpa, e);
    for (self.columns) |*c| {
      if (c.size > 0) try c.data.appendNTimes(gpa, 0, c.size);
    }
    return row;
  }

  // Remove a row by moving the last row into its place (swap remove). Returns the entity that
  // was moved, so the caller can fix that entity's stored row, or .none if `row` was last.
  // world's structural_version; bumped so iterators detect the move.
  fn swapRemoveRow(self: *Archetype, row: usize, version: *u64) Entity {
    version.* +%= 1;
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

// A structural change recorded while a defer scope is open, replayed when the scope closes. Adds
// and removes (relationship pairs included) and deletes reduce to these kinds; a `set` also stashes
// the component bytes in the world's `cmd_data` buffer at [off, off + len).
const CmdKind = enum { add, set, remove, delete };
const Command = struct {
  entity: Entity,
  kind: CmdKind,
  id: Id,
  off: u32 = 0,
  len: u32 = 0,
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
  /// Per-frame seed for parallel workers (avoids data race on shared.Rng.global()).
  frame_seed: u64 = 0,
  // Optional threading backend for parallel systems. Set once via `setIo`; when null, systems
  // registered with `systemParallel` degrade to a single-threaded column pass. Never owned here.
  io: ?std.Io = null,
  // >0 while a `runParallel`/`parallel` column pass is in flight. Structural mutations (which move
  // rows and invalidate the slices other chunks hold) are forbidden then; `assertMutableNow` turns
  // that misuse into a loud panic in safe builds instead of silent memory corruption. Set/cleared
  // on the dispatching thread around the pass, so workers only ever READ a stable value.
  parallel_depth: u32 = 0,
  singleton: Entity = .none, // a reserved entity that holds singleton components
  // pair id -> target gen, so getTarget rejects a recycled slot's new occupant.
  pair_gen: std.AutoHashMapUnmanaged(u64, u32) = .empty,
  // Bumped whenever a new archetype is created, so cached queries know to refresh.
  archetype_version: u64 = 0,
  // Bumped on every row move; iterators panic on mismatch (View.next, each/run).
  structural_version: u64 = 0,
  query_cache: QueryMap = .empty,
  // Deferral: while `defer_depth` is above zero, structural changes are recorded in `cmd_list`
  // (with `set` payloads in `cmd_data`) and replayed when the outermost scope closes.
  defer_depth: u32 = 0,
  cmd_list: std.ArrayList(Command) = .empty,
  cmd_data: std.ArrayList(u8) = .empty,

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

  /// Guardrail for the parallel contract: structural ops (create/move/destroy rows) are illegal
  /// while a `parallel`/`runParallel` column pass is running, because they relocate component
  /// storage and invalidate the slices other chunks are holding. In safe builds this panics with a
  /// clear message (turning silent corruption into an obvious bug); in ReleaseFast it compiles away.
  inline fn assertMutableNow(self: *const World) void {
    if (std.debug.runtime_safety and self.parallel_depth != 0) {
      @panic("zhecs: structural change (set/add/remove/delete/spawn) inside a parallel pass - " ++
        "a worker may only mutate component VALUES through its handed slices, never add/remove " ++
        "components or spawn/delete entities. Do structural edits before/after world.parallel().");
    }
  }

  /// Create a fresh, empty entity.
  pub fn entity(self: *World) !Entity {
    self.assertMutableNow();
    if (self.free_ids.pop()) |i| {
      const rec = &self.records.items[i];
      rec.alive = true;
      rec.archetype = 0;
      const e = makeEntity(i, rec.generation);
      rec.row = @intCast(try self.archetypes.items[0].pushRow(self.mem(), e, &self.structural_version));
      return e;
    }
    const i: u32 = @intCast(self.records.items.len);
    try self.records.append(self.mem(), .{ .archetype = 0, .row = 0, .generation = 0, .alive = true });
    const e = makeEntity(i, 0);
    self.records.items[i].row = @intCast(try self.archetypes.items[0].pushRow(self.mem(), e, &self.structural_version));
    return e;
  }

  /// Delete an entity and all of its components. Its handle becomes stale (a later `isAlive`
  /// returns false even if the slot is reused, thanks to the generation bump). Inside a defer
  /// scope the delete is recorded and applied when the scope closes.
  pub fn delete(self: *World, e: Entity) void {
    self.assertMutableNow();
    if (self.defer_depth > 0) {
      self.cmd_list.append(self.mem(), .{ .entity = e, .kind = .delete, .id = 0 }) catch {};
      return;
    }
    self.applyDelete(e);
  }

  pub fn isAlive(self: *World, e: Entity) bool {
    return self.recordPtr(e) != null;
  }

  // --- components ------------------------------------------------------------------------------

  /// Add component `T` to `e` with a zeroed value, if it is not already present.
  pub fn add(self: *World, e: Entity, comptime T: type) !void {
    self.assertMutableNow();
    const id = try self.componentId(T);
    if (self.defer_depth > 0) return self.enqueue(.add, e, id);
    try self.applyAdd(e, id);
  }

  /// Add or overwrite component `value` on `e`. Fires on_add (if newly added) then on_set.
  pub fn set(self: *World, e: Entity, value: anytype) !void {
    self.assertMutableNow();
    const id = try self.componentId(@TypeOf(value));
    if (self.defer_depth > 0) return self.enqueueSet(e, id, std.mem.asBytes(&value));
    try self.applySet(e, id, std.mem.asBytes(&value));
  }

  /// Read-only pointer to `e`'s component `T`, or null if it does not have one. Reads always see
  /// committed state; a value queued by `set` inside a defer scope is not visible until it flushes.
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
    return self.hasId(e, id);
  }

  /// Mutable pointer to `e`'s component `T`, adding a zero-initialized one first if absent.
  /// The common "edit in place, create on demand" pattern. Not valid inside a defer scope
  /// (it needs the component to exist immediately); use `set`/`add` there instead.
  pub fn getOrAdd(self: *World, e: Entity, comptime T: type) !*T {
    if (self.getMut(e, T)) |p| return p;
    try self.add(e, T);
    return self.getMut(e, T) orelse error.EntityNotAlive;
  }

  /// Remove component `T` from `e`, if present. Fires on_remove while `T` is
  /// still readable via `get`/`getMut`, before the row is actually dropped.
  pub fn remove(self: *World, e: Entity, comptime T: type) !void {
    self.assertMutableNow();
    const id = self.lookupComponent(T) orelse return;
    if (self.defer_depth > 0) return self.enqueue(.remove, e, id);
    try self.applyRemove(e, id);
  }

  /// Add component with the given runtime `id` to entity `e`. The component must already be
  /// registered in this world (a prior `add`/`set` with the same type). Use this for blob-based
  /// instantiation where component types are only known at runtime.
  pub fn addId(self: *World, e: Entity, id: Id) !void {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    if (self.defer_depth > 0) return self.enqueue(.add, e, id);
    try self.addIdInternal(e, id);
  }

  // --- deferral --------------------------------------------------------------------------------

  /// Open a defer scope. While one is open, `add`, `set`, `remove`, `addPair`, `removePair`, and
  /// `delete` record their change instead of applying it, so you can call them safely while a
  /// query is iterating. Scopes nest; the recorded changes are applied when the outermost closes.
  /// Reads (`get`, `has`, `count`) still see committed state until then.
  pub fn beginDefer(self: *World) void {
    self.defer_depth += 1;
  }

  /// Close a defer scope. When the outermost scope closes, the recorded changes are applied in the
  /// order they were made. Changes to an entity that an earlier change deleted are skipped.
  pub fn endDefer(self: *World) !void {
    std.debug.assert(self.defer_depth > 0);
    self.defer_depth -= 1;
    if (self.defer_depth == 0) try self.flush();
  }

  // --- singletons ------------------------------------------------------------------------------

  pub fn setSingleton(self: *World, value: anytype) !void {
    try self.set(self.singleton, value);
  }
  pub fn getSingleton(self: *World, comptime T: type) ?*T {
    return self.getMut(self.singleton, T);
  }
  /// Panic if the singleton is not present (useful in game code where absence is a bug).
  pub fn getSingletonRequire(self: *World, comptime T: type) *T {
    return self.getSingleton(T) orelse @panic(@typeName(T) ++ " singleton not set");
  }

  // --- relationships (exclusive pairs) ---------------------------------------------------------

  /// Add the relationship `(Relation, target)` to `e`, for example `(ChildOf, parent)`.
  pub fn addPair(self: *World, e: Entity, comptime Relation: type, target: Entity) !void {
    self.assertMutableNow();
    const id = try self.pairId(Relation, target);
    // Record target gen so getTarget/hasPair/eachChild reject a recycled slot.
    try self.pair_gen.put(self.mem(), id, entityGen(target));
    if (self.defer_depth > 0) return self.enqueue(.add, e, id);
    try self.applyAdd(e, id);
  }
  pub fn removePair(self: *World, e: Entity, comptime Relation: type, target: Entity) !void {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    const id = try self.pairId(Relation, target);
    if (self.defer_depth > 0) return self.enqueue(.remove, e, id);
    try self.applyRemove(e, id);
  }
  pub fn hasPair(self: *World, e: Entity, comptime Relation: type, target: Entity) bool {
    const rel = self.lookupComponent(Relation) orelse return false;
    const rec = self.recordPtr(e) orelse return false;
    const pid = pairIdOf(rel, target);
    if (self.archetypes.items[rec.archetype].columnIndex(pid) == null) return false;
    // Reject a recycled slot: the stored gen must match the caller's handle.
    const stored = self.pair_gen.get(pid) orelse return true;
    return stored == entityGen(target);
  }
  /// The first `Relation` target on `e`, or null if it was deleted/recycled.
  pub fn getTarget(self: *World, e: Entity, comptime Relation: type) ?Entity {
    const rel = self.lookupComponent(Relation) orelse return null;
    const rec = self.recordPtr(e) orelse return null;
    for (self.archetypes.items[rec.archetype].signature) |s| {
      if (s & PAIR_FLAG != 0 and (s >> 32) & RELATION_MASK == rel) {
        const ti: u32 = @truncate(s);
        if (ti >= self.records.items.len) return null;
        // No recorded gen (a raw addId pair) is unverifiable -> none, not the occupant.
        const stored = self.pair_gen.get(s) orelse return null;
        if (self.records.items[ti].generation != stored) return null;
        return makeEntity(ti, stored);
      }
    }
    return null;
  }
  pub fn childOf(self: *World, e: Entity, the_parent: Entity) !void {
    self.assertMutableNow();
    try self.addPair(e, ChildOf, the_parent);
  }
  pub fn parent(self: *World, e: Entity) ?Entity {
    return self.getTarget(e, ChildOf);
  }

  /// Call `func(ctx, child)` for each direct child of `the_parent` (entities carrying the
  /// `(ChildOf, the_parent)` relationship). The reverse of `parent`. Only the archetypes that
  /// actually hold *this* parent's pair are visited (each distinct parent gets its own pair id),
  /// so this is far cheaper than a full entity scan; cost is proportional to the matching tables.
  /// Order is archetype/row order. Do not change which components an entity has from inside `func`
  /// without a defer scope. Mirrors `each`'s callback shape minus the component pointers.
  pub fn eachChild(self: *World, the_parent: Entity, ctx: anytype, comptime func: anytype) void {
    const rel = self.lookupComponent(ChildOf) orelse return;
    const pid = pairIdOf(rel, the_parent);
    // Reject a recycled parent: a new occupant must not inherit the old children.
    if (self.pair_gen.get(pid)) |stored| {
      if (stored != entityGen(the_parent)) return;
    }
    for (self.archetypes.items) |*arch| {
      if (arch.columnIndex(pid) == null) continue;
      for (arch.entities.items) |child| func(ctx, child);
    }
  }

  /// Collect up to `out.len` direct children of `the_parent` into `out`; returns how many were
  /// written. Same matching as `eachChild`. For a parent with more children than `out` holds, the
  /// extras are dropped (returns `out.len`) - size `out` to your max fan-out, or use `eachChild`.
  pub fn getChildren(self: *World, the_parent: Entity, out: []Entity) usize {
    const rel = self.lookupComponent(ChildOf) orelse return 0;
    const pid = pairIdOf(rel, the_parent);
    // Reject a recycled parent (see eachChild): the new occupant has no children.
    if (self.pair_gen.get(pid)) |stored| {
      if (stored != entityGen(the_parent)) return 0;
    }
    var n: usize = 0;
    for (self.archetypes.items) |*arch| {
      if (arch.columnIndex(pid) == null) continue;
      for (arch.entities.items) |child| {
        if (n >= out.len) return n;
        out[n] = child;
        n += 1;
      }
    }
    return n;
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
  /// Adding or removing a component, or deleting an entity, from inside `func` moves rows under
  /// the iterator. Open a defer scope (`beginDefer`/`endDefer`) around the call to make such
  /// changes safe; they are recorded and applied when the scope closes.
  pub fn each(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype) void {
    self.visit(terms, ctx, func, iterArchetype);
  }

  /// Like `each`, but `func` is called once per matching archetype with whole column slices:
  /// `func(ctx, []const Entity, []T0, []T1, ...)`. The loop body is yours, so the compiler can
  /// vectorize it. As with `each`, use a defer scope to change components safely while iterating.
  pub fn run(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype) void {
    self.visit(terms, ctx, func, runArchetype);
  }

  /// Like `run`, but spreads the matched rows across `io`'s worker threads. Each matched
  /// archetype's rows are sliced into chunks of at most `chunk` entities, and every chunk is
  /// dispatched as an async task on `io`; `func(ctx, []const Entity, []T0, ...)` then runs
  /// (potentially concurrently) on disjoint sub-slices. The call blocks until every chunk has
  /// finished, joining via a `std.Io.Group`. With a `std.Io.Threaded` backend the chunks run in
  /// parallel up to its thread limit; with a single-threaded `io` they run inline, so the same
  /// code degrades gracefully. This is the column pass to reach for under the 200-FPS / MT rules.
  ///
  /// Contract - `func` may run on many threads at once over *disjoint* rows, so it MUST:
  ///   - touch only the rows in the slices it is handed (no indexing into the world, no reaching
  ///     across to another entity's row);
  ///   - make no structural changes - no `add`/`set`/`remove`/`delete`/`spawn`, even deferred, and
  ///     nothing that could create an archetype or move a row (that would invalidate the slices
  ///     other chunks hold). Mutating component *values* in place through the given slices is fine;
  ///   - treat `ctx` as read-only or otherwise thread-safe (e.g. an atomic accumulator, or a
  ///     per-thread shard). The same `ctx` is shared by every chunk.
  /// Pass `chunk = 0` for `default_parallel_chunk`. Smaller chunks balance load across threads at
  /// the cost of more dispatch overhead; size it to your per-row work. The signature errs only if
  /// the backend cannot grow its task storage; on that error it has already run nothing new.
  pub fn runParallel(self: *World, io: std.Io, comptime terms: anytype, chunk: usize, ctx: anytype, comptime func: anytype) void {
    const n = terms.len;
    if (n == 0) return;
    // NESTED-PARALLEL GUARD: if a worker (already inside a parallel pass) dispatches another parallel
    // pass, run it INLINE/serial. Dispatching nested worker pools explodes the thread count + races
    // archetype storage (this crashed the game when a systemParallel worker called ctx.parallel). The
    // inner level is correct serial; only the outermost pass parallelizes.
    if (@atomicLoad(u32, &self.parallel_depth, .seq_cst) != 0) {
      self.run(terms, ctx, func);
      return;
    }
    var ids: [n]Id = undefined;
    inline for (terms, 0..) |T, i| {
      ids[i] = self.lookupComponent(T) orelse return;
    }
    const step = if (chunk == 0) default_parallel_chunk else chunk;
    const Ctx = @TypeOf(ctx);

    var group: std.Io.Group = .init;
    // Mark the world non-mutable for the duration of the pass. ATOMIC because a worker may itself
    // dispatch a nested parallel pass (the dispatch thread's defer then races the worker's inc/dec) -
    // a non-atomic `-= 1` underflowed to an integer-overflow panic. Any structural change from a
    // worker still panics in safe builds (see assertMutableNow).
    _ = @atomicRmw(u32, &self.parallel_depth, .Add, 1, .seq_cst);
    defer _ = @atomicRmw(u32, &self.parallel_depth, .Sub, 1, .seq_cst);
    const Job = struct {
      // One async task: run `func` over one chunk [lo, hi) of one archetype's columns.
      fn chunkJob(arch: *Archetype, cols: [n]usize, total: usize, lo: usize, hi: usize, c: Ctx) void {
        var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
        args[0] = c;
        args[1] = arch.entities.items[lo..hi];
        inline for (terms, 0..) |T, i| {
          args[2 + i] = columnSlice(T, &arch.columns[cols[i]], total)[lo..hi];
        }
        @call(.auto, func, args);
      }
      // Slice one archetype into chunks and spawn a task for each.
      inline fn dispatch(g: *std.Io.Group, o: std.Io, arch: *Archetype, term_ids: [n]Id, st: usize, c: Ctx) void {
        const cnt = arch.entities.items.len;
        if (cnt == 0) return;
        var cols: [n]usize = undefined;
        inline for (0..n) |i| cols[i] = arch.columnIndex(term_ids[i]).?;
        // Treat `st` as a FLOOR but cap the task count: a huge archetype must not spawn
        // thousands of micro-tasks - that just burns dispatch overhead and can stall the
        // executor. Grow the chunk so at most `max_parallel_ranges` tasks are spawned here.
        const eff = @max(st, (cnt + max_parallel_ranges - 1) / max_parallel_ranges);
        var lo: usize = 0;
        while (lo < cnt) : (lo += eff) {
          const hi = @min(lo + eff, cnt);
          g.async(o, chunkJob, .{ arch, cols, cnt, lo, hi, c });
        }
      }
    };

    if (self.matchedArchetypes(ids)) |matched| {
      for (matched) |ai| Job.dispatch(&group, io, &self.archetypes.items[ai], ids, step, ctx);
    } else |_| {
      var ai: usize = 0;
      while (ai < self.archetypes.items.len) : (ai += 1) {
        const arch = &self.archetypes.items[ai];
        if (archetypeMatches(arch, ids)) Job.dispatch(&group, io, arch, ids, step, ctx);
      }
    }
    // Join: blocks until every chunk has finished. Cancellation is not expected for a column
    // pass, so a returned error.Canceled is treated as "all chunks settled" and ignored.
    group.await(io) catch {};
  }

  /// Ergonomic `runParallel`: uses the world's own `io` (set once via `setIo`) and the default
  /// auto-chunk, so a parallel column pass reads as `world.parallel(.{A, B}, ctx, func)` - no `io`
  /// or `chunk` to thread through call sites. If no `io` is set it runs **inline/serial** via `run`
  /// (same `func`, graceful degradation). Same disjoint-rows contract as `runParallel`: `func` runs
  /// on many threads over disjoint slices, so no structural changes and treat `ctx` as shared.
  pub fn parallel(self: *World, comptime terms: anytype, ctx: anytype, comptime func: anytype) void {
    if (self.io) |io| {
      self.runParallel(io, terms, 0, ctx, func);
    } else {
      self.run(terms, ctx, func);
    }
  }

  /// A `while (it.next()) |e|` iterator over every entity that has all of `terms`. Inside the
  /// loop, `it.get(T)` returns a mutable pointer to that entity's `T`. This is the plain Zig way
  /// to walk a query: no callback, no context to thread, just a loop that closes over its scope.
  /// Same rule as `each`: do not change which components an entity has while iterating.
  pub fn view(self: *World, comptime terms: anytype) View(terms) {
    var v: View(terms) = .{ .world = self, .start_arch_version = self.archetype_version, .start_structural_version = self.structural_version };
    if (terms.len == 0) {
      v.done = true;
      return v;
    }
    inline for (terms, 0..) |T, i| {
      if (self.lookupComponent(T)) |id| v.ids[i] = id else v.done = true;
    }
    return v;
  }

  /// Call `func(ctx, Entity)` for every live entity in the world, regardless of components
  /// (the internal singleton entity is skipped). For walking *all* objects - e.g. an editor
  /// hierarchy that lists everything. Don't change which components an entity has, or delete
  /// entities, from inside `func` without a defer scope (it moves rows under the walk).
  pub fn eachEntity(self: *World, ctx: anytype, comptime func: anytype) void {
    for (self.archetypes.items) |*arch| {
      for (arch.entities.items) |e| {
        if (e == self.singleton) continue;
        func(ctx, e);
      }
    }
  }

  /// Collect up to `out.len` live entities (singleton excluded) into `out`; returns how many.
  pub fn allEntities(self: *World, out: []Entity) usize {
    var n: usize = 0;
    for (self.archetypes.items) |*arch| {
      for (arch.entities.items) |e| {
        if (e == self.singleton) continue;
        if (n >= out.len) return n;
        out[n] = e;
        n += 1;
      }
    }
    return n;
  }

  /// Total live entities (excludes the singleton); size an allEntities buffer.
  pub fn entityCount(self: *World) usize {
    var n: usize = 0;
    for (self.archetypes.items) |*arch| {
      for (arch.entities.items) |e| {
        if (e != self.singleton) n += 1;
      }
    }
    return n;
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
        if (archetypeMatches(arch, ids)) visitor(self, arch, terms, ids, ctx, func);
      }
      return;
    };
    for (matched) |ai| visitor(self, &self.archetypes.items[ai], terms, ids, ctx, func);
  }

  /// Compile a reusable query handle. Calling its `each`, `run`, or `count` skips the per-call key
  /// hashing the loose `each`/`run`/`count` do, which adds up when you run many queries a frame.
  /// The handle stays valid for the life of the world and refreshes itself when tables appear.
  pub fn query(self: *World, comptime terms: anytype) !Query(terms) {
    const n = terms.len;
    var ids: [n]Id = undefined;
    inline for (terms, 0..) |T, i| ids[i] = try self.componentId(T);
    return .{ .world = self, .ids = ids, .cache = try self.resolveQuery(ids) };
  }

  // --- systems / pipeline ----------------------------------------------------------------------

  // --- systems / pipeline ----------------------------------------------------------------------

  // Shared tail of `system`/`systemRun`/`systemParallel`: build the entry and append it. Keeps the
  // SystemEntry shape (and any future fields) in one place; the per-kind trampoline is the only
  // thing that differs between the three registrations.
  fn registerSystem(self: *World, phase: Phase, name: []const u8, runner: *const fn (*World) void) !void {
    try self.systems.append(self.mem(), .{ .phase = phase, .name = name, .run = runner });
  }

  /// Register a system that runs in `phase`. `func` has the same shape as an `each` callback but
  /// with the world as its context: `func(*World, Entity, *T0, ...)`, so it can read
  /// `world.delta_time`. Systems run in registration order within a phase.
  pub fn system(self: *World, phase: Phase, name: []const u8, comptime terms: anytype, comptime func: anytype) !void {
    const Trampoline = struct {
      fn run(w: *World) void {
        w.each(terms, w, func);
      }
    };
    try self.registerSystem(phase, name, Trampoline.run);
  }

  /// Set the threading backend used by `systemParallel` systems (typically `threaded.io()` from a
  /// `std.Io.Threaded`). Call once at setup. While unset, parallel systems run single-threaded.
  /// The world does not own the backend - keep it alive for the world's lifetime.
  pub fn setIo(self: *World, io: std.Io) void {
    self.io = io;
  }

  /// Register a **column-pass** system: instead of per-entity calls, `func` is invoked once per
  /// matching archetype with whole column slices - `func(*World, []const Entity, []T0, []T1, ...)`
  /// - so the inner loop is yours and the compiler can vectorize it (the DOD-friendly fast path,
  /// vs the pointer-chasing per-entity `system`). Read `world.delta_time` off the `*World` arg.
  /// Runs in `phase`, in registration order. Prefer this over `system` for any hot bulk update.
  pub fn systemRun(self: *World, phase: Phase, name: []const u8, comptime terms: anytype, comptime func: anytype) !void {
    const Trampoline = struct {
      fn run(w: *World) void {
        w.run(terms, w, func);
      }
    };
    try self.registerSystem(phase, name, Trampoline.run);
  }

  /// Register a **parallel column-pass** system: like `systemRun`, but the matched rows are sliced
  /// into chunks of `chunk` (0 = `default_parallel_chunk`) and spread across the world's `io`
  /// worker threads (set via `setIo`). `func(*World, []const Entity, []T0, ...)` then runs on
  /// disjoint sub-slices, possibly on many threads at once - so it MUST obey the `runParallel`
  /// contract: touch only the rows it is handed, make NO structural changes, and treat the shared
  /// `*World` ctx as read-only (read `delta_time`, don't `set`/`remove`/`spawn`). With no `io` set
  /// it degrades to a single-threaded pass, so the same registration is correct either way. This
  /// is the system kind to reach for under the 200-FPS / multithreaded rules.
  pub fn systemParallel(self: *World, phase: Phase, name: []const u8, comptime terms: anytype, comptime chunk: usize, comptime func: anytype) !void {
    const Trampoline = struct {
      fn run(w: *World) void {
        if (w.io) |io| {
          w.runParallel(io, terms, chunk, w, func);
        } else {
          w.run(terms, w, func); // graceful fallback: no backend → single-threaded
        }
      }
    };
    try self.registerSystem(phase, name, Trampoline.run);
  }

  /// Advance the world by `dt` seconds: run every system, phase by phase, in declaration order.
  ///
  /// Runs all systems in a defer scope; structural ops defer + apply after.
  pub fn progress(self: *World, dt: f32) !void {
    self.delta_time = dt;
    self.beginDefer();
    // NOTE: entity()/spawn() are NOT deferred - creating one mid-iteration panics.
    for (std.enums.values(Phase)) |ph| {
      for (self.systems.items) |s| {
        if (s.phase == ph) s.run(self);
      }
    }
    try self.endDefer();
  }

  // --- pre-allocation --------------------------------------------------------------------------

  /// Create `n` entities at once, writing their handles into `out` (which must have room for them).
  /// The new entities carry no components. This grows the entity tables once rather than per
  /// entity, so it is the cheap way to bring a crowd into being before giving them their parts.
  pub fn spawn(self: *World, n: usize, out: []Entity) !void {
    self.assertMutableNow();
    std.debug.assert(out.len >= n);
    try self.records.ensureUnusedCapacity(self.mem(), n);
    try self.archetypes.items[0].entities.ensureUnusedCapacity(self.mem(), n);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = try self.entity();
  }

  /// Create one entity that already carries `components` (a tuple of component *values*, like a
  /// batch of `set`s), landing it directly in the matching archetype. Returns the new entity.
  ///
  /// Unlike calling `set` repeatedly - which walks the entity through one intermediate archetype
  /// per component, copying every prior column each hop - this places the row in its final table
  /// in one shot, then writes each value once. `on_add` and `on_set` hooks fire for every
  /// component, in the order the components appear. Not valid inside a defer scope (it commits
  /// immediately); use `entity` + `set` there. Order of `components` does not matter; duplicate
  /// component types are a compile error.
  pub fn spawnWith(self: *World, components: anytype) !Entity {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    const e = try self.createWith(components);
    return e;
  }

  /// Bulk form of `spawnWith`: create `n` entities that all carry `components`, writing their
  /// handles into `out` (which must have room for `n`). Every row lands in the same archetype,
  /// whose tables are grown once up front, so this is the cheap way to bring a uniform crowd into
  /// being. Each entity gets its own copy of the values; hooks fire per entity. Not valid inside a
  /// defer scope. To vary fields per entity, follow with a `run`/`each` pass over the new rows.
  pub fn spawnManyWith(self: *World, n: usize, out: []Entity, components: anytype) !void {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    std.debug.assert(out.len >= n);
    try self.reserveFor(components, n);
    try self.records.ensureUnusedCapacity(self.mem(), n);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = try self.createWith(components);
  }

  // Resolve the archetype for a value tuple and ensure it can hold `n` more rows without growing.
  fn reserveFor(self: *World, components: anytype, n: usize) !void {
    const fields = @typeInfo(@TypeOf(components)).@"struct".fields;
    const k = fields.len;
    if (k == 0) return;
    var ids: [k]Id = undefined;
    inline for (fields, 0..) |f, i| ids[i] = try self.componentId(f.type);
    std.mem.sort(Id, &ids, {}, std.sort.asc(Id));
    const ai = try self.getOrCreateArchetype(&ids);
    const arch = &self.archetypes.items[ai];
    try arch.entities.ensureTotalCapacity(self.mem(), arch.entities.items.len + n);
    for (arch.columns) |*c| {
      if (c.size > 0) try c.data.ensureTotalCapacity(self.mem(), (arch.entities.items.len + n) * c.size);
    }
  }

  // Create one entity directly in the archetype for `components`, write each value, and fire hooks.
  fn createWith(self: *World, components: anytype) !Entity {
    std.debug.assert(self.defer_depth == 0);
    const fields = @typeInfo(@TypeOf(components)).@"struct".fields;
    const k = fields.len;
    comptime {
      for (fields, 0..) |f, a| for (fields, 0..) |g, b| {
        if (a < b and f.type == g.type)
          @compileError("spawnWith: component '" ++ @typeName(f.type) ++ "' given twice");
      };
    }
    if (k == 0) return self.entity();

    var ids: [k]Id = undefined;
    inline for (fields, 0..) |f, i| ids[i] = try self.componentId(f.type);
    var sig = ids; // sorted copy forms the archetype signature
    std.mem.sort(Id, &sig, {}, std.sort.asc(Id));
    const to = try self.getOrCreateArchetype(&sig);

    // Reserve a record slot and place a fresh row in the target archetype.
    const e = try self.reserveEntityInArchetype(to);

    // Write each component's bytes into its column for this row, then fire its hooks in order.
    const rec = self.recordPtr(e).?;
    const arch = &self.archetypes.items[to];
    inline for (fields, 0..) |f, i| {
      const ci = arch.columnIndex(ids[i]).?;
      const sz = arch.columns[ci].size;
      if (sz > 0) {
        // Copy into a runtime local: a tuple literal's fields can be comptime-only, whose
        // address is not available at runtime.
        var value: f.type = @field(components, f.name);
        @memcpy(arch.columns[ci].data.items[rec.row * sz ..][0..sz], std.mem.asBytes(&value));
      }
    }
    inline for (fields, 0..) |_, i| {
      self.fireHook(ids[i], e, .on_add);
      self.fireHook(ids[i], e, .on_set);
    }
    return e;
  }

  // Allocate an entity record (recycling a free id when one exists) and push a zeroed row for it
  // directly into archetype `to`, without going through the empty archetype first.
  fn reserveEntityInArchetype(self: *World, to: u32) !Entity {
    if (self.free_ids.pop()) |i| {
      const rec = &self.records.items[i];
      rec.alive = true;
      rec.archetype = to;
      const e = makeEntity(i, rec.generation);
      rec.row = @intCast(try self.archetypes.items[to].pushRow(self.mem(), e, &self.structural_version));
      return e;
    }
    const i: u32 = @intCast(self.records.items.len);
    try self.records.append(self.mem(), .{ .archetype = to, .row = 0, .generation = 0, .alive = true });
    const e = makeEntity(i, 0);
    self.records.items[i].row = @intCast(try self.archetypes.items[to].pushRow(self.mem(), e, &self.structural_version));
    return e;
  }

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

  fn hasId(self: *World, e: Entity, id: Id) bool {
    const rec = self.recordPtr(e) orelse return false;
    return self.archetypes.items[rec.archetype].columnIndex(id) != null;
  }

  // The immediate forms of the public operations. The public methods call these when no defer
  // scope is open, and `flush` calls them when replaying a scope's recorded changes.

  fn applyAdd(self: *World, e: Entity, id: Id) !void {
    const had = self.hasId(e, id);
    try self.addIdInternal(e, id);
    if (!had) self.fireHook(id, e, .on_add);
  }

  fn applySet(self: *World, e: Entity, id: Id, bytes: []const u8) !void {
    const had = self.hasId(e, id);
    try self.addIdInternal(e, id);
    if (bytes.len > 0) {
      const rec = self.recordPtr(e).?;
      const arch = &self.archetypes.items[rec.archetype];
      const ci = arch.columnIndex(id).?;
      @memcpy(arch.columns[ci].data.items[rec.row * bytes.len ..][0..bytes.len], bytes);
    }
    if (!had) self.fireHook(id, e, .on_add);
    self.fireHook(id, e, .on_set);
  }

  fn applyRemove(self: *World, e: Entity, id: Id) !void {
    if (!self.hasId(e, id)) return;
    // Fire while `e` still carries `id`, so observers can read the outgoing
    // value via get/getMut; only then move the row to the reduced archetype.
    self.fireHook(id, e, .on_remove);
    try self.removeId(e, id);
  }

  fn applyDelete(self: *World, e: Entity) void {
    const rec = self.recordPtr(e) orelse return;
    const arch_index = rec.archetype;
    const row = rec.row;
    rec.alive = false;
    rec.generation +%= 1;
    const moved = self.archetypes.items[arch_index].swapRemoveRow(row, &self.structural_version);
    if (moved != .none) self.recordPtr(moved).?.row = row;
    // Best effort: if recycling the id fails to allocate, the slot simply is not reused.
    self.free_ids.append(self.mem(), entityIndex(e)) catch {};
  }

  fn enqueue(self: *World, kind: CmdKind, e: Entity, id: Id) !void {
    try self.cmd_list.append(self.mem(), .{ .entity = e, .kind = kind, .id = id });
  }

  fn enqueueSet(self: *World, e: Entity, id: Id, bytes: []const u8) !void {
    const off: u32 = @intCast(self.cmd_data.items.len);
    try self.cmd_data.appendSlice(self.mem(), bytes);
    try self.cmd_list.append(self.mem(), .{ .entity = e, .kind = .set, .id = id, .off = off, .len = @intCast(bytes.len) });
  }

  // Replay the recorded changes in order, then reset the buffers (keeping their capacity). A
  // change aimed at an entity that an earlier change already deleted is skipped, not an error.
  fn flush(self: *World) !void {
    const n = self.cmd_list.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
      const cmd = self.cmd_list.items[i];
      switch (cmd.kind) {
        .add => self.applyAdd(cmd.entity, cmd.id) catch |err| if (err != error.EntityNotAlive) return err,
        .set => self.applySet(cmd.entity, cmd.id, self.cmd_data.items[cmd.off..][0..cmd.len]) catch |err| if (err != error.EntityNotAlive) return err,
        .remove => self.applyRemove(cmd.entity, cmd.id) catch |err| if (err != error.EntityNotAlive) return err,
        .delete => self.applyDelete(cmd.entity),
      }
    }
    self.cmd_list.clearRetainingCapacity();
    self.cmd_data.clearRetainingCapacity();
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

  /// Return the component ID for a type name string (e.g. "shared.Transform"), or null if not registered.
  pub fn componentIdFromName(self: *const World, name: []const u8) ?Id {
    for (self.component_meta.items, 0..) |meta, i| {
      if (std.mem.eql(u8, meta.name, name)) return @as(Id, @intCast(i));
    }
    return null;
  }

  /// Return the component name for a component ID, or null if invalid.
  pub fn componentName(self: *const World, id: Id) ?[]const u8 {
    if (id >= self.component_meta.items.len) return null;
    return self.component_meta.items[id].name;
  }

  /// Return the component size for a component ID, or null if invalid.
  pub fn componentSize(self: *const World, id: Id) ?usize {
    if (id >= self.component_meta.items.len) return null;
    return self.component_meta.items[id].size;
  }

  /// Return raw bytes of component `id` on entity `e`, or null if the entity doesn't have it.
  pub fn getComponentBlob(self: *World, e: Entity, id: Id) ?[]const u8 {
    const rec = self.recordPtr(e) orelse return null;
    const arch = &self.archetypes.items[rec.archetype];
    const col_idx = arch.columnIndex(id) orelse return null;
    const col = &arch.columns[col_idx];
    if (col.size == 0) return null;
    const off = rec.row * col.size;
    return col.data.items[off .. off + col.size];
  }

  /// Write raw bytes directly onto entity `e`'s component `id`. The entity must already have the
  /// component (use `add`/`set` first, or create via `spawnWith`/`createWith`). Bypasses the
  /// typed `set()` path for blob-based instantiation.
  pub fn setRaw(self: *World, e: Entity, id: Id, bytes: []const u8) !void {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    const rec = self.recordPtr(e) orelse return error.EntityNotAlive;
    const arch = &self.archetypes.items[rec.archetype];
    const col_idx = arch.columnIndex(id) orelse return error.ComponentNotOnEntity;
    const col = &arch.columns[col_idx];
    if (bytes.len != col.size) return error.BlobSizeMismatch;
    const off = rec.row * col.size;
    @memcpy(col.data.items[off .. off + col.size], bytes);
  }

  /// Create one entity directly in the archetype for `ids`, writing each blob into the matching
  /// column. `blobs[i]` must contain exactly `componentSize(ids[i])` bytes. This avoids the
  /// per-component archetype transitions of `addId` + `setRaw`, landing the row in one shot.
  /// Order of `ids` does not matter (sorted internally). Returns the new entity.
  pub fn createFromComponents(self: *World, ids: []const Id, blobs: []const []const u8) !Entity {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    std.debug.assert(ids.len == blobs.len);
    if (ids.len == 0) return self.entity();

    const sig = try self.gpa.dupe(Id, ids);
    defer self.gpa.free(sig);
    std.mem.sort(Id, sig, {}, std.sort.asc(Id));

    const to = try self.getOrCreateArchetype(sig);
    const arch = &self.archetypes.items[to];
    const e = try self.reserveEntityInArchetype(to);
    const rec = self.recordPtr(e).?;

    for (ids, 0..) |id, i| {
      const ci = arch.columnIndex(id).?;
      const col = &arch.columns[ci];
      const sz = col.size;
      if (sz > 0) {
        const off = rec.row * sz;
        @memcpy(col.data.items[off .. off + sz], blobs[i]);
      }
    }

    for (ids) |id| {
      self.fireHook(id, e, .on_add);
      self.fireHook(id, e, .on_set);
    }

    return e;
  }

  /// Bulk form of `createFromComponents`: create `n` entities that all carry `ids`, writing
  /// each blob into the matching column for every entity. Every row lands in the same archetype
  /// in one shot. Writes entity handles into `out` (must have room for `n`).
  pub fn spawnManyFromBlob(
    self: *World,
    ids: []const Id,
    blobs: []const []const u8,
    n: usize,
    out: []Entity,
  ) !void {
    self.assertMutableNow(); // forbid structural mutation during a parallel pass
    std.debug.assert(ids.len == blobs.len);
    std.debug.assert(out.len >= n);
    if (ids.len == 0) return self.spawn(n, out);

    const sig = try self.gpa.dupe(Id, ids);
    defer self.gpa.free(sig);
    std.mem.sort(Id, sig, {}, std.sort.asc(Id));

    const to = try self.getOrCreateArchetype(sig);
    const arch = &self.archetypes.items[to];

    // Pre-grow: entities + column data for n rows
    try arch.entities.ensureTotalCapacity(self.mem(), arch.entities.items.len + n);
    for (arch.columns) |*c| {
      if (c.size > 0) try c.data.ensureTotalCapacity(self.mem(), (arch.entities.items.len + n) * c.size);
    }
    try self.records.ensureUnusedCapacity(self.mem(), n);

    var i: usize = 0;
    while (i < n) : (i += 1) {
      const e = try self.reserveEntityInArchetype(to);
      out[i] = e;
      const rec = self.recordPtr(e).?;

      for (ids, 0..) |id, j| {
        const ci = arch.columnIndex(id).?;
        const col = &arch.columns[ci];
        const sz = col.size;
        if (sz > 0) {
          const off = rec.row * sz;
          @memcpy(col.data.items[off .. off + sz], blobs[j]);
        }
      }

      for (ids) |id| {
        self.fireHook(id, e, .on_add);
        self.fireHook(id, e, .on_set);
      }
    }
  }

  /// Return the component IDs that entity `e` currently carries (in archetype signature order).
  /// Writes into `out` and returns the count (capped at `out.len`).
  pub fn entityComponentIds(self: *World, e: Entity, out: []Id) usize {
    // *World (not *const): recordPtr is non-const. Latent until called (the recurring trap).
    const rec = self.recordPtr(e) orelse return 0;
    const arch = &self.archetypes.items[rec.archetype];
    const sig = arch.signature;
    const n = if (sig.len < out.len) sig.len else out.len;
    @memcpy(out[0..n], sig[0..n]);
    return n;
  }

  /// Get the archetype signature (component IDs) for the archetype of entity `e`. Returns the
  /// signature slice, or null if the entity is not alive.
  pub fn entityArchetypeSignature(self: *World, e: Entity) ?[]const Id {
    // *World (not *const): recordPtr is non-const. Latent until called (only the rotted Prefab does).
    const rec = self.recordPtr(e) orelse return null;
    return self.archetypes.items[rec.archetype].signature;
  }

  // Return the archetype indices matching the given term ids, cached across calls. On a cache hit
  // with an unchanged archetype version this does not allocate: it sorts the tiny term array on
  // the stack to form the key and looks it up. A held `Query` skips even this by keeping the cache
  // pointer from `resolveQuery` and calling `ensureFresh` directly.
  fn matchedArchetypes(self: *World, term_ids: anytype) ![]const u32 {
    const qc = try self.resolveQuery(term_ids);
    try self.ensureFresh(qc, term_ids);
    return qc.matched.items;
  }

  // Find or create the cache slot for a set of term ids, keyed by their sorted form.
  fn resolveQuery(self: *World, term_ids: anytype) !*QueryCache {
    var key = term_ids; // copy; sorting canonicalizes so term order does not fork the cache
    std.mem.sort(Id, &key, {}, std.sort.asc(Id));

    if (self.query_cache.getContext(&key, .{})) |qc| return qc;

    const owned = try self.mem().dupe(Id, &key);
    const qc = try self.mem().create(QueryCache);
    qc.* = .{ .version = self.archetype_version -% 1, .matched = .empty }; // mismatch forces a refresh
    try self.query_cache.putContext(self.mem(), owned, qc, .{});
    return qc;
  }

  // Rebuild a cache's match list only if a new archetype has appeared since it was last built.
  fn ensureFresh(self: *World, qc: *QueryCache, term_ids: anytype) !void {
    if (qc.version == self.archetype_version) return;
    qc.matched.clearRetainingCapacity();
    var ai: u32 = 0;
    while (ai < self.archetypes.items.len) : (ai += 1) {
      if (archetypeMatches(&self.archetypes.items[ai], term_ids)) try qc.matched.append(self.mem(), ai);
    }
    qc.version = self.archetype_version;
  }

  fn pairId(self: *World, comptime Relation: type, target: Entity) !Id {
    const rel = try self.componentId(Relation);
    return pairIdOf(rel, target);
  }

  fn sizeOfId(self: *World, id: Id) usize {
    if (id & PAIR_FLAG != 0) return 0; // a pair carries no data, so its column size is zero
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

  fn addIdInternal(self: *World, e: Entity, id: Id) !void {
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
    const new_row = try self.archetypes.items[to].pushRow(self.mem(), e, &self.structural_version);

    const a = &self.archetypes.items[from];
    const b = &self.archetypes.items[to];
    for (a.signature, 0..) |id, ai| {
      const s = a.columns[ai].size;
      if (s == 0) continue;
      if (b.columnIndex(id)) |bi| {
        @memcpy(b.columns[bi].data.items[new_row * s ..][0..s], a.columns[ai].data.items[old_row * s ..][0..s]);
      }
    }

    const moved = self.archetypes.items[from].swapRemoveRow(old_row, &self.structural_version);
    if (moved != .none) self.recordPtr(moved).?.row = @intCast(old_row);

    const rec = self.recordPtr(e).?;
    rec.archetype = to;
    rec.row = @intCast(new_row);
  }
};

/// A reusable query handle from `World.query`. It holds the resolved component ids and a pointer to
/// the match cache, so each sweep is a quick freshness check and a walk of the matching tables. Its
/// `each`, `run`, and `count` behave exactly like the same-named methods on the world.
pub fn Query(comptime terms: anytype) type {
  const n = terms.len;
  return struct {
    world: *World,
    ids: [n]Id,
    cache: *QueryCache,
    const Self = @This();

    pub fn each(self: Self, ctx: anytype, comptime func: anytype) void {
      self.sweep(ctx, func, iterArchetype);
    }

    pub fn run(self: Self, ctx: anytype, comptime func: anytype) void {
      self.sweep(ctx, func, runArchetype);
    }

    pub fn count(self: Self) usize {
      const list = self.matched() orelse return self.scanCount();
      var total: usize = 0;
      for (list) |ai| total += self.world.archetypes.items[ai].entities.items.len;
      return total;
    }

    /// A `while (it.next()) |e|` iterator over this query, the same as `World.view`.
    pub fn iterator(self: Self) View(terms) {
      return .{ .world = self.world, .ids = self.ids, .start_arch_version = self.world.archetype_version, .start_structural_version = self.world.structural_version };
    }

    // The cached match list, refreshed if a table has appeared, or null if the refresh could
    // not allocate (the callers then fall back to a direct scan, which never allocates).
    fn matched(self: Self) ?[]const u32 {
      self.world.ensureFresh(self.cache, self.ids) catch return null;
      return self.cache.matched.items;
    }

    inline fn sweep(self: Self, ctx: anytype, comptime func: anytype, comptime visitor: anytype) void {
      if (self.matched()) |list| {
        for (list) |ai| visitor(self.world, &self.world.archetypes.items[ai], terms, self.ids, ctx, func);
      } else {
        var ai: usize = 0;
        while (ai < self.world.archetypes.items.len) : (ai += 1) {
          const arch = &self.world.archetypes.items[ai];
          if (archetypeMatches(arch, self.ids)) visitor(self.world, arch, terms, self.ids, ctx, func);
        }
      }
    }

    fn scanCount(self: Self) usize {
      var total: usize = 0;
      var ai: usize = 0;
      while (ai < self.world.archetypes.items.len) : (ai += 1) {
        if (archetypeMatches(&self.world.archetypes.items[ai], self.ids)) total += self.world.archetypes.items[ai].entities.items.len;
      }
      return total;
    }
  };
}

/// A plain Zig iterator over a query, from `World.view` or `Query.iterator`. Walk it with
/// `while (it.next()) |e|`, and read the current entity's components with `it.get(T)`.
pub fn View(comptime terms: anytype) type {
  const n = terms.len;
  return struct {
    world: *World,
    ids: [n]Id = undefined,
    done: bool = false,
    scan: usize = 0, // next archetype index to consider
    arch: ?*Archetype = null,
    cols: [n]usize = undefined,
    row: usize = 0, // next row to return within `arch`
    cur: usize = 0, // row the last next() returned, used by get()
    /// `archetype_version` at iterator creation. If a new archetype is created mid-iteration the
    /// `archetypes` array reallocs and `arch` dangles - we detect the bump and panic clearly.
    start_arch_version: u64 = 0,
    /// `structural_version` at creation; catches same-archetype row moves mid-loop.
    start_structural_version: u64 = 0,
    const Self = @This();

    /// The next matching entity, or null once the query is exhausted.
    pub fn next(self: *Self) ?Entity {
      if (self.done) return null;
      if (self.world.archetype_version != self.start_arch_version) {
        @panic("zhecs: structural change (new archetype) DURING query iteration - adding a component/" ++
          "spawning that creates a new archetype reallocates storage and invalidates this iterator. " ++
          "Collect the entities first, then mutate after the loop (or use the deferred ops in a system).");
      }
      if (self.world.structural_version != self.start_structural_version) {
        @panic("zhecs: structural change (row move) DURING query iteration - a delete/remove/add that " ++
          "lands an entity in an existing archetype still swap-removes a row and invalidates this " ++
          "iterator. Collect the entities first, then mutate after the loop (or use deferred ops).");
      }
      while (true) {
        if (self.arch) |a| {
          if (self.row < a.entities.items.len) {
            self.cur = self.row;
            self.row += 1;
            return a.entities.items[self.cur];
          }
        }
        // Advance to the next archetype that holds every term, skipping empty ones.
        self.arch = null;
        while (self.scan < self.world.archetypes.items.len) {
          const a = &self.world.archetypes.items[self.scan];
          self.scan += 1;
          if (archetypeMatches(a, self.ids)) {
            inline for (0..n) |i| self.cols[i] = a.columnIndex(self.ids[i]).?;
            self.arch = a;
            self.row = 0;
            break;
          }
        }
        if (self.arch == null) return null;
      }
    }

    /// Mutable pointer to the current entity's `T`; `T` must be one of the query's terms.
    pub fn get(self: *Self, comptime T: type) *T {
      const i = comptime termIndex(terms, T);
      return columnPtr(T, &self.arch.?.columns[self.cols[i]], self.cur);
    }
  };
}

fn termIndex(comptime terms: anytype, comptime T: type) comptime_int {
  inline for (terms, 0..) |U, i| {
    if (U == T) return i;
  }
  @compileError("component " ++ @typeName(T) ++ " is not one of the query's terms");
}

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
inline fn iterArchetype(world: *World, arch: *Archetype, comptime terms: anytype, term_ids: anytype, ctx: anytype, comptime func: anytype) void {
  const n = terms.len;
  const cnt = arch.entities.items.len;
  if (cnt == 0) return;
  var cols: [n]usize = undefined;
  inline for (0..n) |i| cols[i] = arch.columnIndex(term_ids[i]).?;

  const start_sv = world.structural_version;
  var row: usize = 0;
  while (row < cnt) : (row += 1) {
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = ctx;
    args[1] = arch.entities.items[row];
    inline for (terms, 0..) |T, i| {
      args[2 + i] = columnPtr(T, &arch.columns[cols[i]], row);
    }
    @call(.auto, func, args);
    // Structural mutation in the callback moved rows; panic before the next read.
    if (world.structural_version != start_sv) structuralChangeInVisitor();
  }
}

// Per-chunk visitor: call `func(ctx, []const Entity, []T0, ...)` once with the whole archetype's
// column slices, leaving the inner loop to the caller so the compiler can vectorize it.
inline fn runArchetype(world: *World, arch: *Archetype, comptime terms: anytype, term_ids: anytype, ctx: anytype, comptime func: anytype) void {
  const cnt = arch.entities.items.len;
  if (cnt == 0) return;
  const start_sv = world.structural_version;
  var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
  args[0] = ctx;
  args[1] = arch.entities.items[0..cnt];
  inline for (terms, 0..) |T, i| {
    const ci = arch.columnIndex(term_ids[i]).?;
    args[2 + i] = columnSlice(T, &arch.columns[ci], cnt);
  }
  @call(.auto, func, args);
  // A structural change inside func invalidates its slices; flag the misuse.
  if (world.structural_version != start_sv) structuralChangeInVisitor();
}

fn structuralChangeInVisitor() noreturn {
  @panic("zhecs: structural change DURING each/run callback - add/remove/delete/spawn moves rows " ++
    "and invalidates the iterator's slices. Wrap the loop in a defer scope (beginDefer/endDefer) " ++
    "so the changes are queued and applied after, or collect entities and mutate after the loop.");
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

test "eachChild / getChildren return exactly the direct children of a parent" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const p = try w.entity();
  const other = try w.entity(); // a second parent, to prove isolation
  const c0 = try w.entity();
  const c1 = try w.entity();
  const c2 = try w.entity();
  const grandchild = try w.entity();

  try w.childOf(c0, p);
  try w.childOf(c1, p);
  try w.childOf(c2, p);
  try w.childOf(grandchild, c0); // child of c0, NOT a direct child of p
  try w.childOf(other, p); // unrelated extra child to keep counts honest? no - count it

  // getChildren: collect direct children of p (c0,c1,c2,other = 4), order-independent.
  var buf: [8]Entity = undefined;
  const n = w.getChildren(p, &buf);
  try testing.expectEqual(@as(usize, 4), n);
  var seen_grandchild = false;
  for (buf[0..n]) |ch| if (ch == grandchild) {
    seen_grandchild = true;
  };
  try testing.expect(!seen_grandchild); // grandchild is c0's child, not p's

  // eachChild: same set via the callback form.
  const Counter = struct {
    var count: usize = 0;
    fn cb(_: void, _: Entity) void {
      count += 1;
    }
  };
  Counter.count = 0;
  w.eachChild(p, {}, Counter.cb);
  try testing.expectEqual(@as(usize, 4), Counter.count);

  // c0 has exactly one child (the grandchild).
  try testing.expectEqual(@as(usize, 1), w.getChildren(c0, &buf));
  try testing.expectEqual(grandchild, buf[0]);
}

test "systemRun column pass and systemParallel fallback both run via progress" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const Position = struct { x: f32 };
  const Velocity = struct { x: f32 };

  var ents: [5]Entity = undefined;
  try w.spawn(5, &ents);
  for (ents) |e| {
    try w.set(e, Position{ .x = 0 });
    try w.set(e, Velocity{ .x = 2 });
  }

  // Column-pass system: integrate position by velocity * dt.
  try w.systemRun(.on_update, "move", .{ Position, Velocity }, struct {
    fn run(world: *World, _: []const Entity, ps: []Position, vs: []const Velocity) void {
      for (ps, vs) |*p, v| p.x += v.x * world.delta_time;
    }
  }.run);

  // Parallel system with no io set → single-threaded fallback path. Adds 1 to each x.
  try w.systemParallel(.on_update, "bump", .{Position}, 0, struct {
    fn run(_: *World, _: []const Entity, ps: []Position) void {
      for (ps) |*p| p.x += 1;
    }
  }.run);

  try w.progress(1.0); // dt=1 → move adds 2, then bump adds 1 → x = 3
  for (ents) |e| try testing.expectEqual(@as(f32, 3.0), w.get(e, Position).?.x);
}

test "createFromComponents: runtime archetype entity from raw blobs" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const Position = struct { x: f32, y: f32 };
  const Tag = struct { name: [8]u8 };

  const pos_id = try w.componentId(Position);
  const tag_id = try w.componentId(Tag);

  // Position blob: { x: 3.0, y: 7.0 }
  var pos_val: Position = .{ .x = 3.0, .y = 7.0 };
  const pos_blob = std.mem.asBytes(&pos_val);

  // Tag blob: { name: "blob_tag" }
  var tag_val: Tag = .{ .name = "blob_tag".* };
  const tag_blob = std.mem.asBytes(&tag_val);

  const ids = [_]Id{ pos_id, tag_id };
  const blobs = [_][]const u8{ pos_blob, tag_blob };

  const e = try w.createFromComponents(&ids, &blobs);

  try testing.expect(w.has(e, Position));
  try testing.expect(w.has(e, Tag));

  const pos = w.get(e, Position).?;
  try testing.expectEqual(@as(f32, 3.0), pos.x);
  try testing.expectEqual(@as(f32, 7.0), pos.y);

  const tag = w.get(e, Tag).?;
  try testing.expectEqualStrings("blob_tag", tag.name[0..8]);
}

test "createFromComponents: unsorted ids produce correct entity" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const A = struct { a: f32 };
  const B = struct { b: f32 };

  const a_id = try w.componentId(A);
  const b_id = try w.componentId(B);

  var a_val: A = .{ .a = 42.0 };
  var b_val: B = .{ .b = 99.0 };

  // Pass ids in reverse order (b, a) - should sort internally
  const ids = [_]Id{ b_id, a_id };
  const blobs = [_][]const u8{ std.mem.asBytes(&b_val), std.mem.asBytes(&a_val) };

  const e = try w.createFromComponents(&ids, &blobs);

  try testing.expectEqual(@as(f32, 42.0), w.get(e, A).?.a);
  try testing.expectEqual(@as(f32, 99.0), w.get(e, B).?.b);
}

test "spawnManyFromBlob: bulk entities from raw blobs" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const Position = struct { x: f32, y: f32 };
  const Health = struct { hp: i32 };

  const pos_id = try w.componentId(Position);
  const hp_id = try w.componentId(Health);

  var pos_val: Position = .{ .x = 1.0, .y = 2.0 };
  var hp_val: Health = .{ .hp = 100 };

  const ids = [_]Id{ pos_id, hp_id };
  const blobs = [_][]const u8{ std.mem.asBytes(&pos_val), std.mem.asBytes(&hp_val) };

  var ents: [4]Entity = undefined;
  try w.spawnManyFromBlob(&ids, &blobs, 4, &ents);

  for (ents) |e| {
    try testing.expect(w.has(e, Position));
    try testing.expect(w.has(e, Health));
    try testing.expectEqual(@as(f32, 1.0), w.get(e, Position).?.x);
    try testing.expectEqual(@as(f32, 2.0), w.get(e, Position).?.y);
    try testing.expectEqual(@as(i32, 100), w.get(e, Health).?.hp);
  }

  // Verify all entities are distinct
  for (ents, 0..) |e1, i| {
    for (ents[i + 1 ..]) |e2| {
      try testing.expect(e1 != e2);
    }
  }
}

test "createFromComponents + spawnManyFromBlob: independent entities, independent mutations" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const Val = struct { v: f32 };
  const val_id = try w.componentId(Val);

  var v1: Val = .{ .v = 1.0 };
  var v2: Val = .{ .v = 2.0 };

  // Two single-component entities from blobs
  const ids1 = [_]Id{ val_id };
  const blobs1 = [_][]const u8{ std.mem.asBytes(&v1) };
  const e1 = try w.createFromComponents(&ids1, &blobs1);

  const blobs2 = [_][]const u8{ std.mem.asBytes(&v2) };
  const e2 = try w.createFromComponents(&ids1, &blobs2);

  try testing.expectEqual(@as(f32, 1.0), w.get(e1, Val).?.v);
  try testing.expectEqual(@as(f32, 2.0), w.get(e2, Val).?.v);

  // Mutate e1, verify e2 unaffected
  w.getMut(e1, Val).?.v = 99.0;
  try testing.expectEqual(@as(f32, 99.0), w.get(e1, Val).?.v);
  try testing.expectEqual(@as(f32, 2.0), w.get(e2, Val).?.v);
}

test "componentName/componentSize return correct metadata (was indexing the ArrayList, not its items)" {
  const Meta = struct { x: f32 = 0, y: u32 = 0, z: u8 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();
  const e = try w.entity();
  try w.add(e, Meta); // registers Meta → assigns a component id + meta
  const id = w.componentIdFromName(@typeName(Meta)) orelse return error.NoId;
  try testing.expectEqualStrings(@typeName(Meta), w.componentName(id).?);
  try testing.expectEqual(@as(usize, @sizeOf(Meta)), w.componentSize(id).?);
  try testing.expect(w.componentName(9999) == null and w.componentSize(9999) == null);
}

test "runSoa + runVectorized over a component field (zero-capacity-append fix)" {
  const Vel = struct { v: f32 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();
  inline for (.{ 1.0, 2.0, 3.0 }) |val| {
    const e = try w.entity();
    try w.set(e, Vel{ .v = val });
  }
  const Sum = struct {
    fn f(s: *f32, slice: []f32) void {
      for (slice) |x| s.* += x;
    }
  };
  var sum: f32 = 0;
  runSoa(&w, Vel, .v, &sum, Sum.f);
  try testing.expectEqual(@as(f32, 6.0), sum);

  // Double each v in place, then re-sum → 12.
  runVectorized(&w, Vel, .v, 4, struct {
    fn op(v: @Vector(4, f32)) @Vector(4, f32) {
      return v * @as(@Vector(4, f32), @splat(2));
    }
  }.op);
  var sum2: f32 = 0;
  runSoa(&w, Vel, .v, &sum2, Sum.f);
  try testing.expectEqual(@as(f32, 12.0), sum2);
}

test "isAlive + entityComponentIds (latent introspection helpers)" {
  const A = struct { x: f32 = 0 };
  const B = struct { y: u32 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();
  const e = try w.entity();
  try testing.expect(w.isAlive(e));
  try w.add(e, A);
  try w.add(e, B);
  var ids: [8]Id = undefined;
  try testing.expectEqual(@as(usize, 2), w.entityComponentIds(e, &ids));
  w.delete(e);
  try testing.expect(!w.isAlive(e));
}

test "addPair / hasPair / removePair relationship cycle (removePair was never exercised)" {
  const Likes = struct {};
  var w = try World.init(testing.allocator);
  defer w.deinit();
  const a = try w.entity();
  const b = try w.entity();
  try testing.expect(!w.hasPair(a, Likes, b));
  try w.addPair(a, Likes, b);
  try testing.expect(w.hasPair(a, Likes, b));
  try w.removePair(a, Likes, b);
  try testing.expect(!w.hasPair(a, Likes, b));
}

test "relationship pair rejects a recycled target (fix-arch-04)" {
  var w = try World.init(testing.allocator);
  defer w.deinit();

  const par = try w.entity();
  const child = try w.entity();
  try w.childOf(child, par);
  try testing.expectEqual(par, w.parent(child).?);
  try testing.expect(w.hasPair(child, ChildOf, par));

  // Delete the parent: its slot index is freed and its generation bumped.
  w.delete(par);

  // The next entity recycles the parent's slot (same index, newer generation).
  const recycled = try w.entity();
  try testing.expectEqual(entityIndex(par), entityIndex(recycled)); // confirm same slot

  // parent/getTarget must return none, NOT the recycled occupant.
  try testing.expect(w.parent(child) == null);
  try testing.expect(w.getTarget(child, ChildOf) == null);
  // hasPair against the recycled entity must not match the old relationship.
  try testing.expect(!w.hasPair(child, ChildOf, recycled));
  // The recycled entity inherits no children.
  var kids: [4]Entity = undefined;
  try testing.expectEqual(@as(usize, 0), w.getChildren(recycled, &kids));
}

test "query iteration + value-updates is safe (iteration guard does not false-positive)" {
  const V = struct { v: f32 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();
  inline for (.{ 1.0, 2.0, 3.0 }) |val| {
    const e = try w.entity();
    try w.set(e, V{ .v = val });
  }
  // The common pattern: iterate a query and mutate component VALUES in place. This must NOT trip the
  // archetype-version guard (only NEW-archetype structural changes during iteration do).
  var q = try w.query(.{V});
  var it = q.iterator();
  var n: usize = 0;
  while (it.next()) |e| {
    w.getMut(e, V).?.v += 10;
    n += 1;
  }
  try testing.expectEqual(@as(usize, 3), n);
}

test "structural guard catches a same-archetype row move that archetype_version misses (fix-arch-03)" {
  const P = struct { x: f32 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();

  // Three entities all carrying P land in the SAME archetype.
  const e0 = try w.entity();
  try w.set(e0, P{ .x = 0 });
  const e1 = try w.entity();
  try w.set(e1, P{ .x = 1 });
  const e2 = try w.entity();
  try w.set(e2, P{ .x = 2 });

  var v = w.view(.{P});
  _ = v.next(); // begin iterating; the view captured the versions at creation
  const arch_v = w.archetype_version;

  // Delete an entity: it swap-removes a row but creates NO new archetype.
  w.delete(e2);

  // The OLD archetype_version guard is unchanged: it would miss this row move.
  try testing.expectEqual(arch_v, w.archetype_version);
  // structural_version advanced, so View.next detects it and panics next call.
  try testing.expect(w.structural_version != v.start_structural_version);
  _ = .{ e0, e1 };
}

test "each callback may delete a sibling under a defer scope without OOB (fix-arch-03)" {
  const P = struct { x: f32 = 0 };
  var w = try World.init(testing.allocator);
  defer w.deinit();

  var ids: [5]Entity = undefined;
  for (0..5) |i| {
    ids[i] = try w.entity();
    try w.set(ids[i], P{ .x = @floatFromInt(i) });
  }

  // Deferred delete is queued; each visits all rows, applied after scope.
  const Ctx = struct { w: *World, victim: Entity, seen: usize };
  var c = Ctx{ .w = &w, .victim = ids[4], .seen = 0 };
  w.beginDefer();
  w.each(.{P}, &c, struct {
    fn f(cx: *Ctx, e: Entity, p: *P) void {
      _ = .{ e, p };
      if (cx.seen == 0) cx.w.delete(cx.victim); // one deferred sibling delete
      cx.seen += 1;
    }
  }.f);
  try w.endDefer();

  try testing.expectEqual(@as(usize, 5), c.seen); // visited every row, no OOB
  try testing.expect(!w.isAlive(ids[4])); // the queued delete took effect after the scope
}
