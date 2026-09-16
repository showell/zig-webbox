//! counter: a number in a file, bumped under a lock.
//!
//! Three unrelated things need one — the game store's session ids, the account
//! store's user ids, and the player store's player ids — and it used to live in
//! the game store, which is why two identity modules imported a module full of
//! Lyn Rummy boards to get at twenty lines. It is its own thing now, so nobody
//! takes the game store along for the ride.
//!
//! The file holds the NEXT value. `next()` returns the current one and writes
//! the successor, so an id is handed out exactly once. A missing or unparseable
//! file reads as 1: a fresh counter and a corrupt one both start over rather
//! than failing a request, and ids are only ever unique-per-file, never dense.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// mu serializes the read-add-write within this process, so two requests cannot
/// be handed the same id.
var mu: Io.Mutex = .init;

/// next returns the counter's current value and persists value+1, creating the
/// file and its parent directories. Floors at 1.
pub fn next(io: Io, alloc: Alloc, path: []const u8) !i64 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);

    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }

    var n: i64 = 0;
    if (Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64))) |body| {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (std.fmt.parseInt(i64, trimmed, 10)) |parsed| {
            n = parsed;
        } else |_| {}
    } else |_| {}
    if (n < 1) n = 1;

    const out = try std.fmt.allocPrint(alloc, "{d}\n", .{n + 1});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
    return n;
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// A counter that forgets is a counter that reissues an id, so the contract under
// test is the PERSISTENCE: a real file, read back by a second call.

const testing = std.testing;

test "fs: ids are handed out once, and survive a restart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A path whose parent does not exist yet — next() creates it.
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "deep", "n.txt" });

    try testing.expectEqual(@as(i64, 1), try next(io, a, path));
    try testing.expectEqual(@as(i64, 2), try next(io, a, path));
    try testing.expectEqual(@as(i64, 3), try next(io, a, path));

    // The file holds the NEXT value, not the last one handed out.
    const body = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64));
    try testing.expectEqualStrings("4\n", body);

    // A corrupt counter restarts rather than failing the request.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not a number" });
    try testing.expectEqual(@as(i64, 1), try next(io, a, path));
}
