//! linux_durable: **NO RESPONSE LEAVES BEFORE THE WRITES AHEAD OF IT ARE
//! DURABLE** (zig-metal-unikernel HOST.md, "Durability"), on Linux. Part of
//! the `webbox` library's Linux half.
//!
//! The store counts every call that changes the disk (`store.changes`). The
//! host hands each connection a `Writer` in place of the socket's: before
//! any byte goes to the socket, if the store has changed the disk since the
//! last sync, the filesystems under the data's roots are synced (`syncfs`).
//! That is the moment the bare-metal host flushes its disks (`io.durable`,
//! called from its `Stream.sendAll`), so the two hosts make the same promise
//! at the same point: a response, or a kept stream's frame, goes out only
//! after what was written before it is on the disk.
//!
//! **A COUNT, NOT A FLAG**: a kept stream's frames go out on its own task,
//! outside the turn, at the same time as a handler's response. With a flag,
//! one task could clear it and still be syncing when the other read it clear
//! and sent. Here each sender compares the store's count with the count the
//! last finished sync covered, and syncs itself when it is behind: two
//! senders may both sync, never neither.
//!
//! **A FAILED SYNC IS LOGGED, AND THE RESPONSE GOES** (HOST.md): the count
//! it would have covered is not marked synced, so the next response tries
//! again.

const std = @import("std");
const Io = @import("host_io").Io;
const store = @import("webbox").store;

/// What a sync of the roots is: true when it succeeded. A test hands in its own.
pub const SyncFn = *const fn (d: *Durable) bool;

pub const Durable = struct {
    /// The store's count (`store.changes`) the last finished sync covered.
    synced: std.atomic.Value(u64),
    sync: SyncFn,
    /// The roots' directories, open for `syncRoots`; -1 where none.
    roots: [2]std.posix.fd_t = .{ -1, -1 },
    /// Syncs that failed, for a host's report.
    failures: std.atomic.Value(u64) = .init(0),

    /// `synced_through`: the store's count already durable (0 at a process's
    /// start, so the first response covers what starting wrote).
    pub fn init(sync: SyncFn, synced_through: u64) Durable {
        return .{ .synced = .init(synced_through), .sync = sync };
    }

    /// **BEFORE ANY BYTE OF A RESPONSE**: a sync, if the store has changed
    /// the disk since the last one covered it; nothing otherwise.
    pub fn beforeBytes(self: *Durable) void {
        const want = store.changes.load(.acquire);
        if (self.synced.load(.acquire) >= want) return;
        if (!self.sync(self)) {
            _ = self.failures.fetchAdd(1, .acq_rel);
            if (!@import("builtin").is_test) std.debug.print("durable: a sync of the data's filesystems failed; the response goes out anyway\n", .{});
            return;
        }
        _ = self.synced.fetchMax(want, .acq_rel);
    }

    /// **NOW, AND WHETHER IT HELD** (store.makeDurable): what
    /// `beforeBytes` does, answering whether every write so far is durable.
    pub fn now(self: *Durable) bool {
        const want = store.changes.load(.acquire);
        if (self.synced.load(.acquire) >= want) return true;
        if (!self.sync(self)) {
            _ = self.failures.fetchAdd(1, .acq_rel);
            return false;
        }
        _ = self.synced.fetchMax(want, .acq_rel);
        return true;
    }

    /// Opens the directories whose filesystems hold the data: the store's two
    /// roots, or, when the host has none (a development run on the
    /// repository's defaults, which resolve from the working directory), the
    /// working directory. A root that will not open stops the host.
    pub fn openRoots(self: *Durable, io: Io) ![]const u8 {
        if (store.data_base == null and store.auth_base == null) {
            self.roots[0] = try openRoot(io, ".");
            return "the working directory's filesystem (no data roots)";
        }
        for ([_]?[]const u8{ store.data_base, store.auth_base }, 0..) |base, i| {
            const b = base orelse continue;
            self.roots[i] = try openRoot(io, b);
        }
        return "the filesystems of the data and auth roots";
    }
};

/// A root's directory, opened so `syncfs` takes it: an `openDir` that will
/// not iterate opens with O_PATH, and `syncfs` refuses that (EBADF).
fn openRoot(io: Io, path: []const u8) !std.posix.fd_t {
    return (try Io.Dir.cwd().openDir(io, path, .{ .iterate = true })).handle;
}

/// `syncfs` on each open root: the whole filesystem under it, so every file
/// the store wrote there, and the folders that name them.
pub fn syncRoots(d: *Durable) bool {
    var ok = true;
    for (d.roots) |fd| if (fd >= 0) {
        if (std.os.linux.errno(std.os.linux.syncfs(fd)) != .SUCCESS) ok = false;
    };
    return ok;
}

/// **THE CONNECTION'S WRITER**: buffers as a socket writer would, and calls
/// `Durable.beforeBytes` before it hands any byte on to `to` (the socket's
/// own writer, unbuffered). Taken by pointer once made (`&w.interface`).
pub const Writer = struct {
    to: *std.Io.Writer,
    durable: *Durable,
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    pub fn init(to: *std.Io.Writer, durable: *Durable, buffer: []u8) Writer {
        return .{ .to = to, .durable = durable, .interface = .{ .buffer = buffer, .vtable = &vtable } };
    }

    /// What is buffered, on to `to`, after the sync.
    fn pass(self: *Writer) std.Io.Writer.Error!void {
        const w = &self.interface;
        if (w.end == 0) return;
        self.durable.beforeBytes();
        defer w.end = 0;
        try self.to.writeAll(w.buffer[0..w.end]);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.pass();
        self.durable.beforeBytes();
        return self.to.writeSplat(data, splat);
    }

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.pass();
        self.durable.beforeBytes();
        return self.to.sendFile(file_reader, limit);
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.pass();
        return self.to.flush();
    }
};

// ── tests ───────────────────────────────────────────────────────────────────
//
// **THE SYNC IS INJECTED** (`Durable.sync`): a test's counts its calls and
// notes how many bytes had reached the sink when it was called, so "before
// the first byte" is checked, not assumed, with no syscall. The store's
// writes are real, into a temporary folder: the count they advance is the
// one production reads.

const testing = std.testing;

var sink: *std.Io.Writer.Allocating = undefined;
var syncs: usize = 0;
var sent_at_sync: usize = 0;
var sync_ok = true;

fn countSync(_: *Durable) bool {
    syncs += 1;
    sent_at_sync = sink.written().len;
    return sync_ok;
}

const Answer = enum { whole, streamed };

/// One request answered through a `Writer` over `sink`: what the sink held
/// before it began.
fn answerOne(d: *Durable, how: Answer) !usize {
    const before = sink.written().len;
    var reader: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nhost: x\r\n\r\n");
    var buf: [256]u8 = undefined;
    var w: Writer = .init(&sink.writer, d, &buf);
    var server = std.http.Server.init(&reader, &w.interface);
    var req = try server.receiveHead();
    switch (how) {
        .whole => try req.respond("saved", .{ .keep_alive = false }),
        .streamed => {
            var hbuf: [64]u8 = undefined;
            var body = try req.respondStreaming(&hbuf, .{ .respond_options = .{ .keep_alive = false } });
            try body.writer.writeAll("one");
            try body.flush();
            try body.writer.writeAll("two");
            try body.end();
        },
    }
    try w.interface.flush();
    try testing.expect(std.mem.endsWith(u8, sink.written(), if (how == .whole) "saved" else "0\r\n\r\n"));
    return before;
}

test "durable: a write, then a response: one sync, before its first byte; a response with no write: none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var out: std.Io.Writer.Allocating = .init(a);
    sink = &out;
    syncs = 0;
    sync_ok = true;
    var d: Durable = .init(countSync, store.changes.load(.acquire));

    for ([_]Answer{ .whole, .streamed }) |how| {
        // No write: no sync.
        _ = try answerOne(&d, how);
        try testing.expectEqual(@as(usize, 0), syncs);

        // A write: one sync, with none of the response sent yet.
        try store.write(io, a, try std.fs.path.join(a, &.{ dir, "record" }), "saved", .{});
        const began = try answerOne(&d, how);
        try testing.expectEqual(@as(usize, 1), syncs);
        try testing.expectEqual(began, sent_at_sync);

        // Nothing written since: no second sync.
        _ = try answerOne(&d, how);
        try testing.expectEqual(@as(usize, 1), syncs);
        syncs = 0;
    }
}

test "durable: a failed sync is counted, the response still goes, and the next response tries again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var out: std.Io.Writer.Allocating = .init(a);
    sink = &out;
    syncs = 0;
    var d: Durable = .init(countSync, store.changes.load(.acquire));

    _ = try store.append(io, a, try std.fs.path.join(a, &.{ dir, "log" }), "one\n");
    sync_ok = false;
    _ = try answerOne(&d, .whole); // goes out; answerOne checks it whole
    try testing.expectEqual(@as(usize, 1), syncs);
    try testing.expectEqual(@as(u64, 1), d.failures.load(.acquire));

    sync_ok = true;
    _ = try answerOne(&d, .whole);
    try testing.expectEqual(@as(usize, 2), syncs);
    _ = try answerOne(&d, .whole);
    try testing.expectEqual(@as(usize, 2), syncs);
}

test "durable: the real sync on a root opened as openRoots opens it succeeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(dir);

    var d: Durable = .init(syncRoots, 0);
    d.roots[0] = try openRoot(io, dir);
    defer _ = std.os.linux.close(d.roots[0]);
    try testing.expect(syncRoots(&d));
}

test "durable: the real sync on a root opened O_PATH fails, and is counted: the ad144c7 bug, held by the syscall itself (metal-vmm QUEUE 198.6)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(dir);
    var d: Durable = .init(syncRoots, 0);
    // An openDir that will not iterate: O_PATH, which syncfs refuses.
    d.roots[0] = (try Io.Dir.cwd().openDir(io, dir, .{})).handle;
    defer _ = std.os.linux.close(d.roots[0]);
    try testing.expect(!syncRoots(&d));
}

test "durable: openRoots opens each root as syncfs takes it, or the working directory when there are none, and the real sync succeeds on them (metal-vmm QUEUE 198.6)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(base);
    const data = try std.fs.path.join(testing.allocator, &.{ base, "data" });
    defer testing.allocator.free(data);
    const auth = try std.fs.path.join(testing.allocator, &.{ base, "auth" });
    defer testing.allocator.free(auth);
    try tmp.dir.createDir(io, "data", .default_dir);
    try tmp.dir.createDir(io, "auth", .default_dir);

    const was_data = store.data_base;
    const was_auth = store.auth_base;
    defer {
        store.data_base = was_data;
        store.auth_base = was_auth;
    }
    {
        store.data_base = data;
        store.auth_base = auth;
        var d: Durable = .init(syncRoots, 0);
        _ = try d.openRoots(io);
        defer for (d.roots) |fd| if (fd >= 0) {
            _ = std.os.linux.close(fd);
        };
        try testing.expect(d.roots[0] >= 0 and d.roots[1] >= 0);
        try testing.expect(syncRoots(&d));
    }
    {
        store.data_base = null;
        store.auth_base = null;
        var d: Durable = .init(syncRoots, 0);
        _ = try d.openRoots(io);
        defer if (d.roots[0] >= 0) {
            _ = std.os.linux.close(d.roots[0]);
        };
        try testing.expect(d.roots[0] >= 0 and d.roots[1] == -1);
        try testing.expect(syncRoots(&d));
    }
}
