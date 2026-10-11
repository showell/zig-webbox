//! signed_cookie: a cookie whose value is signed (signed.zig) with the site's
//! secret (site_secret.zig). Part of the `webbox` library.
//!
//! What any such cookie needs: its value read back as the id it names, under
//! the current secret or, after a change, the previous one while it is still
//! taken; a new one issued; and one renewed when it is used, past half its
//! life or under the previous secret. When to issue one, and anything an application remembers about who
//! was issued one, is the application's.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const signed = @import("signed.zig");
const site_secret = @import("site_secret.zig");

pub const Cookie = struct {
    /// The cookie's name (`http.host_prefix` and a name, for any cookie set
    /// now).
    name: []const u8,
    /// The name it had before, read when a request has none of `name`; one
    /// read so is due to be signed again, under `name` (`needsRenewal`).
    legacy_name: ?[]const u8 = null,
    /// Its signing rules; `kind.lifetime_secs` is also its Max-Age.
    kind: signed.Kind,
};

/// The Set-Cookie header value for a signed `value`.
pub fn header(c: Cookie, alloc: Alloc, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}={s}; Path=/; Max-Age={d}; " ++ http.cookie_attributes, .{ c.name, value, c.kind.lifetime_secs });
}

/// A value that verified: the id it names, when it was signed, and with
/// which secret.
pub const Verified = struct {
    id: []const u8,
    issued: i64,
    by: enum { current, previous },
    /// Read under the cookie's legacy name.
    legacy: bool = false,
};

/// What a request's cookie says, each case named, so a caller decides on
/// each: there is no cookie; there is no secret to read it with (nothing is
/// issued either); it names no one (`Invalid` says how); or it verifies.
pub const Reading = union(enum) {
    none,
    no_secret,
    invalid: Invalid,
    verified: Verified,
};

/// **HOW A COOKIE NAMES NO ONE.** Of several of one name (a parent domain's
/// beside the site's own, metal-vmm QUEUE 162.4), the one that verifies is
/// read; none verifying, or more than one, names no one.
pub const Invalid = enum {
    /// None of the values verifies under either secret: a forgery, one past
    /// its life, another site's, or an application's older spelling.
    does_not_verify,
    /// More than one verifies: which is meant cannot be told.
    more_than_one_verifies,
};

/// Reads this request's cookie, signed with the secret in `secret_dir` or,
/// after a change of secret, with the previous one while it is still taken.
pub fn read(c: Cookie, io: Io, alloc: Alloc, req: *std.http.Server.Request, secret_dir: []const u8, now: i64) !Reading {
    var one: [1][]const u8 = undefined;
    const named: http.Named = if (c.legacy_name) |old|
        try http.cookieOrLegacy(req, alloc, c.name, old, now)
    else
        .{ .values = try http.cookie(req, alloc, c.name), .legacy = false };
    const values: []const []const u8 = switch (named.values) {
        .none => return .none,
        .one => |v| blk: {
            one[0] = v;
            break :blk &one;
        },
        .several => |vs| vs,
    };
    const current = (try site_secret.load(io, alloc, secret_dir)) orelse return .no_secret;
    const prev = try site_secret.previous(io, alloc, secret_dir, now);
    var found: Found = .nothing_yet;
    for (values) |value| switch (verifyEither(c, current, prev, value, now)) {
        .no => {},
        // A legacy-named value signed after the move is a plant: not read.
        .yes => |v| if (named.legacy and v.issued >= http.legacy_issued_before_unix) {} else switch (found) {
            .nothing_yet => found = .{ .one = v },
            .one => return .{ .invalid = .more_than_one_verifies },
        },
    };
    return switch (found) {
        .nothing_yet => .{ .invalid = .does_not_verify },
        .one => |v| blk: {
            var under = v;
            under.legacy = named.legacy;
            break :blk .{ .verified = under };
        },
    };
}

const Found = union(enum) { nothing_yet, one: Verified };

/// One value, under the current secret or else the previous one.
fn verifyEither(c: Cookie, current: []const u8, prev: ?[]const u8, value: []const u8, now: i64) union(enum) { no, yes: Verified } {
    if (signed.verify(c.kind, current, value, now)) |id| return .{ .yes = .{ .id = id, .issued = signed.issuedOf(value), .by = .current } };
    if (prev) |p| if (signed.verify(c.kind, p, value, now)) |id| return .{ .yes = .{ .id = id, .issued = signed.issuedOf(value), .by = .previous } };
    return .no;
}

/// **DUE TO BE SIGNED AGAIN**: signed with the previous secret, or past half
/// its life. Nothing else re-signs a valid cookie, so without this one active
/// all its life is lost at its end.
pub fn needsRenewal(c: Cookie, v: Verified, now: i64) bool {
    return v.legacy or v.by == .previous or now -| v.issued > @divTrunc(c.kind.lifetime_secs, 2);
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
    try std.testing.expectEqualStrings("device=7.1000.mac; Path=/; Max-Age=100; HttpOnly; Secure; SameSite=Lax", h);
    try std.testing.expect(!needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .current }, 1050));
    try std.testing.expect(needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .current }, 1051));
    try std.testing.expect(needsRenewal(c, .{ .id = "7", .issued = 1000, .by = .previous }, 1000));
}

/// A request whose head carries `cookie_header` (several Cookie headers when
/// it holds a "\n"), read as `c` with a secret in a fresh folder.
const Rig = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: std.testing.TmpDir,
    dir: []const u8,

    fn init(self: *Rig) !void {
        self.arena = .init(std.testing.allocator);
        self.threaded = .init(self.arena.allocator(), .{});
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        try site_secret.create(self.threaded.io(), self.arena.allocator(), self.dir);
    }
    fn deinit(self: *Rig) void {
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena.deinit();
    }
    fn signedFor(self: *Rig, c: Cookie, id: []const u8, now: i64) ![]const u8 {
        const a = self.arena.allocator();
        const secret = (try site_secret.load(self.threaded.io(), a, self.dir)).?;
        return signed.sign(a, c.kind, secret, id, now);
    }
    fn reading(self: *Rig, c: Cookie, cookie_lines: []const []const u8, now: i64) !Reading {
        const a = self.arena.allocator();
        var head: std.ArrayList(u8) = .empty;
        try head.appendSlice(a, "GET / HTTP/1.1\r\nHost: x\r\n");
        for (cookie_lines) |line| try head.print(a, "Cookie: {s}\r\n", .{line});
        try head.appendSlice(a, "\r\n");
        var reader: std.Io.Reader = .fixed(head.items);
        var out: std.Io.Writer.Allocating = .init(a);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        return read(c, self.threaded.io(), a, &req, self.dir, now);
    }
};

fn digits(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

test "signed_cookie: two that verify, or none, name no one, and say which" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c: Cookie = .{ .name = "device", .kind = .{ .label = "device\n", .lifetime_secs = 1000, .skew_secs = 5, .validId = digits } };
    const a = rig.arena.allocator();
    const seven = try rig.signedFor(c, "7", 5000);
    const eight = try rig.signedFor(c, "8", 5000);
    try std.testing.expectEqual(Reading{ .invalid = .more_than_one_verifies }, try rig.reading(c, &.{try std.fmt.allocPrint(a, "device={s}; device={s}", .{ seven, eight })}, 5000));
    try std.testing.expectEqual(Reading{ .invalid = .does_not_verify }, try rig.reading(c, &.{"device=junk; device=other"}, 5000));
    try std.testing.expectEqual(Reading{ .invalid = .does_not_verify }, try rig.reading(c, &.{"device=junk"}, 5000));
    try std.testing.expectEqual(Reading.none, try rig.reading(c, &.{"other=1"}, 5000));
    try std.testing.expectEqualStrings("7", (try rig.reading(c, &.{try std.fmt.allocPrint(a, "device={s}", .{seven})}, 5000)).verified.id);
}

test "signed_cookie: of two cookies of one name, the one that verifies is read, wherever it is (metal-vmm QUEUE 162.4)" {
    // A cookie set for the parent domain arrives beside the subdomain's own,
    // and the first of them was read: a stale or foreign one ahead of the
    // site's own made its visitor no one.
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c: Cookie = .{ .name = "device", .kind = .{ .label = "device\n", .lifetime_secs = 1000, .skew_secs = 5, .validId = digits } };
    const good = try rig.signedFor(c, "7", 5000);
    const a = rig.arena.allocator();
    for ([_][]const []const u8{
        &.{try std.fmt.allocPrint(a, "device=junk; device={s}", .{good})},
        &.{try std.fmt.allocPrint(a, "device={s}; device=junk", .{good})},
        &.{ "device=junk", try std.fmt.allocPrint(a, "other=1; device={s}", .{good}) },
    }) |lines| {
        try std.testing.expectEqualStrings("7", (try rig.reading(c, lines, 5000)).verified.id);
    }
}

test "signed_cookie: the legacy name is read only when the new one is absent, and is due to move (metal-vmm QUEUE 167.5)" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c: Cookie = .{ .name = "__Host-device", .legacy_name = "device", .kind = .{ .label = "device\n", .lifetime_secs = 1000, .skew_secs = 5, .validId = digits } };
    const a = rig.arena.allocator();
    const seven = try rig.signedFor(c, "7", 5000);
    const eight = try rig.signedFor(c, "8", 5000);
    // Only the old name: read, and due to be signed again under the new.
    const old = (try rig.reading(c, &.{try std.fmt.allocPrint(a, "device={s}", .{seven})}, 5000)).verified;
    try std.testing.expectEqualStrings("7", old.id);
    try std.testing.expect(old.legacy and needsRenewal(c, old, 5000));
    // The new name: read, the old one beside it ignored, however valid (a
    // sibling's plant under the old name names no one else).
    const now = (try rig.reading(c, &.{try std.fmt.allocPrint(a, "device={s}; __Host-device={s}", .{ eight, seven })}, 5000)).verified;
    try std.testing.expectEqualStrings("7", now.id);
    try std.testing.expect(!now.legacy and !needsRenewal(c, now, 5000));
    // Issued under the new name.
    try std.testing.expect(std.mem.startsWith(u8, try header(c, a, seven), "__Host-device="));
}
