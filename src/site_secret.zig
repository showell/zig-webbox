//! site_secret: the site's signing secret, kept as files in a folder (the
//! application's secrets folder, `auth/`). Part of the `webbox` library.
//!
//!   _session_secret                 the secret: at least 32 bytes
//!   _session_secret.previous        the one before the last change
//!   _session_secret.previous-until  until when (Unix seconds) the previous
//!                                   one is still taken
//!
//! Each call names the folder; nothing here is kept between calls. `create`
//! makes the first secret, once, when a site is set up (angry-gopher's was
//! seeded on disk by hand, before `create`); only `rotate` replaces one.

const std = @import("std");
const Io = @import("host_io").Io;
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
    const hex = fresh(io);
    try store.replace(io, alloc, try std.fs.path.join(alloc, &.{ dir, current_name }), &hex, .{ .private = true });
}

/// **THE FIRST SECRET**, made once, when a site is set up. Refused
/// (`error.SecretExists`) when the folder has one already, whatever it holds:
/// only `rotate` replaces a secret. **ONE, HOWEVER MANY START AT ONCE**
/// (metal-vmm QUEUE 162.3): made whole beside the name and renamed onto it
/// without replacing (store.createNew), so of two processes setting up
/// together one makes the secret and the other is refused, where a check
/// and then a write let both write and the last one's win.
pub fn create(io: Io, alloc: Alloc, dir: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ dir, current_name });
    const hex = fresh(io);
    store.createNew(io, alloc, path, &hex, .{ .private = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return error.SecretExists,
        else => return e,
    };
}

/// 32 random bytes as 64 hex digits.
fn fresh(io: Io) [64]u8 {
    var b: [32]u8 = undefined;
    io.random(b[0..]);
    return std.fmt.bytesToHex(b, .lower);
}

test "create makes the first secret once, and refuses a second; rotate then replaces it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    try std.testing.expect((try load(io, a, dir)) == null);
    try create(io, a, dir);
    const first = (try load(io, a, dir)).?;
    try std.testing.expectEqual(@as(usize, 64), first.len);
    try std.testing.expectError(error.SecretExists, create(io, a, dir));
    try std.testing.expectEqualStrings(first, (try load(io, a, dir)).?);

    try rotate(io, a, dir, 1);
    const second = (try load(io, a, dir)).?;
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    try std.testing.expectEqualStrings(first, (try previous(io, a, dir, now)).?);
}

test "two processes setting up at once make one secret: every other is told SecretExists (metal-vmm QUEUE 162.3)" {
    // A check and then a write: two that both checked before either wrote
    // both wrote, and the last one's secret silently replaced the first's.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..20) |round| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/round{d}", .{ &tmp.sub_path, round });
        const Racer = struct {
            made: std.atomic.Value(u32) = .init(0),
            refused: std.atomic.Value(u32) = .init(0),
            go: std.atomic.Value(bool) = .init(false),
            fn run(self: *@This(), racer_io: Io, d: []const u8) void {
                var own = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer own.deinit();
                while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
                if (create(racer_io, own.allocator(), d)) {
                    _ = self.made.fetchAdd(1, .monotonic);
                } else |e| if (e == error.SecretExists) {
                    _ = self.refused.fetchAdd(1, .monotonic);
                }
            }
        };
        var racer: Racer = .{};
        var threads: [8]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Racer.run, .{ &racer, io, dir });
        racer.go.store(true, .release);
        for (threads) |t| t.join();
        try std.testing.expectEqual(@as(u32, 1), racer.made.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 7), racer.refused.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 64), (try load(io, a, dir)).?.len);
    }
}

test "the previous secret is taken until the second before previous-until, not at it; a secret of 32 bytes loads, 31 does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    const prev = "q" ** 32;
    try store.write(io, a, try std.fs.path.join(a, &.{ dir, previous_name }), prev, .{});
    try store.write(io, a, try std.fs.path.join(a, &.{ dir, previous_until_name }), "5000\n", .{});
    try std.testing.expectEqualStrings(prev, (try previous(io, a, dir, 4999)).?);
    try std.testing.expect((try previous(io, a, dir, 5000)) == null);

    const cur = try std.fs.path.join(a, &.{ dir, current_name });
    try store.write(io, a, cur, "s" ** 32, .{});
    try std.testing.expectEqual(@as(usize, 32), (try load(io, a, dir)).?.len);
    try store.replace(io, a, cur, "s" ** 31, .{});
    try std.testing.expect((try load(io, a, dir)) == null);
}
