//! **A CONNECTION'S WRITES, EACH UNDER A DEADLINE** (metal-vmm QUEUE 198.6
//! and the box's cold review of 213), for linux_host.zig: `Sent` puts every
//! write to a socket under its deadline, watched by one thread over a table
//! of the writes under way; `Hold` keeps an answer in memory while its handler
//! has the turn; `WriteWatch` watches a kept stream's writes. linux_host.zig
//! uses it as `linux_writes`.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;

/// **A KEPT STREAM'S WRITE HAS A DEADLINE** (metal-vmm QUEUE 198.6): a
/// reader that stays connected and stops reading blocked `serveKept`'s
/// write for good, and the stream ended only when a newer one displaced it.
/// A send taking no byte for this long fails, and the stream ends (as
/// metal's does after `idle_timeout_ms` with nothing taken).
pub const kept_write_deadline_ms: u64 = 30_000;
pub var turn_write_deadline_for_test_ms: ?u64 = null;

/// **AN ANSWER'S WRITES HAVE DEADLINES** (the box's cold review of 213): a
/// write in the turn (an answer past `held_most`) that takes no byte for
/// `turn_write_deadline_ms` has its socket shut, so the turn is held up by
/// one stuck client for that long at most; one after the turn, for
/// `answer_write_deadline_ms`, as a kept stream's (it holds only its own
/// connection, but a client that never reads must not hold it for good).
pub const turn_write_deadline_ms: u64 = 5_000;
pub const answer_write_deadline_ms: u64 = kept_write_deadline_ms;
pub var answer_write_deadline_for_test_ms: ?u64 = null;
/// Writes whose socket was shut at their deadline, for tests and reports.
pub var writes_shut: std.atomic.Value(u64) = .init(0);

/// **THE MOST AN ANSWER HOLDS IN MEMORY** while its handler has the turn:
/// every ordinary page; a larger answer is written in the turn, under the
/// turn's write deadline.
pub const held_most: usize = 1024 * 1024;

/// An answer held while its handler has the turn, and written after.
pub const Hold = struct {
    to: *std.Io.Writer,
    gpa: std.mem.Allocator,
    holding: bool = false,
    /// Past `held_most`: what was held has been written, and the rest goes
    /// straight on.
    spilled: bool = false,
    list: std.ArrayList(u8) = .empty,
    interface: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    pub fn begin(h: *Hold) void {
        h.holding = true;
        h.spilled = false;
    }

    /// What was held, written and flushed; holding no more. Its memory
    /// given back, so a kept connection holds none between requests.
    pub fn release(h: *Hold) std.Io.Writer.Error!void {
        h.holding = false;
        defer h.list.clearAndFree(h.gpa);
        if (h.list.items.len > 0) try h.to.writeAll(h.list.items);
        try h.to.flush();
    }

    pub fn spill(h: *Hold) std.Io.Writer.Error!void {
        h.spilled = true;
        try h.to.writeAll(h.list.items);
        h.list.clearAndFree(h.gpa);
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const h: *Hold = @alignCast(@fieldParentPtr("interface", w));
        if (!h.holding or h.spilled) return h.to.writeSplat(data, splat);
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |d| total += d.len;
        total += data[data.len - 1].len * splat;
        if (h.list.items.len + total > held_most) {
            try h.spill();
            return h.to.writeSplat(data, splat);
        }
        h.list.ensureUnusedCapacity(h.gpa, total) catch {
            try h.spill();
            return h.to.writeSplat(data, splat);
        };
        for (data[0 .. data.len - 1]) |d| h.list.appendSliceAssumeCapacity(d);
        for (0..splat) |_| h.list.appendSliceAssumeCapacity(data[data.len - 1]);
        return total;
    }

    pub fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const h: *Hold = @alignCast(@fieldParentPtr("interface", w));
        // Held, a file is read into memory by `drain`.
        if (h.holding and !h.spilled) return error.Unimplemented;
        return h.to.sendFile(file_reader, limit);
    }

    pub fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const h: *Hold = @alignCast(@fieldParentPtr("interface", w));
        if (h.holding and !h.spilled) return;
        return h.to.flush();
    }
};

/// The socket's writes, each under its deadline (`watchWrite`).
pub const Sent = struct {
    to: *std.Io.Writer,
    stream: net.Stream,
    io: Io,
    /// Whether this connection's handler has the turn: its writes then
    /// hold up the site, and have the turn's shorter deadline.
    in_turn: bool = false,
    /// Whether the watchdog shut the socket at a write's deadline.
    shut: bool = false,
    interface: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    pub fn deadline(s: *const Sent) u64 {
        return if (s.in_turn) turn_write_deadline_for_test_ms orelse turn_write_deadline_ms else answer_write_deadline_for_test_ms orelse answer_write_deadline_ms;
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *Sent = @alignCast(@fieldParentPtr("interface", w));
        const t = watchWrite(s.io, s.stream, s.deadline());
        defer if (!doneWrite(s.io, t)) {
            s.shut = true;
        };
        return s.to.writeSplat(data, splat);
    }

    pub fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const s: *Sent = @alignCast(@fieldParentPtr("interface", w));
        const t = watchWrite(s.io, s.stream, s.deadline());
        defer if (!doneWrite(s.io, t)) {
            s.shut = true;
        };
        return s.to.sendFile(file_reader, limit);
    }

    pub fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s: *Sent = @alignCast(@fieldParentPtr("interface", w));
        return s.to.flush();
    }
};

/// **THE WRITES UNDER WAY**, each with when it began and its deadline, and
/// the one watchdog that shuts a socket whose write is past it. A table, not
/// a thread a connection: one thread watches them all.
const writes_most = 256;
var writes: [writes_most]?struct { stream: net.Stream, since_ms: i64, deadline_ms: u64, ticket: u64 } = @splat(null);
var writes_lock: Io.Mutex = .init;
var writes_tickets: u64 = 0;
var watchdog_started: std.atomic.Value(bool) = .init(false);

const WriteTicket = struct { slot: ?usize, ticket: u64 };

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

fn watchWrite(io: Io, stream: net.Stream, deadline_ms: u64) WriteTicket {
    if (!watchdog_started.swap(true, .acq_rel)) {
        const t = std.Thread.spawn(.{}, writeWatchdog, .{io}) catch {
            watchdog_started.store(false, .release);
            return .{ .slot = null, .ticket = 0 };
        };
        t.detach();
    }
    writes_lock.lockUncancelable(io);
    defer writes_lock.unlock(io);
    writes_tickets += 1;
    for (&writes, 0..) |*w, i| if (w.* == null) {
        w.* = .{ .stream = stream, .since_ms = nowMs(io), .deadline_ms = deadline_ms, .ticket = writes_tickets };
        return .{ .slot = i, .ticket = writes_tickets };
    };
    // A full table: the write goes unwatched, as every write did before.
    return .{ .slot = null, .ticket = 0 };
}

/// Whether the write ended before its deadline: false when the watchdog
/// took it out of the table and shut its socket.
fn doneWrite(io: Io, t: WriteTicket) bool {
    const i = t.slot orelse return true;
    writes_lock.lockUncancelable(io);
    defer writes_lock.unlock(io);
    if (writes[i]) |w| if (w.ticket == t.ticket) {
        writes[i] = null;
        return true;
    };
    return false;
}

fn writeWatchdog(io: Io) void {
    while (true) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(50) }, io) catch {};
        const now = nowMs(io);
        writes_lock.lockUncancelable(io);
        for (&writes) |*slot| if (slot.*) |w| if (now - w.since_ms >= @as(i64, @intCast(w.deadline_ms))) {
            // Its write fails, its handler or task ends, its turn (if it
            // holds it) is let go.
            w.stream.shutdown(io, .both) catch {};
            _ = writes_shut.fetchAdd(1, .acq_rel);
            slot.* = null;
        };
        writes_lock.unlock(io);
    }
}
pub var write_deadline_for_test_ms: ?u64 = null;

/// A kept stream's watcher: it samples the write count a quarter-deadline at
/// a time, and a write under way (odd) that has not moved for the whole
/// deadline has its socket shut. Not SO_SNDTIMEO: std's Io takes the EAGAIN
/// it gives for a programmer's error.
pub var writes_ended_by_deadline: std.atomic.Value(u64) = .init(0);
pub const WriteWatch = struct {
    stream: net.Stream,
    ms: u64,
    writes: std.atomic.Value(u64) = .init(0),
    /// Woken as well as stored: the watcher waits on it, so the stream's end
    /// is not held for the rest of a step (a quarter of the deadline).
    state: std.atomic.Value(State) = .init(.watching),

    const State = enum(u32) { watching, ended };

    pub fn end(self: *WriteWatch, io: Io) void {
        self.state.store(.ended, .release);
        io.futexWake(State, &self.state.raw, 1);
    }

    pub fn run(self: *WriteWatch, io: Io) void {
        const step = @max(self.ms / 4, 10);
        var last = self.writes.load(.acquire);
        var still: u64 = 0;
        while (self.state.load(.acquire) == .watching) {
            io.futexWaitTimeout(State, &self.state.raw, .watching, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@intCast(step)) } }) catch {};
            if (self.state.load(.acquire) == .ended) return;
            const now = self.writes.load(.acquire);
            if (now != last or now % 2 == 0) {
                last = now;
                still = 0;
                continue;
            }
            still += step;
            if (still >= self.ms) {
                _ = writes_ended_by_deadline.fetchAdd(1, .acq_rel);
                self.stream.shutdown(io, .both) catch {};
                return;
            }
        }
    }
};
