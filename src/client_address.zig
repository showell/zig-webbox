//! client_address: which address a request comes from. Part of the `webbox`
//! library.
//!
//! It is the connection's own address (the host's `Bus.peer`), unless that is
//! the reverse proxy in front (`trusted_proxy`), whose X-Forwarded-For then
//! names the client: the last entry, the one that proxy added. An entry that
//! is not plausibly an address is not believed, and the request counts as
//! the proxy's own.

const std = @import("std");
const Alloc = std.mem.Allocator;
const http = @import("http.zig");

/// The longest address as text (IPv6's).
pub const addr_max = 45;

/// The reverse proxy whose X-Forwarded-For is believed, as text, which the
/// host sets as it starts. Null: none is, and every request is its
/// connection's address.
pub var trusted_proxy: ?[]const u8 = null;

/// The address a request is from: `peer`, or the last X-Forwarded-For entry
/// when `peer` is the trusted proxy. Null when the host gave no peer. Owned by
/// `alloc`, so it outlives a body read.
pub fn resolve(alloc: Alloc, req: *std.http.Server.Request, peer: ?[]const u8) !?[]const u8 {
    const p = peer orelse return null;
    const proxy = trusted_proxy orelse return try alloc.dupe(u8, p);
    if (!std.mem.eql(u8, p, proxy)) return try alloc.dupe(u8, p);
    if (try http.header(req, alloc, "x-forwarded-for")) |xff| {
        var parts = std.mem.splitBackwardsScalar(u8, xff, ',');
        const last = std.mem.trim(u8, parts.first(), " \t");
        if (plausible(last)) return last;
    }
    return try alloc.dupe(u8, p); // the proxy, with nothing usable said: count it as itself
}

/// An IPv4 or IPv6 address's characters, at an address's length: enough to
/// keep a header from naming anything else.
fn plausible(s: []const u8) bool {
    if (s.len == 0 or s.len > addr_max) return false;
    for (s) |c| if (!(std.ascii.isHex(c) or c == '.' or c == ':')) return false;
    return true;
}

/// The setting as it stood, to put back (`defer saved.restore()`): for a test
/// that sets it.
pub const Saved = struct {
    trusted_proxy: ?[]const u8,
    pub fn restore(self: Saved) void {
        trusted_proxy = self.trusted_proxy;
    }
};

pub fn save() Saved {
    return .{ .trusted_proxy = trusted_proxy };
}

test "plausible: an address's characters at an address's length, and nothing else" {
    try std.testing.expect(plausible("203.0.113.7"));
    try std.testing.expect(plausible("2001:db8::1"));
    for ([_][]const u8{ "", "unknown", "1.2.3.4 ", &@as([46]u8, @splat('a')), "../x" }) |bad| try std.testing.expect(!plausible(bad));
}
