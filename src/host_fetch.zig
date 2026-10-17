//! host_fetch: **ONE GET, FROM THE APPLICATION, THROUGH ITS HOST**
//! (zig-metal-unikernel's docs/designs/DESIGN-sleep.md, "The host's fetch").
//! Part of the `webbox` library.
//!
//! An application cannot reach a network itself: on the bare-metal host the
//! TCP client is the kernel's, inside its own turn of the network; on Linux
//! the stack is the operating system's, and a fetch inside the turn would hold
//! up every request. So the host offers one fetch at a time, the same shape on
//! both: `start` it from `between`, and read `result` on a later call, which
//! the host makes as soon as the fetch ends (the host's `between` contract).
//!
//! The outcomes are the kernel's client's words (fetch.zig's `Outcome`), so a
//! line about a poll reads the same on both hosts. Each host says which it can
//! produce: `no_arp` is metal's word for nobody answering at the address
//! (Linux's EHOSTUNREACH); `given_up` is metal's retransmission timer (Linux's
//! deadlines end a fetch first); `no_route` is an address off the machine's
//! own network (metal fetches on-link only).

const std = @import("std");

pub const Target = struct { ip: [4]u8, port: u16, path: []const u8 };

/// The fetch's three bounds, each from its start: established by
/// `connect_ms`, never silent for `idle_ms`, done by `total_ms`.
pub const Deadlines = struct { connect_ms: u32, idle_ms: u32, total_ms: u32 };

pub const Outcome = enum {
    /// A 200, with as many body bytes as its content-length says (or, with
    /// none, everything up to the server's FIN).
    ok,
    /// Nobody listens at the port: a reset to the SYN.
    refused,
    connect_deadline,
    idle_deadline,
    total_deadline,
    /// The retransmission timer ran out (metal only: Linux's deadlines end a
    /// fetch before its own retries do).
    given_up,
    /// The server reset the connection after it was made.
    reset,
    /// Not a 200, a head too big, or more body than it said.
    bad_answer,
    /// Nobody answered at the address (metal: ARP; Linux: EHOSTUNREACH).
    no_arp,
    /// The server finished before the body its content-length promised.
    short_answer,
    /// A body past `body_most`: the host keeps no more.
    too_long,
    /// The address is not on the machine's own network (metal fetches
    /// on-link only, and a machine whose lease named no network fetches
    /// nothing); on Linux, ENETUNREACH or EADDRNOTAVAIL.
    no_route,
};

/// The most body a host keeps for a fetch.
pub const body_most = 64 * 1024;

/// How a fetch ended. `body` is the host's, good until the next `start`.
pub const Result = struct { outcome: Outcome, status: u16, body: []const u8 };

/// The longest path a host fetches: past it, `start` refuses, never a
/// shorter path asked instead.
pub const path_most = 256;

/// Why a fetch did not start: one is running, or its end is not yet taken
/// (`Busy`), or its path is past `path_most`.
pub const StartError = error{ Busy, PathTooLong };

/// What a host provides. `start` copies what it needs of `target` (its path);
/// `result` hands the ended fetch over once, then null until the next.
pub const Fetcher = struct {
    start: *const fn (target: Target, deadlines: Deadlines) StartError!void,
    result: *const fn () ?Result,
};

var fetcher: ?Fetcher = null;

/// The host calls it once at startup.
pub fn provide(f: Fetcher) void {
    fetcher = f;
}

/// Starts a fetch. `Busy` while one is running or its end is unread;
/// `PathTooLong` past `path_most`; `NoFetch` on a host that offers none (a
/// unit test's site, started with no host).
pub fn start(target: Target, deadlines: Deadlines) (StartError || error{NoFetch})!void {
    const f = fetcher orelse return error.NoFetch;
    if (target.path.len > path_most) return error.PathTooLong;
    return f.start(target, deadlines);
}

/// The ended fetch, once; null while it runs, and after it was handed over.
pub fn result() ?Result {
    const f = fetcher orelse return null;
    return f.result();
}

test "host_fetch: no host, no fetch; a host's fetch is started once at a time and its end handed over once" {
    const Fake = struct {
        var running = false;
        var ended: ?Result = null;
        fn startIt(_: Target, _: Deadlines) StartError!void {
            if (running) return error.Busy;
            running = true;
        }
        fn resultIt() ?Result {
            const r = ended orelse return null;
            ended = null;
            running = false;
            return r;
        }
    };
    const was = fetcher;
    defer fetcher = was;
    fetcher = null;
    const t: Target = .{ .ip = .{ 10, 100, 0, 3 }, .port = 80, .path = "/version" };
    const d: Deadlines = .{ .connect_ms = 150, .idle_ms = 1000, .total_ms = 3000 };
    try std.testing.expectError(error.NoFetch, start(t, d));
    try std.testing.expectEqual(@as(?Result, null), result());
    provide(.{ .start = Fake.startIt, .result = Fake.resultIt });
    try start(t, d);
    try std.testing.expectError(error.Busy, start(t, d));
    try std.testing.expectError(error.PathTooLong, start(.{ .ip = t.ip, .port = 80, .path = "/" ** (path_most + 1) }, d));
    try std.testing.expectEqual(@as(?Result, null), result());
    Fake.ended = .{ .outcome = .ok, .status = 200, .body = "{}" };
    try std.testing.expectEqual(Outcome.ok, result().?.outcome);
    try std.testing.expectEqual(@as(?Result, null), result());
    try start(t, d);
}
