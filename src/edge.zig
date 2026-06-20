//! edge: the one policy for incoming data at the server's edges.
//!
//! THREAT MODEL (read this first). Prod ships ReleaseSafe, so zig's bounds and
//! integer-overflow checks are ON: a classic C-style buffer overflow — write
//! past a buffer, corrupt adjacent memory, keep running — cannot happen. If we
//! ever index/copy out of bounds we PANIC (clean crash, systemd restarts). So
//! the realistic "overflow" attack here is a panic-as-DoS: feed input that
//! drives an edge past a fixed buffer and kill the worker. The defence is to
//! BOUND every edge so oversized/malformed input is rejected gracefully —
//! reaching neither the panic nor a silent truncation.
//!
//! POLICY (four rules):
//!   1. Every edge has an explicit, named byte/count bound (no inline magic).
//!   2. Exceeding a bound is REJECTED — never truncated, never panicked into.
//!      The status is fixed by category (statusFor): 431 header, 413 body size,
//!      400 malformed. The human message stays caller-specific (it's UX).
//!   3. Every rejection is OBSERVABLE: a process-wide atomic counter per kind.
//!   4. Tests assert the counter moved (see stress_test.py's edge-policy job).
//!
//! The counters are exposed in GET /version (home.zig), so the watchdog — which
//! already polls /version every minute — surfaces a climbing reject counter in
//! watchdog-status.txt for free: "someone is probing us" becomes an ssh-readable
//! signal. Counters are in-memory and reset on restart; they're a probe signal,
//! not accounting.
//!
//! This module has NO dependencies but std (it's compiled into every harness),
//! and it is the single home for the reject responses that used to be ad-hoc
//! strings smeared across the handlers.

const std = @import("std");
const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// RejectKind is the closed set of edge-bound rejections. Each maps to a fixed
/// HTTP status (statusFor). Add a kind here and it appears in /version's
/// `rejects` object automatically (countsJSON iterates the enum).
pub const RejectKind = enum {
    header_too_large, // request head exceeded the 16 KB read buffer
    body_too_large, // request body (or an uploaded image) exceeded its cap
    body_unreadable, // body framing was malformed / unreadable
    malformed_markdown, // hostile / absurdly over-formatted markdown
    malformed_multipart, // a multipart upload we couldn't parse a file out of
};

const N = @typeInfo(RejectKind).@"enum".fields.len;

/// counters[kind] — process-lifetime, lock-free. .monotonic is enough: we never
/// order these against other memory, we just want an eventually-correct tally.
var counters = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** N;

fn bump(kind: RejectKind) void {
    _ = counters[@intFromEnum(kind)].fetchAdd(1, .monotonic);
}

/// get returns the current count for a kind (for tests / introspection).
pub fn get(kind: RejectKind) u64 {
    return counters[@intFromEnum(kind)].load(.monotonic);
}

/// statusFor maps a reject kind to its canonical HTTP status. Category, not
/// message: every body-size reject is a 413, every malformed-input reject a 400.
pub fn statusFor(kind: RejectKind) std.http.Status {
    return switch (kind) {
        .header_too_large => .request_header_fields_too_large, // 431
        .body_too_large => .payload_too_large, // 413
        .body_unreadable, .malformed_markdown, .malformed_multipart => .bad_request, // 400
    };
}

/// reject counts the rejection and sends the canonical status with `msg` (the
/// caller's context-specific, user-facing text). The single chokepoint every
/// edge-bound rejection flows through.
pub fn reject(req: *Request, kind: RejectKind, msg: []const u8) !void {
    bump(kind);
    try req.respond(msg, .{ .status = statusFor(kind) });
}

/// count records a rejection WITHOUT sending a response — for paths that already
/// have their own observable side effect (e.g. the markdown preview endpoint,
/// which still returns the visible malformed_html placeholder) or where the
/// connection is being closed raw (the oversize-header path in server.zig).
pub fn count(kind: RejectKind) void {
    bump(kind);
}

/// countsJSON renders the counters as a JSON object keyed by kind name, e.g.
/// {"header_too_large":0,"body_too_large":3,...}. Embedded in /version.
pub fn countsJSON(alloc: Alloc) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.append(alloc, '{');
    inline for (@typeInfo(RejectKind).@"enum".fields, 0..) |f, i| {
        if (i != 0) try b.append(alloc, ',');
        try b.print(alloc, "\"{s}\":{d}", .{ f.name, counters[i].load(.monotonic) });
    }
    try b.append(alloc, '}');
    return b.toOwnedSlice(alloc);
}
