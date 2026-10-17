//! **WHAT `between` ANSWERS, AND WHAT IT IS HANDED** (zig-metal-unikernel's
//! docs/designs/DESIGN-sleep.md). Part of the `webbox` library, re-exported
//! by site.zig. A file of its own, with no imports, so zig-metal-unikernel's
//! tier 0 holds a byte-for-byte copy (its src/pinned/webbox_wake.zig) and
//! needs no checkout of this one.

/// **WHEN THE APPLICATION NEXT NEEDS A TURN** (zig-metal-unikernel's
/// docs/designs/DESIGN-sleep.md), what its `between` answers. The same
/// promise on every host: called once its time comes, as soon as the host
/// can after it, and maybe sooner too (`between` checks its own clock).
pub const Wake = union(enum) {
    /// More to do now: called again on the next free turn.
    more,
    /// Nothing before this time on the awake clock (`Now.awake_ns`), unless
    /// a request comes first. Within one boot or one process: never stored.
    at: i96,
    /// Nothing until a request, or the end of the application's own fetch.
    idle,
};

/// The two clocks a host hands `between`: the awake clock, which only moves
/// forward and is what `Wake.at` is in, and the wall clock in Unix seconds,
/// which a script's `.now` and a log line read.
pub const Now = struct { awake_ns: i96, unix_s: i64 };
