//! bus: a keyed pub/sub fan-out for SSE streams — the zig port's answer to Go's
//! `subBus[T]` (server/chat/sse.go). Each key maps to a set of Subscribers (one
//! per open tab); `publish` is best-effort (a full subscriber drops the event,
//! since every stream using this is live-only — a missed event is re-derived on
//! reload). This is the SPIKE artifact that settles chat's concurrency runtime
//! BEFORE chat lands: prove fan-out + cross-connection synchronization on a toy
//! tenant (spike.zig's /spike/events), then graduate this verbatim into chat.
//!
//! Specialized to owned-`[]u8` messages.
//! When chat needs typed events it becomes `Bus(comptime T)`; the
//! shape doesn't change.
//!
//! Synchronization (all io-aware, std.Io primitives — work across the thread
//! pool the server runs connections on):
//!   - Bus.mutex guards the subscriber registry. Lock order: bus.mutex → sub.mutex
//!     (publish takes bus.mutex, then each sub.mutex). close/open take only
//!     bus.mutex; next() takes only sub.mutex. No cycle, no deadlock.
//!   - Each Subscriber has its own mutex (guards the ring) + an atomic `seq`
//!     futex (the wakeup edge). push() bumps seq + futexWake; next() futexWaits
//!     on seq with a timeout, so an idle stream still wakes to send a keepalive.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// Subscriber is one open stream's mailbox: a small bounded ring of owned
/// messages, drained by the stream's handler via `next()`. The handler owns the
/// Subscriber's lifetime — it calls Bus.open to create it and (via defer)
/// Bus.close to remove + destroy it. After close removes it from the registry
/// (under bus.mutex), no publisher can reference it, so destroy is race-free.
pub const Subscriber = struct {
    io: Io,
    alloc: Alloc,
    mutex: Io.Mutex = .init,
    /// Bumped on every push (the futex wakeup edge). next() waits on a snapshot
    /// of this; a push between snapshot and wait makes futexWait return at once.
    seq: std.atomic.Value(u32) = .init(0),
    ring: [cap]?[]u8 = @splat(null),
    head: usize = 0,
    count: usize = 0,

    const cap = 16;
    /// How long next() blocks with no message before returning .idle, so the
    /// stream emits a keepalive (and thereby notices a vanished client on the
    /// failed write). Go uses 25s; matched here.
    const keepalive_s = 25;

    pub const Next = union(enum) {
        /// An owned message — the caller must free it with the bus allocator.
        msg: []u8,
        /// No message within the keepalive window — send a ping.
        idle,
    };

    /// push enqueues a COPY of msg, dropping it if the ring is full or the copy
    /// allocation fails (best-effort, exactly like Go's non-blocking channel
    /// send). Wakes next() via the seq futex.
    fn push(self: *Subscriber, msg: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.count < cap) {
                if (self.alloc.dupe(u8, msg)) |copy| {
                    self.ring[(self.head + self.count) % cap] = copy;
                    self.count += 1;
                } else |_| {}
            }
        }
        _ = self.seq.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.seq.raw, 1);
    }

    /// take pops the oldest message if present (caller holds nothing; takes the
    /// lock itself). Returns null when empty.
    fn take(self: *Subscriber) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const m = self.ring[self.head].?;
        self.ring[self.head] = null;
        self.head = (self.head + 1) % cap;
        self.count -= 1;
        return m;
    }

    /// next blocks until a message arrives or the keepalive window elapses.
    /// Returns an owned message (caller frees) or .idle. Spurious wakeups just
    /// fall through to .idle — a harmless extra ping.
    pub fn next(self: *Subscriber) Next {
        if (self.take()) |m| return .{ .msg = m };
        const expected = self.seq.load(.acquire);
        self.io.futexWaitTimeout(u32, &self.seq.raw, expected, .{
            .duration = .{ .raw = .fromSeconds(keepalive_s), .clock = .awake },
        }) catch {};
        if (self.take()) |m| return .{ .msg = m };
        return .idle;
    }

    fn drainAndFree(self: *Subscriber) void {
        while (self.take()) |m| self.alloc.free(m);
    }
};

pub const Bus = struct {
    io: Io,
    alloc: Alloc,
    mutex: Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct { key: []u8, sub: *Subscriber };

    pub fn init(io: Io, alloc: Alloc) Bus {
        return .{ .io = io, .alloc = alloc };
    }

    /// open registers a new Subscriber under `key` and returns it. The caller
    /// owns it and must pair this with `close`.
    pub fn open(self: *Bus, key: []const u8) !*Subscriber {
        const sub = try self.alloc.create(Subscriber);
        sub.* = .{ .io = self.io, .alloc = self.alloc };
        const key_copy = try self.alloc.dupe(u8, key);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries.append(self.alloc, .{ .key = key_copy, .sub = sub }) catch |e| {
            self.alloc.free(key_copy);
            self.alloc.destroy(sub);
            return e;
        };
        return sub;
    }

    /// close removes `sub` from the registry, then frees it. Removal happens
    /// under bus.mutex, so once it returns no publisher can reach `sub` —
    /// draining + destroy is then race-free.
    pub fn close(self: *Bus, sub: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (self.entries.items[i].sub == sub) {
                self.alloc.free(self.entries.items[i].key);
                _ = self.entries.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock(self.io);
        sub.drainAndFree();
        self.alloc.destroy(sub);
    }

    /// publish delivers msg (best-effort) to every subscriber on `key`.
    pub fn publish(self: *Bus, key: []const u8, msg: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) e.sub.push(msg);
        }
    }

    /// subscriberCount reports how many streams are open on `key` (for the
    /// spike's /spike/broadcast acknowledgement — handy proof of fan-out width).
    pub fn subscriberCount(self: *Bus, key: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) n += 1;
        }
        return n;
    }
};
