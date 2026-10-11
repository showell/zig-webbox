//! site_secret: the site's signing secret, kept as files in a folder (the
//! application's secrets folder, `auth/`). Part of the `webbox` library.
//!
//!   _session_secret                 the secret: at least 32 bytes
//!   _session_secret.previous        the one before the last change
//!   _session_secret.previous-until  until when (Unix seconds) the previous
//!                                   one is still taken
//!
//! Each call names the folder; nothing here is kept between calls. Nothing
//! makes a first secret: an application seeds one, and only `rotate`
//! replaces one that exists.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const store = @import("store.zig");

const current_name = "_session_secret";
const previous_name = "_session_secret.previous";
const previous_until_name = "_session_secret.previous-until";

/// The secret in `dir` (at least 32 bytes), or null when there is none.
pub fn load(io: Io, alloc: Alloc, dir: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(alloc, &.{ dir, current_name });
    const b = (try store.readOrNull(io, alloc, path, .unlimited)) orelse return null;
    if (b.len < 32) return null;
    return b;
}

/// The secret before the last change, while values signed with it are still
/// taken at `now` (Unix seconds; `previous-until`); null past that, or when
/// there is none.
pub fn previous(io: Io, alloc: Alloc, dir: []const u8, now: i64) !?[]const u8 {
    const until_path = try std.fs.path.join(alloc, &.{ dir, previous_until_name });
    const raw = (try store.readOrNull(io, alloc, until_path, .limited(64))) orelse return null;
    const until = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return null;
    if (now >= until) return null;
    const path = try std.fs.path.join(alloc, &.{ dir, previous_name });
    const b = (try store.readOrNull(io, alloc, path, .unlimited)) orelse return null;
    if (b.len < 32) return null;
    return b;
}

/// **CHANGES THE SECRET.** The current one becomes the previous one, still
/// taken for `previous_days` more days (0: not at all), and a new one, 32
/// random bytes as 64 hex digits, takes its place. Written previous first and
/// the new secret last, so a stop part-way leaves the old secret in force.
pub fn rotate(io: Io, alloc: Alloc, dir: []const u8, previous_days: i64) !void {
    const current = (try load(io, alloc, dir)) orelse return error.NoSecret;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    try store.replace(io, alloc, try std.fs.path.join(alloc, &.{ dir, previous_name }), current, .{ .private = true });
    try store.replace(io, alloc, try std.fs.path.join(alloc, &.{ dir, previous_until_name }), try std.fmt.allocPrint(alloc, "{d}\n", .{now + previous_days * 24 * 60 * 60}), .{});
    var b: [32]u8 = undefined;
    io.random(b[0..]);
    const hex = std.fmt.bytesToHex(b, .lower);
    try store.replace(io, alloc, try std.fs.path.join(alloc, &.{ dir, current_name }), &hex, .{ .private = true });
}
