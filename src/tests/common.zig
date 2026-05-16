//! Shared component and tag types for the test suite, so each test file stays focused on its cases.

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };
pub const Health = struct { hp: i32 };

pub const Frozen = struct {}; // tag
pub const Dead = struct {}; // tag

pub const Likes = struct {}; // relationship
pub const Owns = struct {}; // relationship

/// An over-aligned component, to exercise the alignment casts in column access.
pub const Aligned = struct { lead: u8, big: u128 };

/// A large component, to exercise column growth and the byte copy during a table move.
pub const Big = struct { bytes: [300]u8 };

/// A family of distinct component types indexed by a comptime integer, for wide-archetype tests.
/// Memoised by the compiler, so `Comp(3)` is the same type everywhere it appears.
pub fn Comp(comptime i: usize) type {
    return struct {
        const slot = i;
        v: u32,
    };
}
