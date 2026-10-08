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
const store = @import("store.zig");

/// mu serializes the read-add-write within this process, so two requests cannot
/// be handed the same id.
var mu: Io.Mutex = .init;

/// next returns the counter's current value and persists value+1, creating the
/// file and its parent directories. Floors at 1.
pub fn next(io: Io, alloc: Alloc, path: []const u8) !i64 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);

    const n = try current(io, alloc, path);

    const out = try std.fmt.allocPrint(alloc, "{d}\n", .{n + 1});
    try store.replace(io, alloc, path, out, .{});
    return n;
}

/// peek answers the value `next` would hand out, and writes nothing: what a
/// page offers before anything is made (puzzles.zig, a session made on its
/// first move). Floors at 1, as `next` does.
pub fn peek(io: Io, alloc: Alloc, path: []const u8) !i64 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    return current(io, alloc, path);
}

/// The value the counter holds, floored at 1; 1 when there is no counter
/// yet. **A COUNTER THAT CANNOT BE READ, OR DOES NOT HOLD A NUMBER, IS AN
/// ERROR** (metal-vmm QUEUE 105): read as a new one, it handed out ids
/// already given. Called under `mu`.
fn current(io: Io, alloc: Alloc, path: []const u8) !i64 {
    const body = (try store.readOrNull(io, alloc, path, .limited(64))) orelse return 1;
    return @max(try std.fmt.parseInt(i64, std.mem.trim(u8, body, " \t\r\n"), 10), 1);
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

    // A corrupt counter fails the request, and is left as it is: restarting
    // it handed out ids already given (metal-vmm QUEUE 105).
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not a number" });
    try testing.expect(std.meta.isError(next(io, a, path)));
    try testing.expectEqualStrings("not a number", try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64)));
}

test "fs: peek answers what next would, and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "deep", "n.txt" });
    try testing.expectEqual(@as(i64, 1), peek(io, a, path));
    try testing.expect(!try store.has(io, a, path)); // no file, and no folder for it, made
    try testing.expectEqual(@as(i64, 1), peek(io, a, path));
    try testing.expectEqual(@as(i64, 1), try next(io, a, path));
    try testing.expectEqual(@as(i64, 2), peek(io, a, path));
    try testing.expectEqual(@as(i64, 2), peek(io, a, path));
    try testing.expectEqual(@as(i64, 2), try next(io, a, path));
}

test "fs: a counter that cannot be read is an error, never 1 again (metal-vmm QUEUE 105)" {
    // An unreadable counter read as a fresh one: next handed out 1, then 2,
    // ids already given (a member's account among them, users.zig).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "n.txt" });
    try store.makeDir(io, a, path); // there, and unreadable
    try testing.expect(std.meta.isError(next(io, a, path)));
    try testing.expect(std.meta.isError(peek(io, a, path)));
    // Garbled is not new either.
    const garbled = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "g.txt" });
    try store.write(io, a, garbled, "4x\n", .{});
    try testing.expect(std.meta.isError(next(io, a, garbled)));
    // Absent is the first id.
    const absent = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "new.txt" });
    try testing.expectEqual(@as(i64, 1), try next(io, a, absent));
}
