//! bus: a keyed pub/sub fan-out for SSE streams, and the seam where a HOST
//! takes a stream over.
//!
//! **THE APPLICATION DESCRIBES A STREAM; THE HOST KEEPS IT.** A stream handler
//! writes its headers and backlog, then records a `Kept` — its subscriber, and
//! how to render an event for this viewer — on its request's `Bus` and returns.
//! The host serves what was kept: on Linux, `serveKept` blocks on the
//! connection's own task exactly as the handler's loop used to; on a machine
//! with one loop, `drainKept` renders whatever has arrived and the host writes
//! it, then moves on. The application is one source for both.
//!
//! `Hub` is the shared registry (one per process). `Bus` is a small
//! per-request handle over it, which is what makes "the stream this request
//! kept" a field rather than a global — requests run concurrently on Linux.
//! Each key maps to a set of Subscribers (one
//! per open tab); `publish` is best-effort (a full subscriber drops the event,
//! since every stream using this is live-only — a missed event is re-derived on
//! reload). It drives chat's live streams (chat_sse.zig); it was prototyped on a
//! standalone concurrency spike (since removed) before chat was ported.
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
    /// SERVER-lifetime allocator (named `gpa`, like presence's): the ring outlives
    /// any one request, so `push` DUPES each message into it. Never the request arena.
    gpa: Alloc,
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
    /// failed write).
    pub const keepalive_s = 25;

    pub const Next = union(enum) {
        /// An owned message — the caller must free it with the bus allocator.
        msg: []u8,
        /// No message within the keepalive window — send a ping.
        idle,
    };

    /// push enqueues a COPY of msg, dropping it if the ring is full or the copy
    /// allocation fails (best-effort: a non-blocking enqueue that drops rather
    /// than blocks). Wakes next() via the seq futex.
    fn push(self: *Subscriber, msg: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.count < cap) {
                if (self.gpa.dupe(u8, msg)) |copy| {
                    self.ring[(self.head + self.count) % cap] = copy;
                    self.count += 1;
                } else |_| {}
            }
        }
        _ = self.seq.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.seq.raw, 1);
    }

    /// poll takes the oldest message without waiting, or null. For hosts that
    /// cannot block: the caller frees it with the bus allocator.
    pub fn poll(self: *Subscriber) ?[]u8 {
        return self.take();
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
        while (self.take()) |m| self.gpa.free(m);
    }
};

pub const Hub = struct {
    io: Io,
    /// SERVER-lifetime allocator: registry + every Subscriber it mints live on this,
    /// so `open` dupes the key into it. `alloc` (request arena) must never land here.
    gpa: Alloc,
    mutex: Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct { key: []u8, sub: *Subscriber };

    pub fn init(io: Io, gpa: Alloc) Hub {
        return .{ .io = io, .gpa = gpa };
    }

    /// open registers a new Subscriber under `key` and returns it. The caller
    /// owns it and must pair this with `close`.
    pub fn open(self: *Hub, key: []const u8) !*Subscriber {
        const sub = try self.gpa.create(Subscriber);
        sub.* = .{ .io = self.io, .gpa = self.gpa };
        const key_copy = try self.gpa.dupe(u8, key);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries.append(self.gpa, .{ .key = key_copy, .sub = sub }) catch |e| {
            self.gpa.free(key_copy);
            self.gpa.destroy(sub);
            return e;
        };
        return sub;
    }

    /// close removes `sub` from the registry, then frees it. Removal happens
    /// under bus.mutex, so once it returns no publisher can reach `sub` —
    /// draining + destroy is then race-free.
    pub fn close(self: *Hub, sub: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (self.entries.items[i].sub == sub) {
                self.gpa.free(self.entries.items[i].key);
                _ = self.entries.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock(self.io);
        sub.drainAndFree();
        self.gpa.destroy(sub);
    }

    /// publish delivers msg (best-effort) to every subscriber on `key`.
    pub fn publish(self: *Hub, key: []const u8, msg: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) e.sub.push(msg);
        }
    }
};

/// A request's handle on the hub. Everything a handler does with the bus goes
/// through it; the one thing it adds is `kept`.
pub const Bus = struct {
    hub: *Hub,
    /// The stream this request handed to the host, if it did.
    kept: ?Kept = null,

    pub fn of(hub: *Hub) Bus {
        return .{ .hub = hub };
    }

    pub fn open(self: *Bus, key: []const u8) !*Subscriber {
        return self.hub.open(key);
    }

    pub fn close(self: *Bus, sub: *Subscriber) void {
        self.hub.close(sub);
    }

    pub fn publish(self: *Bus, key: []const u8, msg: []const u8) void {
        self.hub.publish(key, msg);
    }

    /// The server-lifetime allocator, for anything a kept stream owns.
    pub fn gpa(self: *Bus) Alloc {
        return self.hub.gpa;
    }

    /// Hands the stream to the host. At most once per request.
    pub fn keep(self: *Bus, k: Kept) void {
        std.debug.assert(self.kept == null);
        self.kept = k;
    }
};

/// What a host needs to go on serving a stream after its handler returned.
/// Nothing in it points into the request: its arena and writer are gone by
/// the time the host uses this.
pub const Kept = struct {
    sub: *Subscriber,
    /// This viewer's frame for one published event, or null to send nothing.
    /// `arena` lives for that one frame.
    render: *const fn (ctx: []const u8, arena: Alloc, blob: []const u8) ?[]const u8,
    /// What `render` needs to know about the viewer, owned by the hub's
    /// allocator and freed with the stream.
    ctx: []const u8 = "",
};

/// The keepalive: a comment line, which a browser ignores. A stream that has
/// sent nothing for `Subscriber.keepalive_s` sends this, and a closed tab is
/// noticed when it cannot be written.
pub const ping = ": ping\n\n";

/// Ends a kept stream: its subscriber leaves the registry, its context is
/// freed.
pub fn drop(hub: *Hub, k: Kept) void {
    hub.close(k.sub);
    if (k.ctx.len > 0) hub.gpa.free(k.ctx);
}

/// **FOR A HOST WITH A TASK PER CONNECTION.** Serves a kept stream until its
/// client goes away — the loop the stream handlers used to run themselves.
pub fn serveKept(hub: *Hub, k: Kept, w: *std.Io.Writer) void {
    defer drop(hub, k);
    while (true) {
        switch (k.sub.next()) {
            .msg => |blob| {
                defer k.sub.gpa.free(blob);
                var arena = std.heap.ArenaAllocator.init(hub.gpa);
                defer arena.deinit();
                const frame = k.render(k.ctx, arena.allocator(), blob) orelse continue;
                w.writeAll(frame) catch return;
                w.flush() catch return;
            },
            .idle => {
                w.writeAll(ping) catch return;
                w.flush() catch return;
            },
        }
    }
}

/// **FOR A HOST WITH ONE LOOP.** Everything the stream has now, rendered and
/// appended to `out`, without waiting. Answers how many frames were added.
pub fn drainKept(k: Kept, arena: Alloc, out: *std.ArrayList(u8)) !usize {
    var frames: usize = 0;
    while (k.sub.poll()) |blob| {
        defer k.sub.gpa.free(blob);
        const frame = k.render(k.ctx, arena, blob) orelse continue;
        try out.appendSlice(arena, frame);
        frames += 1;
    }
    return frames;
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// The fan-out semantics, exercised single-threaded (the cross-thread futex
// races aren't unit-testable here, but the registry/ring/keying contract is).
// Everything runs on std.testing.allocator, so an unfreed message, key, or
// Subscriber fails the test — these double as a leak check on open/close/drain.
//
// INVARIANT the tests must respect: next() blocks for keepalive_s (25s) on an
// EMPTY subscriber. So we only ever call next() after publishing, and exactly as
// many times as there are buffered messages; emptiness is asserted via the
// private `count` field instead.

const testing = std.testing;

/// expectMsg drains one buffered message and checks it (the sub MUST be non-empty
/// or next() would block on the keepalive). Frees it with the bus allocator.
fn expectMsg(sub: *Subscriber, want: []const u8) !void {
    switch (sub.next()) {
        .msg => |m| {
            defer testing.allocator.free(m);
            try testing.expectEqualStrings(want, m);
        },
        .idle => return error.TestUnexpectedIdle,
    }
}

test "bus: a published message reaches a subscriber as an owned copy" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = Hub.init(threaded.io(), testing.allocator);
    defer bus.entries.deinit(testing.allocator);

    const sub = try bus.open("room");
    bus.publish("room", "hello");
    try expectMsg(sub, "hello");
    bus.close(sub);
}

test "bus: publish fans out to every subscriber on the key; other keys never see it" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = Hub.init(threaded.io(), testing.allocator);
    defer bus.entries.deinit(testing.allocator);

    const a1 = try bus.open("room");
    const a2 = try bus.open("room");
    const other = try bus.open("elsewhere");

    bus.publish("room", "hi");
    try expectMsg(a1, "hi"); // both room subscribers receive it
    try expectMsg(a2, "hi");
    try testing.expectEqual(@as(usize, 0), other.count); // keyed isolation: nothing queued

    bus.close(a1);
    bus.close(a2);
    bus.close(other);
}

test "bus: open/close add and remove registry entries" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = Hub.init(threaded.io(), testing.allocator);
    defer bus.entries.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), bus.entries.items.len);
    const s1 = try bus.open("k");
    const s2 = try bus.open("k");
    try testing.expectEqual(@as(usize, 2), bus.entries.items.len);
    bus.close(s1);
    try testing.expectEqual(@as(usize, 1), bus.entries.items.len);
    // a publish after one closes still reaches the survivor (and frees cleanly)
    bus.publish("k", "still here");
    try expectMsg(s2, "still here");
    bus.close(s2);
    try testing.expectEqual(@as(usize, 0), bus.entries.items.len);
}

test "bus: a full ring drops new messages best-effort, keeping the oldest cap in FIFO order" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = Hub.init(threaded.io(), testing.allocator);
    defer bus.entries.deinit(testing.allocator);

    const sub = try bus.open("k");

    // publish cap+4 distinct messages; only the first `cap` fit, the rest drop.
    const overflow = Subscriber.cap + 4;
    var n: usize = 0;
    while (n < overflow) : (n += 1) {
        const m = try std.fmt.allocPrint(testing.allocator, "{d}", .{n});
        defer testing.allocator.free(m);
        bus.publish("k", m);
    }
    try testing.expectEqual(Subscriber.cap, sub.count);

    // draining yields exactly 0..cap-1 in order (the late arrivals were dropped).
    var want: usize = 0;
    while (want < Subscriber.cap) : (want += 1) {
        const s = try std.fmt.allocPrint(testing.allocator, "{d}", .{want});
        defer testing.allocator.free(s);
        try expectMsg(sub, s);
    }
    bus.close(sub);
}

fn upper(ctx: []const u8, arena: Alloc, blob: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, blob, "skip")) return null;
    return std.fmt.allocPrint(arena, "data: {s} for {s}\n\n", .{ blob, ctx }) catch null;
}

test "bus: a request's handle forwards to the hub, and keeps at most one stream" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    var bus = Bus.of(&hub);
    const sub = try bus.open("k");
    bus.publish("k", "via the handle");
    try expectMsg(sub, "via the handle");
    try testing.expect(bus.kept == null);
    bus.keep(.{ .sub = sub, .render = upper, .ctx = try testing.allocator.dupe(u8, "ann") });
    try testing.expect(bus.kept != null);
    drop(&hub, bus.kept.?);
    try testing.expectEqual(@as(usize, 0), hub.entries.items.len);
}

test "bus: two requests' handles are separate — keeping on one is not keeping on the other" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    var a = Bus.of(&hub);
    const b = Bus.of(&hub);
    const sub = try a.open("k");
    a.keep(.{ .sub = sub, .render = upper });
    try testing.expect(b.kept == null);
    drop(&hub, a.kept.?);
}

test "bus: drainKept renders what has arrived, skips what render declines, and never waits" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    const sub = try hub.open("k");
    const k = Kept{ .sub = sub, .render = upper, .ctx = "bob" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;

    // Nothing yet: returns at once with nothing.
    try testing.expectEqual(@as(usize, 0), try drainKept(k, arena.allocator(), &out));

    hub.publish("k", "one");
    hub.publish("k", "skip");
    hub.publish("k", "two");
    try testing.expectEqual(@as(usize, 2), try drainKept(k, arena.allocator(), &out));
    try testing.expectEqualStrings("data: one for bob\n\ndata: two for bob\n\n", out.items);
    try testing.expectEqual(@as(usize, 0), sub.count); // all taken, the skipped one freed
    hub.close(sub);
}

test "bus: serveKept writes each frame, and a write that fails ends the stream and frees it" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    const sub = try hub.open("k");
    hub.publish("k", "first");
    hub.publish("k", "second");

    // A writer that takes exactly one frame and then fails, as a closed
    // socket does: serveKept must return (not wait out a keepalive) and the
    // registry must be empty afterwards. testing.allocator checks the rest.
    var storage: [64]u8 = undefined;
    const want = "data: first for cy\n\n";
    var w: std.Io.Writer = .fixed(storage[0..want.len]);
    serveKept(&hub, .{ .sub = sub, .render = upper, .ctx = try testing.allocator.dupe(u8, "cy") }, &w);
    try testing.expectEqualStrings(want, w.buffered());
    try testing.expectEqual(@as(usize, 0), hub.entries.items.len);
}
