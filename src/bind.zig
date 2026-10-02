//! bind: the address the server listens on, from GOPHER_BIND.
//!
//! The default is every interface: prod's firewall keeps 9001 private, and
//! Caddy reaches it on localhost. With GOPHER_BIND=127.0.0.1 the server
//! answers on loopback only, which is how a rehearsal on real data is run
//! without anything outside the machine reaching it.
//!
//! **A BIND THAT WILL NOT PARSE IS AN ERROR, NOT THE DEFAULT.** Whoever set
//! it meant fewer interfaces than all, and falling back to every one would
//! open what they meant to close.

const std = @import("std");
const net = std.Io.net;

pub const default = "0.0.0.0";

/// The address to listen on: `raw` (GOPHER_BIND's value, or null when it is
/// unset) on `port`.
pub fn address(raw: ?[]const u8, port: u16) !net.IpAddress {
    const host = std.mem.trim(u8, raw orelse default, " \t\r\n");
    return net.IpAddress.parse(host, port) catch {
        std.debug.print("zig-server: GOPHER_BIND={s} is not an IP address; not starting\n", .{raw orelse ""});
        return error.BadBindAddress;
    };
}

test "unset is every interface, 127.0.0.1 is loopback only, and a bad one is refused" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.0.0.0:9001", try std.fmt.bufPrint(&buf, "{f}", .{try address(null, 9001)}));
    try std.testing.expectEqualStrings("127.0.0.1:9001", try std.fmt.bufPrint(&buf, "{f}", .{try address("127.0.0.1", 9001)}));
    try std.testing.expectEqualStrings("127.0.0.1:9001", try std.fmt.bufPrint(&buf, "{f}", .{try address(" 127.0.0.1\n", 9001)}));
    for ([_][]const u8{ "localhost", "127.0.0.1x", "", "256.0.0.1" }) |bad| {
        try std.testing.expectError(error.BadBindAddress, address(bad, 9001));
    }
}

test "bound to 127.0.0.1, the listener is on loopback and answers there" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr = try address("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var buf: [64]u8 = undefined;
    const bound = try std.fmt.bufPrint(&buf, "{f}", .{listener.socket.address});
    try std.testing.expect(std.mem.startsWith(u8, bound, "127.0.0.1:"));
    var conn = try listener.socket.address.connect(io, .{ .mode = .stream });
    conn.close(io);
}
