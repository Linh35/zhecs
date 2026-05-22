//! Aggregator for the public-API test suite. Each topic lives in its own file under tests/; this
//! pulls them in so a single `zig build test` runs them all. Tests that need access to library
//! internals stay next to the implementation in zhecs.zig.

comptime {
    _ = @import("tests/lifecycle.zig");
    _ = @import("tests/components.zig");
    _ = @import("tests/queries.zig");
    _ = @import("tests/pipeline.zig");
    _ = @import("tests/relationships.zig");
    _ = @import("tests/deferred.zig");
    _ = @import("tests/query_handle.zig");
    _ = @import("tests/spawn.zig");
    _ = @import("tests/interop.zig");
    _ = @import("tests/fuzz.zig");
}
