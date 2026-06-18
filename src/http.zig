//! http: tiny shared helpers over std.http.Server — content-type headers and
//! the common responses. Keeps the per-feature handlers terse.

const std = @import("std");

pub const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
pub const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };

pub fn notFound(req: *std.http.Server.Request) !void {
    try req.respond("not found\n", .{ .status = .not_found });
}

/// redirect sends a 303 See Other to `location` (Go's http.StatusSeeOther).
pub fn redirect(req: *std.http.Server.Request, location: []const u8) !void {
    try req.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}
