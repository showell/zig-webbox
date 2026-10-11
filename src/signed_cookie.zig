//! signed_cookie: a cookie whose value is signed (signed.zig) with the site's
//! secret (site_secret.zig). Part of the `webbox` library.
//!
//! What any such cookie needs: its value read back as the id it names, under
//! the current secret or, after a change, the previous one while it is still
//! taken; a new one issued; and one renewed when it is used, past half its
//! life or under the previous secret. When to issue one, and anything an application remembers about who
//! was issued one, is the application's.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const signed = @import("signed.zig");
const site_secret = @import("site_secret.zig");

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

/// A value that verified: the id it names, when it was signed, and with
/// which secret.
pub const Verified = struct {
    id: []const u8,
    issued: i64,
    by: enum { current, previous },
};

/// What a request's cookie says, each case named, so a caller decides on
/// each: there is no cookie; there is no secret to read it with (nothing is
/// issued either); its value does not verify under either secret (a forgery,
/// one past its life, or an application's older spelling); or it does.
pub const Reading = union(enum) {
    none,
    no_secret,
    invalid,
    verified: Verified,
};

/// Reads this request's cookie, signed with the secret in `secret_dir` or,
/// after a change of secret, with the previous one while it is still taken.
pub fn read(c: Cookie, io: Io, alloc: Alloc, req: *std.http.Server.Request, secret_dir: []const u8, now: i64) !Reading {
    const value = (try http.cookie(req, alloc, c.name)) orelse return .none;
    const current = (try site_secret.load(io, alloc, secret_dir)) orelse return .no_secret;
    if (signed.verify(c.kind, current, value, now)) |id| return .{ .verified = .{ .id = id, .issued = signed.issuedOf(value), .by = .current } };
    if (try site_secret.previous(io, alloc, secret_dir, now)) |prev| if (signed.verify(c.kind, prev, value, now)) |id| {
        return .{ .verified = .{ .id = id, .issued = signed.issuedOf(value), .by = .previous } };
    };
    return .invalid;
}

/// **DUE TO BE SIGNED AGAIN**: signed with the previous secret, or past half
/// its life. Nothing else re-signs a valid cookie, so without this one active
/// all its life is lost at its end.
pub fn needsRenewal(c: Cookie, v: Verified, now: i64) bool {
    return v.by == .previous or now -| v.issued > @divTrunc(c.kind.lifetime_secs, 2);
}

/// The Set-Cookie header for `id`, signed now with the secret in
/// `secret_dir`; null when there is no secret (nothing unsigned is ever
/// issued).
pub fn issue(c: Cookie, io: Io, alloc: Alloc, secret_dir: []const u8, id: []const u8, now: i64) !?[]const u8 {
    const current = (try site_secret.load(io, alloc, secret_dir)) orelse return null;
    return try header(c, alloc, try signed.sign(alloc, c.kind, current, id, now));
}

/// **RENEWED WHEN USED**: the Set-Cookie header that signs this request's
/// cookie again, when it verifies and needs renewal; null otherwise.
pub fn renew(c: Cookie, io: Io, alloc: Alloc, req: *std.http.Server.Request, secret_dir: []const u8, now: i64) !?[]const u8 {
    const v = switch (try read(c, io, alloc, req, secret_dir, now)) {
        .verified => |v| v,
        .none, .no_secret, .invalid => return null,
    };
    if (!needsRenewal(c, v, now)) return null;
    return issue(c, io, alloc, secret_dir, v.id, now);
}

test "signed_cookie: the header carries the name, the value and the lifetime; it needs renewal past half its life, or under the previous secret" {
    const any = struct {
        fn id(_: []const u8) bool {
            return true;
        }
    };
    const c: Cookie = .{ .name = "device", .kind = .{ .label = "device\n", .lifetime_secs = 100, .skew_secs = 5, .validId = any.id } };
    const h = try header(c, std.testing.allocator, "7.1000.mac");
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("device=7.1000.mac; Path=/; Max-Age=100; HttpOnly; SameSite=Lax", h);
    try std.testing.expect(!needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .current }, 1050));
    try std.testing.expect(needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .current }, 1051));
    try std.testing.expect(needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .previous }, 1000));
}
