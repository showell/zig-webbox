//! **A REQUEST'S READS BEFORE THE TURN**, for linux_host.zig: a body read
//! whole into memory under its deadline (body.zig's, from its size) and, for
//! an upload, its stall time; the watchdog that ends a read from outside,
//! which a head's read shares; the upload slots, a human's newer upload
//! taking over their older one (170.1); and the small bodies' budget, charged
//! as their bytes arrive (170.3). linux_host.zig uses it as `linux_reads`.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;
const body_rule = @import("webbox").body;

fn sleepMs(io: Io, ms: u64) Io.Cancelable!void {
    const capped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(capped) }, io);
}

/// The deadlines are body.zig's, sized from the body; a test shortens them
/// by setting this, in milliseconds, for every body.
pub var deadline_for_test_ms: ?u64 = null;

/// A test shortens these, in milliseconds.
pub var stall_for_test_ms: ?u64 = null;
/// A test's own tick for `watch`, in place of a quarter of the deadline (at
/// most 250 ms): a tick longer than the stall puts a takeover in the window
/// where the stall time has passed and the watcher has not yet seen it.
pub var tick_for_test_ms: ?u64 = null;
pub var small_budget_for_test: ?u64 = null;
/// A test's error before the turn, once a body is read: its slot taken or
/// its charge made (metal-vmm QUEUE 176.8).
pub var fail_after_read_for_test: bool = false;

/// How a body's read before the turn ended.
pub const Got = union(enum) {
    whole: []u8,
    too_large,
    unreadable,
    /// Past its deadline.
    too_slow,
    /// An upload with no byte for `body.upload_stall_ms`: a dropped phone.
    stalled,
    /// An upload its human's newer one took the place of.
    replaced,
    /// The small budget is spent.
    busy,
    no_deadline,
};

/// What a read before the turn has received, and what ended it from
/// outside: its deadline, a stall, or its human's newer upload (170.1).
pub const Progress = struct {
    received: std.atomic.Value(u64) = .init(0),
    ended_by: std.atomic.Value(Ended) = .init(.nothing),
    stream: net.Stream,
    io: Io,

    pub const Ended = enum(u8) { nothing, deadline, stalled, replaced };

    /// Ended from outside, once: the socket stops reading, which ends the read.
    pub fn end(self: *Progress, why: Ended) void {
        if (self.ended_by.cmpxchgStrong(.nothing, why, .acq_rel, .acquire) == null)
            self.stream.shutdown(self.io, .recv) catch {};
    }
};

/// The request's body read into memory from `gpa` (its slice left in
/// `owned`, the caller's to free; the head is copied into `arena`), before
/// the turn, and the request left to its handler as if it had not been: the head copied out of the
/// read buffer (a body read reuses it), the body served from memory under
/// a plain Content-Length (and handed over as it is: `http.held_body`).
pub fn readWhole(io: Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, owned: *?[]u8, req: *std.http.Server.Request, plan: body_rule.Read, upload: bool, progress: *Progress, charged: *u64) !Got {
    const head = try arena.dupe(u8, req.head_buffer);
    var whole: Whole = .{ .most = plan.bytes, .progress = progress, .small = !upload, .charged = charged, .gpa = gpa };
    // The body's memory, the caller's to free when the request is done,
    // whatever came of the read.
    defer if (whole.list.capacity > 0) {
        owned.* = whole.list.allocatedSlice();
    };
    {
        // The read and its watchdog, whichever ends first. **EVERY TASK IS
        // AWAITED BEFORE THIS FRAME ENDS** (metal-vmm QUEUE 167.1):
        // `cancelDiscard` waits for both, however the race went, and only
        // then is the read's state looked at.
        var buffer: [2]Raced = undefined;
        var race: Io.Select(Raced) = .init(io, &buffer);
        race.concurrent(.read, Whole.read, .{ &whole, req }) catch return .no_deadline;
        const stall: ?u64 = if (upload) stall_for_test_ms orelse body_rule.upload_stall_ms else null;
        race.concurrent(.watch, watch, .{ io, progress, deadline_for_test_ms orelse plan.deadline_ms, stall }) catch {
            // No deadline to read under: the read is ended, not left to run.
            progress.end(.deadline);
            race.cancelDiscard();
            return .no_deadline;
        };
        _ = race.await() catch |e| {
            progress.end(.deadline);
            race.cancelDiscard();
            return e;
        };
        race.cancelDiscard();
    }
    const own: Got = switch (whole.state) {
        .read => |b| .{ .whole = b },
        .reading => unreachable, // both tasks are done
        .too_large => .too_large,
        .busy => .busy,
        .unreadable => .unreadable,
    };
    const got = verdict(own, progress.ended_by.load(.acquire));
    const body = switch (got) {
        .whole => |b| b,
        else => return got,
    };
    // The head again, from its copy; the body, from memory.
    req.head_buffer = head;
    req.head = std.http.Server.Request.Head.parse(head) catch return error.HttpHeadersInvalid;
    req.head.transfer_encoding = .none;
    req.head.content_length = body.len;
    req.head.expect = null;
    const from_memory = try arena.create(std.Io.Reader);
    from_memory.* = .fixed(body);
    req.server.reader.in = from_memory;
    req.server.reader.state = .received_head;
    return got;
}

pub const Raced = union(enum) { read: void, watch: void };

/// **A READ IS NAMED BY HOW IT ENDED** (170.7): whole is whole, whatever
/// fired beside it; one ended from outside by why; else its own end (too
/// large, unreadable, the budget), never a 408 for one that was not late.
/// An unreadable end is the shut socket's when something outside shut it.
pub fn verdict(own: Got, ended_by: Progress.Ended) Got {
    if (own != .unreadable) return own;
    return switch (ended_by) {
        .nothing => .unreadable,
        .deadline => .too_slow,
        .stalled => .stalled,
        .replaced => .replaced,
    };
}

/// The read's watchdog: past `deadline_ms`, or (an upload) with nothing
/// received for `stall_ms`, it ends the read; ended from outside (a newer
/// upload), it is done. Cancelled when the read ends first.
pub fn watch(io: Io, progress: *Progress, deadline_ms: u64, stall_ms: ?u64) void {
    const tick: u64 = tick_for_test_ms orelse @min(250, @max(1, deadline_ms / 4));
    var waited: u64 = 0;
    var quiet: u64 = 0;
    var seen = progress.received.load(.acquire);
    while (true) {
        sleepMs(io, tick) catch return;
        waited += tick;
        if (progress.ended_by.load(.acquire) != .nothing) return;
        if (waited >= deadline_ms) return progress.end(.deadline);
        const now = progress.received.load(.acquire);
        if (now != seen) {
            seen = now;
            quiet = 0;
        } else quiet += tick;
        if (stall_ms) |most| if (quiet >= most) return progress.end(.stalled);
    }
}

/// **A STRANGER'S UPLOAD IS NEVER READ** (body.zig): its route sees an empty
/// body under the head's own framing, so a read of it fails (400), and the
/// route refuses a stranger before reading anyway. Never told to send it.
pub fn neverRead(req: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const empty = try arena.create(std.Io.Reader);
    empty.* = .fixed("");
    req.server.reader.in = empty;
    req.head.expect = null;
    // Its body is still on the socket: the connection's last request.
    req.head.keep_alive = false;
}

/// The host's upload slots (body.zig), who reads in each, and their lock:
/// connections take and give back from their own tasks.
pub var slots: body_rule.Slots = .{};
var slot_readers: [body_rule.upload_slots]?*Progress = @splat(null);
/// When each slot's upload asked for it, in order (`nextAsk`): of a human's
/// uploads, the one that asked last is the retry (metal-vmm QUEUE 171's
/// simulator: two retries waiting took the slot from each other).
var slot_asked: [body_rule.upload_slots]u64 = @splat(0);
var asks: u64 = 0;

pub fn nextAsk(io: Io) u64 {
    slots_lock.lockUncancelable(io);
    defer slots_lock.unlock(io);
    asks += 1;
    return asks;
}

const Taken = union(enum) { slot: usize, busy, replaced };
var slots_lock: Io.Mutex = .init;

/// How long an uploader waits for a slot; a test shortens it.
pub var slot_wait_for_test_ms: ?u64 = null;

/// A slot for `who`, waiting on this connection's own task for one to come
/// free, at most `body.slot_wait_ms`; null past that. **A HUMAN'S NEW UPLOAD
/// TAKES OVER THEIR OLD ONE** (170.1): the page uploads one at a time, so a
/// second is a retry, its first most likely a dropped phone's; the first is
/// ended (409), its slot given back, and taken here.
pub fn takeSlot(io: Io, who: u64, progress: *Progress, asked: u64) Taken {
    const most = slot_wait_for_test_ms orelse body_rule.slot_wait_ms;
    var waited: u64 = 0;
    while (true) : (waited += 50) {
        slots_lock.lockUncancelable(io);
        const taken = slots.take(who);
        switch (taken) {
            .slot => |i| {
                slot_readers[i] = progress;
                slot_asked[i] = asked;
            },
            // A newer upload of theirs holds the slot: this is the stale
            // retry, told 409; an older one there is taken over.
            .human_has_one => if (slots.heldBy(who)) |i| {
                if (slot_asked[i] > asked) {
                    slots_lock.unlock(io);
                    return .replaced;
                }
                if (slot_readers[i]) |old| old.end(.replaced);
            },
            .all_busy => {},
        }
        slots_lock.unlock(io);
        switch (taken) {
            .slot => |i| return .{ .slot = i },
            .all_busy, .human_has_one => if (waited >= most) return .busy,
        }
        sleepMs(io, 50) catch return .busy;
    }
}

pub fn readDone(io: Io, i: usize) void {
    slots_lock.lockUncancelable(io);
    defer slots_lock.unlock(io);
    slot_readers[i] = null;
}

pub fn giveBackSlot(io: Io, i: usize) void {
    slots_lock.lockUncancelable(io);
    defer slots_lock.unlock(io);
    slots.giveBack(i);
    slot_readers[i] = null;
}

/// Small bodies' bytes held now, against `body.small_budget` (170.3).
pub var small_held: u64 = 0;
var small_lock: Io.Mutex = .init;

fn chargeSmall(io: Io, n: u64) bool {
    small_lock.lockUncancelable(io);
    defer small_lock.unlock(io);
    const budget = small_budget_for_test orelse body_rule.small_budget;
    if (small_held + n > budget) return false;
    small_held += n;
    return true;
}

pub fn unchargeSmall(io: Io, n: u64) void {
    if (n == 0) return;
    small_lock.lockUncancelable(io);
    defer small_lock.unlock(io);
    small_held -= n;
}

/// A body being read whole, a few KiB a read so its progress is seen, and
/// how its read ended.
pub const Whole = struct {
    /// The most it may be (its Content-Length, or the route's cap).
    most: u64,
    progress: *Progress,
    /// A small body, charged to the small budget as its bytes arrive.
    small: bool,
    charged: *u64,
    /// **THE BODY'S MEMORY IS ITS OWN, NOT THE ARENA'S** (metal-vmm QUEUE
    /// 177.2): an arena frees or grows in place only its newest allocation
    /// in a node, so a list that outgrew its node left its old copy behind
    /// (1.5-4.5x what was charged). This allocator frees what a growth
    /// leaves; the caller frees the list itself when the request is done.
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    state: union(enum) { reading, read: []u8, too_large, unreadable, busy } = .reading,

    pub fn read(self: *Whole, req: *std.http.Server.Request) void {
        // Memory that runs out is the host's busy (503, the client may try
        // again), never the client's unreadable body (metal-vmm QUEUE 172).
        self.state = self.readAll(req) catch |e| switch (e) {
            error.OutOfMemory => .busy,
            else => .unreadable,
        };
    }

    pub fn readAll(self: *Whole, req: *std.http.Server.Request) !@FieldType(Whole, "state") {
        var transfer: [4096]u8 = undefined;
        const declared = req.head.content_length;
        const r = try req.readerExpectContinue(&transfer);
        const list = &self.list;
        // An upload's exact length at once (its slot is its bound); a small
        // body grows as it comes, a silent one holding nothing (170.3).
        if (!self.small) if (declared) |n| try list.ensureTotalCapacityPrecise(self.gpa, @intCast(n));
        var chunk: [4096]u8 = undefined;
        while (true) {
            const room = if (declared) |n| @min(chunk.len, n - list.items.len) else chunk.len;
            if (room == 0) break;
            // **WHAT HAS ARRIVED, AS IT ARRIVES** (metal-vmm QUEUE 176.7): a
            // read that waited to fill 4 KiB made a 100 B/s link a stall.
            var bufs: [1][]u8 = .{chunk[0..room]};
            const got = r.readVec(&bufs) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return .unreadable,
            };
            if (got == 0) continue; // filled the reader's own buffer: read again
            const need = list.items.len + got;
            if (need > self.most) return .too_large;
            if (self.small and need > list.capacity) {
                // **THE CHARGE IS WHAT IS HELD** (176.5, 177.2, 180.6): the
                // room is charged before it is taken, grown by half (never
                // past the body's most), so a 1 MiB body is some 30 growths,
                // not 256. While a growth copies, the old room is beside the
                // new one, so the new room is charged whole first, and the
                // old room's charge given back once the growth is done.
                const room_now: u64 = list.capacity;
                const grown: u64 = @min(self.most, @max(need, room_now + room_now / 2));
                if (!chargeSmall(self.progress.io, grown)) return .busy;
                list.ensureTotalCapacityPrecise(self.gpa, @intCast(grown)) catch |e| {
                    unchargeSmall(self.progress.io, grown);
                    return e;
                };
                unchargeSmall(self.progress.io, room_now);
                self.charged.* += grown - room_now;
            }
            try list.appendSlice(self.gpa, chunk[0..got]);
            _ = self.progress.received.fetchAdd(got, .acq_rel);
        }
        // std ends a Content-Length body at the connection's end, short and
        // silent: that is no body (http.readLimitedBody says why).
        if (declared) |n| if (list.items.len != n) return .unreadable;
        return .{ .read = list.items };
    }
};
