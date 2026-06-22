//! http: tiny shared helpers over std.http.Server — content-type headers and
//! the common responses. Keeps the per-feature handlers terse.

const std = @import("std");
const Io = std.Io;
const edge = @import("edge.zig");

pub const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
pub const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };
pub const json_ct = std.http.Header{ .name = "content-type", .value = "application/json; charset=utf-8" };
pub const plain_ct = std.http.Header{ .name = "content-type", .value = "text/plain; charset=utf-8" };

/// header returns the value of the first request header whose name
/// case-insensitively matches `name`, or null.
pub fn header(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// queryValue pulls one (un-decoded) query parameter from a raw request target
/// (`/path?a=1&b=2`), or null when absent.
pub fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn notFound(req: *std.http.Server.Request) !void {
    try req.respond("not found\n", .{ .status = .not_found });
}

pub fn methodNotAllowed(req: *std.http.Server.Request) !void {
    try req.respond("method not allowed\n", .{ .status = .method_not_allowed });
}

/// readLimitedBody reads the request body capped at `max` bytes. On success
/// returns the body (alloc-owned). On overflow it responds 413 and returns null;
/// on any other read error it responds 400 and returns null — so callers just
/// `return` when the result is null.
///
/// `max + 1`: allocRemaining errors when the limit is *reached* (≥), so to allow
/// a body of exactly `max` and reject only `max + 1` we pass `max + 1`.
///
/// No-framing guard: a request with NO Content-Length and NO chunked transfer
/// encoding has no body (RFC 9110). zig's bodyReader would otherwise frame that
/// as `.body_none` = the raw connection reader, so allocRemaining reads until the
/// socket closes — which, with keep-alive off and the client awaiting our
/// response, hangs forever. A browser form post always sends Content-Length (0
/// for an empty form), so this only bites a malformed/handcrafted client; we
/// treat it as the empty body it spec'ly is rather than hang. (Steve, 2026-06-19.)
pub fn readLimitedBody(req: *std.http.Server.Request, alloc: std.mem.Allocator, max: usize) !?[]u8 {
    if (req.head.content_length == null and req.head.transfer_encoding == .none) {
        return try alloc.alloc(u8, 0);
    }
    var buf: [4 * 1024]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    return reader.allocRemaining(alloc, .limited(max + 1)) catch |e| switch (e) {
        error.StreamTooLong => {
            try edge.reject(req, .body_too_large, "request body too large\n");
            return null;
        },
        else => {
            try edge.reject(req, .body_unreadable, "read body\n");
            return null;
        },
    };
}

/// redirect sends a 303 See Other to `location`.
pub fn redirect(req: *std.http.Server.Request, location: []const u8) !void {
    try req.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

// ── Server-Sent Events ───────────────────────────────────────────────────────

/// sse_headers are the response headers for an event-stream: the content type,
/// no-cache, and x-accel-buffering off (defeats reverse-proxy buffering so
/// frames arrive live).
pub const sse_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

/// pushFrame sends one SSE frame live over a chunked BodyWriter. Two flushes are
/// required and the order matters: body.writer.flush() drains the BodyWriter's
/// own buffer into the protocol output (emitting the HTTP chunk), then
/// body.flush() pushes that chunk out the socket. body.flush() ALONE is a no-op
/// while bytes still sit in the writer buffer — the subtle bit that makes SSE
/// actually stream. (Proven on the /spike surface; chat's streams reuse it.)
pub fn pushFrame(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.writer.flush();
    try body.flush();
}
