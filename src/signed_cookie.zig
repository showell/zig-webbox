//! signed_cookie: a cookie whose value is signed (signed.zig) with the site's
//! secret (secret.zig). Part of the `webbox` library.
//!
//! What any such cookie needs: its value read back as the id it names, under
//! the current secret or, after a change, the previous one while it is still
//! taken; the Set-Cookie header for a value; and when one is due to be signed
//! again. When to issue one, and anything an application remembers about who
//! was issued one, is the application's.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const signed = @import("signed.zig");
const secret = @import("secret.zig");

pub const Cookie = struct {
    /// The cookie's name.
    name: []const u8,
    /// Its signing rules; `kind.lifetime_secs` is also its Max-Age.
    kind: signed.Kind,
};

/// The Set-Cookie header value for a signed `value`.
pub fn header(c: Cookie, alloc: Alloc, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ c.name, value, c.kind.lifetime_secs });
}

/// A value read back: the id it names, when it was signed, and with which
/// secret.
pub const Read = struct {
    id: []const u8,
    issued: i64,
    by: enum { current, previous },
};

/// The id this request's cookie names, signed with the secret in
/// `secret_dir` or, after a change of secret, with the previous one while it
/// is still taken; null when it names no one (no cookie, no secret, a value
/// that does not verify).
pub fn read(c: Cookie, io: Io, alloc: Alloc, req: *std.http.Server.Request, secret_dir: []const u8, now: i64) !?Read {
    const value = (try http.cookie(req, alloc, c.name)) orelse return null;
    const current = (try secret.load(io, alloc, secret_dir)) orelse return null;
    if (signed.verify(c.kind, current, value, now)) |id| return .{ .id = id, .issued = signed.issuedOf(value), .by = .current };
    if (try secret.previous(io, alloc, secret_dir)) |prev| if (signed.verify(c.kind, prev, value, now)) |id| {
        return .{ .id = id, .issued = signed.issuedOf(value), .by = .previous };
    };
    return null;
}

/// **DUE TO BE SIGNED AGAIN**: signed with the previous secret, or past half
/// its life. Nothing else re-signs a valid cookie, so without this one active
/// all its life is lost at its end.
pub fn due(c: Cookie, r: Read, now: i64) bool {
    return r.by == .previous or now -| r.issued > @divTrunc(c.kind.lifetime_secs, 2);
}

test "signed_cookie: the header carries the name, the value and the lifetime; due past half its life, or under the previous secret" {
    const any = struct {
        fn id(_: []const u8) bool {
            return true;
        }
    };
    const c: Cookie = .{ .name = "device", .kind = .{ .label = "device\n", .lifetime_secs = 100, .skew_secs = 5, .validId = any.id } };
    const h = try header(c, std.testing.allocator, "7.1000.mac");
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("device=7.1000.mac; Path=/; Max-Age=100; HttpOnly; SameSite=Lax", h);
    try std.testing.expect(!due(c, .{ .id = "7", .issued = 1000, .by = .current }, 1050));
    try std.testing.expect(due(c, .{ .id = "7", .issued = 1000, .by = .current }, 1051));
    try std.testing.expect(due(c, .{ .id = "7", .issued = 1000, .by = .previous }, 1000));
}
