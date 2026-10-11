//! signed: a value that names an id, signed so that only the site could have
//! made it. Part of the `gopher` library (gopher.zig): it imports std only.
//!
//!     <id>.<issued>.<mac>     mac = base64url(HMAC-SHA256(secret, label id "\n" issued))
//!
//! A `Kind` is one cookie's rules: its label (so one kind's MAC never passes
//! as another's), how long a value names its id, how far ahead of the clock
//! an `issued` may be, and which ids it may carry (none holds a `.`, so the
//! value splits plainly).

const std = @import("std");
const Alloc = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const Kind = struct {
    /// Mixed into the MAC first; by convention the cookie's name and "\n".
    label: []const u8,
    /// From its signing, how long a value names its id.
    lifetime_secs: i64,
    /// How far ahead of the clock an `issued` may be: a clock a little behind
    /// the one that signed it. Past this the value names no one.
    skew_secs: i64,
    /// The ids this kind may carry. None may hold a `.`.
    validId: *const fn ([]const u8) bool,
};

fn mac(kind: Kind, secret: []const u8, id: []const u8, issued: []const u8, out: *[HmacSha256.mac_length]u8) void {
    var ctx = HmacSha256.init(secret);
    ctx.update(kind.label);
    ctx.update(id);
    ctx.update("\n");
    ctx.update(issued);
    ctx.final(out);
}

/// The signed value for `id`, issued at `issued_unix`.
pub fn sign(alloc: Alloc, kind: Kind, secret: []const u8, id: []const u8, issued_unix: i64) ![]const u8 {
    const issued = try std.fmt.allocPrint(alloc, "{d}", .{issued_unix});
    var m: [HmacSha256.mac_length]u8 = undefined;
    mac(kind, secret, id, issued, &m);
    var enc: [b64.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ id, issued, b64.Encoder.encode(&enc, &m) });
}

/// The id a signed value carries at `now_unix`, or null: one of another kind
/// or secret, one past its lifetime, or one issued further ahead than the
/// clock's skew, is no one.
pub fn verify(kind: Kind, secret: []const u8, value: []const u8, now_unix: i64) ?[]const u8 {
    var it = std.mem.splitScalar(u8, value, '.');
    const id = it.next() orelse return null;
    const issued = it.next() orelse return null;
    const m64 = it.next() orelse return null;
    if (it.next() != null or !kind.validId(id)) return null;
    const n = std.fmt.parseInt(i64, issued, 10) catch return null;
    if (now_unix -| n > kind.lifetime_secs or n -| now_unix > kind.skew_secs) return null;
    var want: [HmacSha256.mac_length]u8 = undefined;
    mac(kind, secret, id, issued, &want);
    var got: [HmacSha256.mac_length]u8 = undefined;
    b64.Decoder.decode(&got, m64) catch return null;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, want, got)) return null;
    return id;
}

/// The second a value `verify` has passed was signed.
pub fn issuedOf(value: []const u8) i64 {
    var it = std.mem.splitScalar(u8, value, '.');
    _ = it.next();
    return std.fmt.parseInt(i64, it.next() orelse return 0, 10) catch 0;
}

const testing = std.testing;

fn anyDigits(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| if (c < '0' or c > '9') return false;
    return true;
}

test "signed: a value names its id for its lifetime, under its own kind and secret only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "a secret of thirty-two bytes or more, for signed's test";
    const kind: Kind = .{ .label = "k\n", .lifetime_secs = 100, .skew_secs = 5, .validId = anyDigits };
    const v = try sign(a, kind, secret, "42", 1000);
    try testing.expectEqualStrings("42", verify(kind, secret, v, 1000).?);
    try testing.expectEqualStrings("42", verify(kind, secret, v, 1100).?);
    try testing.expect(verify(kind, secret, v, 1101) == null); // past its lifetime
    try testing.expect(verify(kind, secret, v, 994) == null); // issued too far ahead
    try testing.expect(verify(kind, "another secret entirely, as long as the first", v, 1000) == null);
    const other: Kind = .{ .label = "j\n", .lifetime_secs = 100, .skew_secs = 5, .validId = anyDigits };
    try testing.expect(verify(other, secret, v, 1000) == null); // another kind's
    try testing.expect(verify(kind, secret, try sign(a, kind, secret, "4x", 1000), 1000) == null); // not an id it carries
    try testing.expectEqual(@as(i64, 1000), issuedOf(v));
}
