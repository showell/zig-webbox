//! http: tiny shared helpers over std.http.Server — content-type headers and
//! the common responses. Keeps the per-feature handlers terse.

const std = @import("std");

pub const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
pub const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };
pub const json_ct = std.http.Header{ .name = "content-type", .value = "application/json; charset=utf-8" };
pub const plain_ct = std.http.Header{ .name = "content-type", .value = "text/plain; charset=utf-8" };

pub fn notFound(req: *std.http.Server.Request) !void {
    try req.respond("not found\n", .{ .status = .not_found });
}

/// methodNotAllowed mirrors Go's http.Error(w, "method not allowed", 405) — the
/// trailing newline matches http.Error's behavior.
pub fn methodNotAllowed(req: *std.http.Server.Request) !void {
    try req.respond("method not allowed\n", .{ .status = .method_not_allowed });
}

/// readLimitedBody reads the request body capped at `max` bytes, mirroring Go's
/// lynrummy.readLimitedBody. On success returns the body (alloc-owned). On
/// overflow it responds 413 and returns null; on any other read error it responds
/// 400 and returns null — so callers just `return` when the result is null.
///
/// `max + 1`: allocRemaining errors when the limit is *reached* (≥), but Go's
/// MaxBytesReader allows exactly `max` and rejects only `max + 1`.
pub fn readLimitedBody(req: *std.http.Server.Request, alloc: std.mem.Allocator, max: usize) !?[]u8 {
    var buf: [4 * 1024]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    return reader.allocRemaining(alloc, .limited(max + 1)) catch |e| switch (e) {
        error.StreamTooLong => {
            try req.respond("request body too large\n", .{ .status = .payload_too_large });
            return null;
        },
        else => {
            try req.respond("read body\n", .{ .status = .bad_request });
            return null;
        },
    };
}

/// redirect sends a 303 See Other to `location` (Go's http.StatusSeeOther).
pub fn redirect(req: *std.http.Server.Request, location: []const u8) !void {
    try req.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}
