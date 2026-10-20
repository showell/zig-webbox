//! edge: the one policy for incoming data at the server's edges. Part of the
//! `webbox` library.
//!
//! THREAT MODEL (read this first). It assumes a build with zig's runtime safety
//! on (Debug, whose checks are a superset of ReleaseSafe's, or ReleaseSafe), so
//! the bounds and integer-overflow checks are ON: a classic C-style overflow
//! — write past a buffer, corrupt adjacent memory, keep running — cannot
//! happen. An out-of-bounds index or copy PANICS (a clean crash, which the
//! host restarts). So the realistic "overflow" attack is a panic-as-DoS: feed
//! input that drives an edge past a fixed buffer and kill the worker. The
//! defence is to BOUND every edge so oversized/malformed input is rejected
//! gracefully — reaching neither the panic nor a silent truncation.
//!
//! POLICY (four rules):
//!   1. Every edge has an explicit, named byte/count bound (no inline magic).
//!   2. Exceeding a bound is REJECTED — never truncated, never panicked into.
//!      The status is fixed by category (statusFor): 431 header, 413 body size,
//!      400 malformed. The human message stays caller-specific (it's UX).
//!   3. Every rejection is OBSERVABLE: a process-wide atomic counter per kind.
//!   4. An application's tests assert the counter moved.
//!
//! An application shows the counters where an operator or a monitor looks
//! (`countsJSON` for a machine, `countsText` for a person), so a climbing
//! count says "someone is probing us". Counters are in-memory and reset on
//! restart; they're a probe signal, not accounting.
//!
//! This module has NO dependencies but std (so any harness can compile it in),
//! and it is the single home for reject responses: no handler spells its own
//! status for an edge-bound rejection.

const std = @import("std");
const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// RejectKind is the closed set of edge-bound rejections. Each maps to a fixed
/// HTTP status (statusFor). Add a kind here and it appears in countsJSON and
/// countsText automatically (both iterate the enum).
pub const RejectKind = enum {
    header_too_large, // request head exceeded the host's read buffer
    head_malformed, // a request head that is not HTTP (metal-vmm QUEUE 172)
    head_too_slow, // a request head not whole within the host's deadline (metal-vmm QUEUE 184)
    body_too_large, // request body (or an uploaded image) exceeded its cap
    body_unreadable, // body framing was malformed / unreadable
    body_too_slow, // a body not whole within the host's deadline (body.zig)
    body_framed_twice, // both Content-Length and Transfer-Encoding (RFC 9112 §6.1)
    no_deadline, // the host could not arm a body's deadline, so did not read it
    uploads_busy, // every upload slot held (or the uploader's own) past the wait (body.zig)
    body_length_required, // an upload without a Content-Length (body.zig)
    body_expectation_failed, // an Expect other than 100-continue (body.zig)
    upload_replaced, // an upload its human's newer one took the place of (body.zig)
    malformed_markdown, // hostile / absurdly over-formatted markdown
    malformed_multipart, // a multipart upload we couldn't parse a file out of
};

const N = @typeInfo(RejectKind).@"enum".field_names.len;

/// counters[kind] — process-lifetime, lock-free. .monotonic is enough: we never
/// order these against other memory, we just want an eventually-correct tally.
var counters: [N]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

fn bump(kind: RejectKind) void {
    _ = counters[@backingInt(kind)].fetchAdd(1, .monotonic);
}

/// statusFor maps a reject kind to its canonical HTTP status. Category, not
/// message: every body-size reject is a 413, every malformed-input reject a 400.
pub fn statusFor(kind: RejectKind) std.http.Status {
    return switch (kind) {
        .header_too_large => .request_header_fields_too_large, // 431
        .body_too_large => .payload_too_large, // 413
        .body_too_slow, .head_too_slow => .request_timeout, // 408
        .head_malformed, .body_unreadable, .body_framed_twice, .malformed_markdown, .malformed_multipart => .bad_request, // 400
        .no_deadline, .uploads_busy => .service_unavailable, // 503
        .body_length_required => .length_required, // 411
        .body_expectation_failed => .expectation_failed, // 417
        .upload_replaced => .conflict, // 409
    };
}

/// reject counts the rejection and sends the canonical status with `msg` (the
/// caller's context-specific, user-facing text). The single chokepoint every
/// edge-bound rejection flows through.
pub fn reject(req: *Request, kind: RejectKind, msg: []const u8) !void {
    bump(kind);
    // Refused: never told to send its body first (http.declineExpectation).
    req.head.expect = null;
    try req.respond(msg, .{ .status = statusFor(kind) });
}

/// count records a rejection WITHOUT sending a response — for paths that already
/// have their own observable side effect (e.g. an endpoint that still answers,
/// with a visible placeholder) or where the connection is being closed raw (a
/// host refusing an oversized head before any route sees it).
/// How many of `kind` have been counted.
pub fn countOf(kind: RejectKind) u64 {
    return counters[@backingInt(kind)].load(.monotonic);
}

pub fn count(kind: RejectKind) void {
    bump(kind);
}

/// countsText renders the counters that are not zero, for a person:
/// `body_too_large 3, header_too_large 1`, or `none`.
pub fn countsText(alloc: Alloc) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    inline for (@typeInfo(RejectKind).@"enum".field_names, 0..) |name, i| {
        const n = counters[i].load(.monotonic);
        if (n != 0) {
            if (b.items.len != 0) try b.appendSlice(alloc, ", ");
            try b.print(alloc, "{s} {d}", .{ name, n });
        }
    }
    if (b.items.len == 0) try b.appendSlice(alloc, "none");
    return b.toOwnedSlice(alloc);
}

/// countsJSON renders the counters as a JSON object keyed by kind name, e.g.
/// {"header_too_large":0,"body_too_large":3,...}.
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
