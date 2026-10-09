//! bus: a keyed pub/sub fan-out for SSE streams, and the seam where a HOST
//! takes a stream over.
//!
//! **THE APPLICATION DESCRIBES A STREAM; THE HOST KEEPS IT.** A stream handler
//! writes its headers and backlog, then records a `Kept` — its subscriber, and
//! how to render an event for this viewer — on its request's `Bus` and returns.
//! The host serves what was kept: on Linux, `serveKept` blocks on the
//! connection's own task exactly as the handler's loop used to; on a machine
//! with one loop, `nextFrame` renders the next event that has arrived — when
//! the host has somewhere to put it — and the host moves on. The application
//! is one source for both.
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
    /// An event was dropped because the ring was full. A host that can end
    /// the stream (so its browser reconnects and resumes) should, rather than
    /// carry on with a gap.
    missed: bool = false,

    const cap = 16;
    /// How long next() blocks with no message before returning .idle, so the
    /// stream emits a keepalive (and thereby notices a vanished client on the
    /// failed write).
    pub const keepalive_s = 25;
    /// The window next() waits, in milliseconds: `keepalive_s` unless the
    /// server was told otherwise (`GOPHER_KEEPALIVE_MS`, `keepaliveSetting`;
    /// metal-vmm QUEUE 137), so a test of a quiet tab need not wait 25 s.
    /// gopher-metal's kernel has the same knob (`keepalive_ms`).
    pub var keepalive_ms: u64 = keepalive_s * std.time.ms_per_s;

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
                } else |_| {
                    self.missed = true;
                }
            } else {
                self.missed = true;
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
            .duration = .{ .raw = .fromMilliseconds(@intCast(keepalive_ms)), .clock = .awake },
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
    /// The address the connection came from, as text (`203.0.113.7`,
    /// `2001:db8::1`), if the host knows it: the host sets it before `route`.
    /// What one address may make and write is bounded by it
    /// (game_limits.zig); with none, those bounds do not apply.
    peer: ?[]const u8 = null,

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

/// **THE KEEPALIVE, SET FOR TESTS** (metal-vmm QUEUE 137): `GOPHER_KEEPALIVE_MS`
/// as the server reads it. Unset is null (the default, 25 s); a whole number
/// of milliseconds above zero is the window; anything else is refused, and
/// the server does not start, as for GOPHER_BIND.
pub fn keepaliveSetting(text: ?[]const u8) error{InvalidKeepalive}!?u64 {
    const t = std.mem.trim(u8, text orelse return null, " \t\r\n");
    const ms = std.fmt.parseInt(u64, t, 10) catch return error.InvalidKeepalive;
    if (ms == 0 or ms > std.math.maxInt(u32)) return error.InvalidKeepalive;
    return ms;
}

/// The keepalive: a comment line, which a browser ignores. A stream that has
/// sent nothing for `Subscriber.keepalive_ms` sends this, and a closed tab is
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
        // **A MAILBOX THAT OVERFLOWED ENDS THE STREAM**, as `nextFrame` ends it
        // on a host with one loop: the browser reconnects and resumes from
        // its cursor. Carrying on would show this viewer a conversation with
        // a hole in it and no sign of one, which metal never did.
        if (k.sub.missed) return;
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

/// **FOR A HOST WITH ONE LOOP.** The stream's next frame, rendered into
/// `arena`, without waiting; null when nothing has arrived. One at a time, so
/// the host takes an event only when it has room to send it: until then the
/// event stays in the mailbox, as it would on Linux while a write blocks.
/// `error.EventsMissed` once the mailbox has dropped one: the host ends the
/// stream, and the browser reconnects and resumes.
pub fn nextFrame(k: Kept, arena: Alloc) !?[]const u8 {
    if (k.sub.missed) return error.EventsMissed;
    while (k.sub.poll()) |blob| {
        defer k.sub.gpa.free(blob);
        const frame = k.render(k.ctx, arena, blob) orelse continue;
        // The frame may point into the event, which is freed on return.
        return try arena.dupe(u8, frame);
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// The fan-out semantics, exercised single-threaded (the cross-thread futex
// races aren't unit-testable here, but the registry/ring/keying contract is).
// Everything runs on std.testing.allocator, so an unfreed message, key, or
// Subscriber fails the test — these double as a leak check on open/close/drain.
//
// INVARIANT the tests must respect: next() blocks for keepalive_ms (25s) on an
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

test "bus: GOPHER_KEEPALIVE_MS governs how long a quiet stream waits before a ping, and unset leaves 25 s (metal-vmm QUEUE 137)" {
    // The setting, read as the server reads it: unset is the default; a
    // number is milliseconds; anything else refuses to start.
    try testing.expectEqual(@as(?u64, null), try keepaliveSetting(null));
    try testing.expectEqual(@as(?u64, 200), try keepaliveSetting(" 200\n"));
    try testing.expectError(error.InvalidKeepalive, keepaliveSetting("25s"));
    try testing.expectError(error.InvalidKeepalive, keepaliveSetting("0"));
    try testing.expectEqual(@as(u64, 25_000), Subscriber.keepalive_ms);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus = Hub.init(io, testing.allocator);
    defer bus.entries.deinit(testing.allocator);
    const sub = try bus.open("room");
    defer bus.close(sub);

    // Set to 200 ms, an empty subscriber answers idle (a ping) no sooner
    // than that, and long before the default.
    Subscriber.keepalive_ms = (try keepaliveSetting("200")).?;
    defer Subscriber.keepalive_ms = Subscriber.keepalive_s * std.time.ms_per_s;
    const start = Io.Clock.now(.awake, io);
    try testing.expect(sub.next() == .idle);
    const waited_ms = @divFloor(start.durationTo(Io.Clock.now(.awake, io)).nanoseconds, std.time.ns_per_ms);
    try testing.expect(waited_ms >= 200);
    try testing.expect(waited_ms < 10_000);
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

test "bus: nextFrame renders what has arrived one at a time, skips what render declines, and never waits" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    const sub = try hub.open("k");
    const k = Kept{ .sub = sub, .render = upper, .ctx = "bob" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Nothing yet: returns at once with nothing.
    try testing.expectEqual(@as(?[]const u8, null), try nextFrame(k, arena.allocator()));

    hub.publish("k", "one");
    hub.publish("k", "skip");
    hub.publish("k", "two");
    try testing.expectEqualStrings("data: one for bob\n\n", (try nextFrame(k, arena.allocator())).?);
    try testing.expectEqual(@as(usize, 2), sub.count); // the rest wait in the mailbox
    try testing.expectEqualStrings("data: two for bob\n\n", (try nextFrame(k, arena.allocator())).?);
    try testing.expectEqual(@as(?[]const u8, null), try nextFrame(k, arena.allocator()));
    try testing.expectEqual(@as(usize, 0), sub.count); // all taken, the skipped one freed
    hub.close(sub);
}

test "bus: a mailbox that overflowed says so, and nextFrame stops rather than skip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);

    const sub = try hub.open("k");
    const k = Kept{ .sub = sub, .render = upper, .ctx = "bob" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (0..Subscriber.cap) |_| hub.publish("k", "fits");
    try testing.expect(!sub.missed);
    hub.publish("k", "one too many");
    try testing.expect(sub.missed);
    try testing.expectError(error.EventsMissed, nextFrame(k, arena.allocator()));
    hub.close(sub);
}

test "bus: a mailbox that overflowed ends serveKept at once, as nextFrame ends it" {
    var hub = Hub.init(testing.io, testing.allocator);
    const sub = try hub.open("k");
    for (0..Subscriber.cap + 1) |_| hub.publish("k", "x");
    try testing.expect(sub.missed);
    var storage: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    // Returns without writing or waiting: the stream ends, and drop frees it.
    serveKept(&hub, .{ .sub = sub, .render = upper }, &w);
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expectEqual(@as(usize, 0), hub.entries.items.len);
    hub.entries.deinit(testing.allocator);
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

// ── the mailbox contract, over seeded runs ──────────────────────────────────
//
// **THE CONTRACT BOTH HOSTS SERVE** (gopher-metal HOST.md, "Live streams"):
// a reader sees exactly the events published on its key since it opened, in
// the order they were published, nothing from another key and nothing
// skipped; a reader whose mailbox was full when an event arrived ends with
// `EventsMissed` (serveKept ends the same way), and never sees a gap. The
// model here is a list of what each reader is owed; the Hub is driven by
// seeded publishes, opens, closes and reads, one loop, as metal serves it.

fn same(_: []const u8, _: Alloc, blob: []const u8) ?[]const u8 {
    return blob;
}

/// How often each case was met, over every seed: a simulator that never
/// overflowed a mailbox would prove nothing about it.
var sim_seen: struct { frames: usize = 0, missed: usize = 0, empty: usize = 0, closed: usize = 0 } = .{};

const SimReader = struct {
    sub: *Subscriber,
    key: usize,
    /// Events published on its key since it opened and not yet read.
    owed: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The model's verdict: an event arrived while its mailbox was full.
    overflowed: bool = false,
    /// A slow reader reads on one turn in eight, so its mailbox fills.
    slow: bool = false,
};

fn simRun(seed: u64) !void {
    const keys = [_][]const u8{ "conv/1_2", "conv/1_3", "user/7" };
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var readers: std.ArrayListUnmanaged(SimReader) = .empty;
    defer {
        for (readers.items) |*rd| {
            rd.owed.deinit(testing.allocator);
            hub.close(rd.sub);
        }
        readers.deinit(testing.allocator);
    }
    var seq: usize = 0;
    for (0..r.intRangeAtMost(usize, 50, 400)) |_| {
        switch (r.uintLessThan(u8, 10)) {
            0, 1 => if (readers.items.len < 6) {
                const k = r.uintLessThan(usize, keys.len);
                try readers.append(testing.allocator, .{ .sub = try hub.open(keys[k]), .key = k, .slow = r.uintLessThan(u8, 3) == 0 });
            },
            2 => if (readers.items.len > 0) {
                var rd = readers.swapRemove(r.uintLessThan(usize, readers.items.len));
                rd.owed.deinit(testing.allocator);
                hub.close(rd.sub);
                sim_seen.closed += 1;
            },
            3, 4, 5, 6 => {
                const k = r.uintLessThan(usize, keys.len);
                seq += 1;
                const ev = try std.fmt.allocPrint(arena.allocator(), "{s}#{d}", .{ keys[k], seq });
                for (readers.items) |*rd| {
                    if (rd.key != k or rd.overflowed) continue;
                    if (rd.owed.items.len == Subscriber.cap) rd.overflowed = true else try rd.owed.append(testing.allocator, ev);
                }
                hub.publish(keys[k], ev);
            },
            else => for (readers.items) |*rd| {
                if (rd.slow and r.uintLessThan(u8, 8) != 0) continue;
                for (0..r.uintAtMost(usize, 4)) |_| {
                    const got = nextFrame(.{ .sub = rd.sub, .render = same }, arena.allocator()) catch |e| {
                        try testing.expectEqual(error.EventsMissed, e);
                        try testing.expect(rd.overflowed);
                        sim_seen.missed += 1;
                        break;
                    };
                    const frame = got orelse {
                        // Nothing waiting: the model owes nothing either.
                        try testing.expect(rd.overflowed or rd.owed.items.len == 0);
                        sim_seen.empty += 1;
                        break;
                    };
                    try testing.expect(!rd.overflowed);
                    try testing.expect(rd.owed.items.len > 0);
                    try testing.expectEqualStrings(rd.owed.items[0], frame);
                    _ = rd.owed.orderedRemove(0);
                    sim_seen.frames += 1;
                }
            },
        }
    }
}

test "bus: the mailbox contract over seeded runs (a simulator)" {
    sim_seen = .{};
    for (1..301) |seed| try simRun(seed);
    try testing.expect(sim_seen.frames > 1000 and sim_seen.missed > 10 and sim_seen.empty > 100 and sim_seen.closed > 100);
}
