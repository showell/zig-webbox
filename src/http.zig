//! http: tiny shared helpers over std.http.Server — content-type headers and
//! the common responses. Keeps the per-feature handlers terse.

const std = @import("std");
const Io = std.Io;
const edge = @import("edge.zig");

pub const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
pub const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };
pub const json_ct = std.http.Header{ .name = "content-type", .value = "application/json; charset=utf-8" };
pub const plain_ct = std.http.Header{ .name = "content-type", .value = "text/plain; charset=utf-8" };
pub const pdf_ct = std.http.Header{ .name = "content-type", .value = "application/pdf" };
pub const png_ct = std.http.Header{ .name = "content-type", .value = "image/png" };
pub const svg_ct = std.http.Header{ .name = "content-type", .value = "image/svg+xml" };
pub const wasm_ct = std.http.Header{ .name = "content-type", .value = "application/wasm" };

// ── request-head accessors (the OWNING chokepoint) ───────────────────────────
//
// Reading the request BODY invalidates the std.http head strings (the zig-0.16
// `received_head` gotcha): any borrowed slice of a header value or the target
// silently becomes garbage afterward, which once mis-attributed an authenticated
// post to the wrong principal. So every accessor here returns memory OWNED by the
// caller's allocator — a head value you hold can never dangle. This module is the
// ONLY place allowed to touch `req.head.target` / `req.iterateHeaders()` directly;
// tools/lint_head_access.py enforces that, which is what makes the foot-gun
// impossible to reintroduce rather than merely fixed once.

/// header returns the value of the first request header whose name
/// case-insensitively matches `name`, OWNED (duped into `alloc`), or null.
pub fn header(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return try alloc.dupe(u8, h.value);
    }
    return null;
}

/// target returns the request target (`/path?query`), OWNED. Routing keeps
/// slices of it alive past body reads, so it must not borrow from the head.
pub fn target(req: *std.http.Server.Request, alloc: std.mem.Allocator) ![]const u8 {
    return alloc.dupe(u8, req.head.target);
}

/// cookie returns the value of cookie `name` from any Cookie header, OWNED, or null.
pub fn cookie(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        if (parseCookieValue(h.value, name)) |v| return try alloc.dupe(u8, v);
    }
    return null;
}

/// parseCookieValue extracts cookie `name` from one Cookie header value
/// (`a=1; b=2`), or null. PURE — returns a slice INTO `header_value`; the owning
/// is `cookie`'s job. Split out so the parse is unit-testable without a Request.
pub fn parseCookieValue(header_value: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, header_value, ';');
    while (pairs.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// queryValue pulls one (un-decoded) query parameter from a request target
/// (`/path?a=1&b=2`), or null when absent. PURE — a slice into `target`; pass an
/// OWNED target (from `target`) when the result outlives a body read.
pub fn queryValue(target_str: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target_str, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target_str[q + 1 ..], '&');
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
/// actually stream. (Every chat SSE stream pushes its frames through here.)
pub fn pushFrame(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.writer.flush();
    try body.flush();
}

const testing = std.testing;

test "parseCookieValue: picks the named cookie, trims spaces, ignores the rest" {
    try testing.expectEqualStrings("xyz", parseCookieValue("a=1; gopher_auth=xyz; b=2", "gopher_auth").?);
    try testing.expectEqualStrings("1", parseCookieValue("a=1", "a").?);
    try testing.expectEqualStrings("3", parseCookieValue("gopher_uid=3", "gopher_uid").?);
    try testing.expect(parseCookieValue("a=1; b=2", "c") == null);
    try testing.expect(parseCookieValue("", "a") == null);
    try testing.expect(parseCookieValue("noequalssign", "a") == null);
}

// The regression test for the bug this whole module exists to prevent: a value
// read from the request head, used after the body read that clobbers the head
// buffer. parseCookieValue returns a slice INTO the source (what the accessor
// borrows before duping); we prove the dupe — and only the dupe — survives the
// source being overwritten, exactly as a chunked body read overwrites the head.
test "head value must be owned: a clobbered source buffer corrupts the borrow, not the dupe" {
    var buf: [12]u8 = undefined;
    @memcpy(&buf, "sid=deadbee0"); // "sid=" + an 8-char value
    const borrowed = parseCookieValue(&buf, "sid").?;
    try testing.expectEqualStrings("deadbee0", borrowed);

    const owned = try testing.allocator.dupe(u8, borrowed); // what the accessor does
    defer testing.allocator.free(owned);

    @memset(&buf, 0xAA); // simulate the body read overwriting the head buffer
    try testing.expectEqualStrings("deadbee0", owned); // the owned copy is intact
    try testing.expect(!std.mem.eql(u8, borrowed, owned)); // the borrow is now garbage
}
