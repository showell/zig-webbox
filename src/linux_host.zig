//! linux_host: a site served as a Linux process. Part of the `webbox`
//! library's Linux half (`webbox_linux`): sockets, a thread pool, the
//! environment, /proc. Nothing the site reaches imports it (the portability
//! lint holds that); an application calls it from its `main`, and a machine
//! with no operating system replaces all of it while calling the same `start`
//! and `route`. It reaches the portable half as the `webbox` module.
//!
//! `Server(S).run` is the whole of it, in one order: the allocator (the
//! memory meter over the page allocator), the environment, the config file,
//! the site's `start`, the application's report, the keepalive, the bind, the
//! listener, then one task per connection, forever.
//!
//! Concurrency: each accepted connection runs as its own task on the std.Io
//! thread pool (a never-awaited Io.Group + group.concurrent). The pool grows
//! on demand and finished tasks self-reap, so it's effectively
//! goroutine-per-connection: connections are accepted, read and written at
//! once, and a kept stream is served on its own task (bus.zig). **But only
//! one handler runs at a time** (`turn`): the route table runs as it does on
//! the bare-metal host's single loop, so the two hosts are one machine
//! (Steve, 2026-10-07). Each connection serves ONE request then closes
//! (keep-alive off): see handleConn.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;
const mem_meter = @import("webbox").mem_meter;
const bind = @import("bind.zig");
const bus = @import("webbox").bus;
const edge = @import("webbox").edge;
const http = @import("webbox").http;
const body_rule = @import("webbox").body;
const host_facts = @import("webbox").host_facts;
const free_space = @import("webbox").free_space;
const linux_config = @import("linux_config.zig");

/// The environment variables a host reads, named whole by the application,
/// so a search for one finds where it is read.
pub const Env = struct {
    /// The port; unset, or not a port, is `Options.default_port`.
    port: []const u8,
    /// The address to listen on (bind.zig); unset is every interface, and one
    /// that will not parse stops the host.
    bind: []const u8,
    /// The config file's path (linux_config.zig).
    config: []const u8,
    /// The reverse proxy whose X-Forwarded-For is believed.
    trusted_proxy: []const u8,
    /// A quiet stream's ping window, for tests (bus.zig's keepaliveSetting).
    keepalive_ms: []const u8,
};

pub const Options = struct {
    /// What the host calls itself in its log and its facts.
    name: []const u8,
    env: Env,
    default_port: u16,
    /// The trusted proxy when its variable is unset.
    default_trusted_proxy: []const u8,
    /// The config's `auth_dir` when the file names none.
    default_auth_dir: []const u8,
    /// What the listening line says after the address: the surfaces served.
    routes_hint: []const u8,
    /// How the data volume's free space is read, given the environment (an
    /// application may have a setting of its own for it, and say so).
    free_space: *const fn (env: *const std.process.Environ.Map) free_space.FreeSpace,
};

/// `S` is a site (site.zig's `Site(App)`, or a namespace that re-exports one):
/// `start`, `route`, `Started`.
pub fn Server(comptime S: type) type {
    inline for (.{ "start", "route", "Started", "bodyLimit" }) |name| {
        if (!@hasDecl(S, name)) @compileError("linux_host.Server takes a site, which declares " ++ name ++ " (site.zig)");
    }
    return struct {
        /// Serves the site until the process ends. `report` says what the
        /// application's setup did, in its own words, before the listener
        /// opens.
        pub fn run(init: std.process.Init.Minimal, comptime options: Options, report: *const fn (started: *const S.Started) void) !void {
            // The metered allocator wraps page_allocator and counts live
            // bytes and allocations: the process base allocator, so
            // everything downstream (the IO pool, the bus, the per-request
            // arenas) allocates through it, and the meter sees the whole
            // leakable surface.
            const alloc = mem_meter.init(std.heap.page_allocator);
            var threaded = std.Io.Threaded.init(alloc, .{ .environ = init.environ });
            defer threaded.deinit();
            const io = threaded.io();

            // (0.16 routes the OS environment through main's Init, not a
            // global.)
            var env = try std.process.Environ.createMap(init.environ, alloc);
            defer env.deinit();
            host_name = options.name;
            started_unix = nowUnix(io);
            const space = options.free_space(&env);
            var started = try S.start(io, .{
                .roots = try linux_config.load(io, alloc, env, options.env.config, options.default_auth_dir),
                .free_space = space,
                .trusted_proxy = env.get(options.env.trusted_proxy) orelse options.default_trusted_proxy,
                .facts = linuxFacts,
            });
            report(&started);
            // The pub/sub fan-out shared across all connections, for the
            // process's lifetime. Each request gets its own handle on it (a
            // Bus), which is where a stream handler leaves the stream it
            // kept.
            const hub = &started.hub;

            if (bus.keepaliveSetting(env.get(options.env.keepalive_ms)) catch |e| {
                std.debug.print("{s}: {s}={s} is not a number of milliseconds above zero; not starting\n", .{ options.name, options.env.keepalive_ms, env.get(options.env.keepalive_ms) orelse "" });
                return e;
            }) |ms| {
                bus.Subscriber.keepalive_ms = ms;
                std.debug.print("{s}: {s}={d}: a quiet stream pings after {d} ms\n", .{ options.name, options.env.keepalive_ms, ms, ms });
            }

            const port = portFrom(env.get(options.env.port), options.default_port);
            const addr = bind.address(env.get(options.env.bind), port) catch |e| {
                std.debug.print("{s}: {s}={s} is not an IP address; not starting\n", .{ options.name, options.env.bind, env.get(options.env.bind) orelse "" });
                return e;
            };
            var listener = try addr.listen(io, .{ .reuse_address = true });
            defer listener.deinit(io);

            std.debug.print("{s}: http://localhost:{d}, bound to {f}  {s}\n", .{ options.name, port, addr, options.routes_hint });

            // Each connection becomes a concurrent task in this group. It is
            // never awaited: the server runs forever and completed tasks
            // self-reap.
            var conns: Io.Group = .init;
            while (true) {
                const stream = listener.accept(io) catch |e| {
                    std.debug.print("accept failed: {s}\n", .{@errorName(e)});
                    continue;
                };
                conns.concurrent(io, serveConn, .{ io, alloc, hub, stream }) catch |e| {
                    // **NO TASK, NO SERVING** (metal-vmm QUEUE 167.4): served
                    // inline, its head and body would be read with no
                    // deadline, holding the accept loop. A 503, and closed.
                    std.debug.print("spawn failed ({s}); answered 503\n", .{@errorName(e)});
                    busy(io, stream);
                };
            }
        }

        /// The body of `req` read whole into memory before the turn, by the
        /// rule (body.zig), or the refusal to answer instead. An upload is
        /// read once its uploader is known (a stranger's never) and holds a
        /// slot; a small one is charged to the small budget as it arrives.
        fn bodyBeforeTurn(io: Io, arena: std.mem.Allocator, req: *std.http.Server.Request, progress: *Progress, slot: *?usize, held: *?[]u8, charged: *u64) !?Refusal {
            const cap = S.bodyLimit(try http.target(req, arena));
            const read: body_rule.Read, const upload = switch (body_rule.plan(&req.head, cap)) {
                .none => return null,
                .refused => |r| return switch (r) {
                    .too_large => .{ .kind = .body_too_large, .msg = "request body too large\n" },
                    .framed_twice => .{ .kind = .body_framed_twice, .msg = "request body framed twice\n" },
                    .length_required => .{ .kind = .body_length_required, .msg = "an upload says its length\n" },
                    .expectation_failed => .{ .kind = .body_expectation_failed, .msg = "only 100-continue is met\n" },
                },
                .small => |r| .{ r, false },
                .upload => |r| .{ r, true },
            };
            if (upload) {
                const who = (try S.uploader(req, io, arena)) orelse {
                    try neverRead(req, arena);
                    return null;
                };
                slot.* = takeSlot(io, body_rule.keyOf(who), progress) orelse
                    return .{ .kind = .uploads_busy, .msg = "Uploads are busy; try again in a minute.\n" };
            }
            const began = Io.Clock.now(.awake, io);
            const length = req.head.content_length orelse 0;
            const got = try readWhole(io, arena, req, read, upload, progress, charged);
            // Read: nothing left to take over (a newer upload now waits for
            // this one's slot, which comes back when its request is done).
            if (slot.*) |i| readDone(io, i);
            if (upload) {
                // **THE LOG SAYS AN UPLOAD'S SIZE AND ITS TIME** (169),
                // whole or not, so a slow link is read, not inferred.
                const ms = @divTrunc(Io.Clock.now(.awake, io).nanoseconds - began.nanoseconds, std.time.ns_per_ms);
                if (!@import("builtin").is_test) std.debug.print("{s}: an upload of {d} bytes: {t}, {d} received, after {d} ms\n", .{ host_name, length, got, progress.received.load(.acquire), ms });
            }
            return switch (got) {
                .whole => |b| blk: {
                    held.* = b;
                    break :blk null;
                },
                .too_large => .{ .kind = .body_too_large, .msg = "request body too large\n" },
                .unreadable => .{ .kind = .body_unreadable, .msg = "read body\n" },
                .too_slow => .{ .kind = .body_too_slow, .msg = "request body too slow\n" },
                .stalled => .{ .kind = .body_too_slow, .msg = "the upload stalled\n" },
                .replaced => .{ .kind = .upload_replaced, .msg = "a newer upload took this one's place\n" },
                .busy => .{ .kind = .uploads_busy, .msg = "busy; try again in a minute\n" },
                .no_deadline => .{ .kind = .no_deadline, .msg = "busy; try again\n" },
            };
        }

        /// serveConn is the per-connection task body. It returns void
        /// (swallowing all errors) so it coerces to the Cancelable!void that
        /// Io.Group requires.
        fn serveConn(io: std.Io, alloc: std.mem.Allocator, hub: *bus.Hub, stream: net.Stream) void {
            // absent-ok: the connection's own task: the error is logged, and the connection closes without an answer.
            handleConn(io, alloc, hub, stream) catch |e| {
                std.debug.print("connection error: {s}\n", .{@errorName(e)});
            };
        }

        /// handleConn serves exactly ONE request, then closes the connection
        /// (`connection: close`). Keep-alive is OFF: the bare-metal host
        /// serves one request per connection too, so the two hosts answer
        /// alike.
        fn handleConn(io: std.Io, alloc: std.mem.Allocator, hub: *bus.Hub, stream: net.Stream) !void {
            defer stream.close(io);

            var read_buf: [http.head_bytes]u8 = undefined; // must hold the full request header
            var write_buf: [64 * 1024]u8 = undefined;
            var sr = stream.reader(io, &read_buf);
            var sw = stream.writer(io, &write_buf);
            var server = std.http.Server.init(&sr.interface, &sw.interface);

            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            var req = server.receiveHead() catch |e| switch (e) {
                error.HttpConnectionClosing => return,
                // A request head larger than read_buf. Count it (the
                // guaranteed observable) and best-effort a 431 before
                // closing. The reader/writer may be mid-stream after an
                // oversize head, so the raw write is swallowed on failure —
                // the count is the part we rely on.
                error.HttpHeadersOversize => {
                    edge.count(.header_too_large);
                    sw.interface.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                        "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
                    sw.interface.flush() catch {};
                    return;
                },
                else => return e,
            };
            // **THE TURN NEVER WAITS ON THE NETWORK** (webbox's body.zig,
            // metal-vmm QUEUE 169, 170): every body is read whole, here,
            // before the turn. A small one within its deadline; an upload
            // once its uploader is known and has a slot, within five
            // minutes and never stalled for long. A stranger's upload is
            // never read, and its route refuses it.
            // **THE READ'S STATE LIVES AS LONG AS THE CONNECTION** (170's
            // cold review): a slot's reader is named by a pointer to it, and
            // the slot is given back only when the request is done.
            var progress: Progress = .{ .stream = stream, .io = io };
            var slot: ?usize = null;
            defer if (slot) |i| giveBackSlot(io, i);
            var held_body: ?[]u8 = null;
            var charged: u64 = 0;
            defer unchargeSmall(io, charged);
            // **AN ERROR BEFORE THE TURN IS ANSWERED** (170.6): a 500, as
            // one in the turn is, never a close with no answer.
            const refusal = bodyBeforeTurn(io, arena.allocator(), &req, &progress, &slot, &held_body, &charged) catch |e| {
                if (!@import("builtin").is_test) std.debug.print("{s}: before the turn: {s}\n", .{ host_name, @errorName(e) });
                req.head.keep_alive = false;
                req.head.expect = null;
                req.respond("The server failed before it could answer.\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
                return;
            };
            if (refusal) |r| return refuse(&req, r.kind, r.msg);
            req.head.keep_alive = false; // force `connection: close` without touching each handler
            var b = bus.Bus.of(hub);
            var peer_buf: [64]u8 = undefined;
            b.peer = peerText(&peer_buf, stream.socket.address);
            turn.lockUncancelable(io);
            // The body read before the turn, handed to the handler's read
            // as it is (170.5: an upload in memory once, not twice).
            http.held_body = held_body;
            const routed = S.route(&req, io, arena.allocator(), &b);
            http.held_body = null;
            turn.unlock(io);
            // A stream the handler kept is route's answer, served here, on
            // this connection's own task, until its client goes away; on an
            // error route has dropped it (metal-vmm QUEUE 157(a)).
            if (try routed) |kept| bus.serveKept(hub, kept, &sw.interface);
        }
    };
}

/// A connection there is no task to serve: a 503 written straight to it (a
/// few bytes, which the socket's own buffer takes), and closed.
fn busy(io: Io, stream: net.Stream) void {
    defer stream.close(io);
    edge.count(.no_deadline);
    var w = stream.writer(io, &.{});
    w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
}

/// The deadlines are body.zig's, sized from the body; a test shortens them
/// by setting this, in milliseconds, for every body.
pub var deadline_for_test_ms: ?u64 = null;

/// A test shortens these, in milliseconds.
pub var stall_for_test_ms: ?u64 = null;
pub var small_budget_for_test: ?u64 = null;

const Refusal = struct { kind: edge.RejectKind, msg: []const u8 };

/// How a body's read before the turn ended.
const Got = union(enum) {
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
const Progress = struct {
    received: std.atomic.Value(u64) = .init(0),
    ended_by: std.atomic.Value(Ended) = .init(.nothing),
    stream: net.Stream,
    io: Io,

    const Ended = enum(u8) { nothing, deadline, stalled, replaced };

    /// Ended from outside, once: the socket stops reading, which ends the read.
    fn end(self: *Progress, why: Ended) void {
        if (self.ended_by.cmpxchgStrong(.nothing, why, .acq_rel, .acquire) == null)
            self.stream.shutdown(self.io, .recv) catch {};
    }
};

/// The request's body read into `arena`, before the turn, and the request
/// left to its handler as if it had not been: the head copied out of the
/// read buffer (a body read reuses it), the body served from memory under
/// a plain Content-Length (and handed over as it is: `http.held_body`).
fn readWhole(io: Io, arena: std.mem.Allocator, req: *std.http.Server.Request, plan: body_rule.Read, upload: bool, progress: *Progress, charged: *u64) !Got {
    const head = try arena.dupe(u8, req.head_buffer);
    var whole: Whole = .{ .most = plan.bytes, .progress = progress, .small = !upload, .charged = charged };
    {
        // The read and its watchdog, whichever ends first. **EVERY TASK IS
        // AWAITED BEFORE THIS FRAME ENDS** (metal-vmm QUEUE 167.1):
        // `cancelDiscard` waits for both, however the race went, and only
        // then is the read's state looked at.
        var buffer: [2]Raced = undefined;
        var race: Io.Select(Raced) = .init(io, &buffer);
        race.concurrent(.read, Whole.read, .{ &whole, req, arena }) catch return .no_deadline;
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
    // **A READ IS NAMED BY HOW IT ENDED** (170.7): whole is whole, whatever
    // fired beside it; one ended from outside by why; else its own end (too
    // large, unreadable, the budget), never a 408 for one that was not late.
    const own: Got = switch (whole.state) {
        .read => |b| .{ .whole = b },
        .reading => unreachable, // both tasks are done
        .too_large => .too_large,
        .busy => .busy,
        .unreadable => .unreadable,
    };
    // An unreadable end is the shut socket's when something outside shut it.
    const got: Got = if (own != .unreadable) own else switch (progress.ended_by.load(.acquire)) {
        .nothing => .unreadable,
        .deadline => .too_slow,
        .stalled => .stalled,
        .replaced => .replaced,
    };
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

const Raced = union(enum) { read: void, watch: void };

/// A request refused before the turn, its connection closed after: what of
/// its body is unread stays unread. The answer is best-effort, as the
/// client may be gone.
fn refuse(req: *std.http.Server.Request, kind: edge.RejectKind, msg: []const u8) void {
    req.head.keep_alive = false;
    edge.reject(req, kind, msg) catch {};
}

fn sleepMs(io: Io, ms: u64) Io.Cancelable!void {
    const capped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(capped) }, io);
}

/// The read's watchdog: past `deadline_ms`, or (an upload) with nothing
/// received for `stall_ms`, it ends the read; ended from outside (a newer
/// upload), it is done. Cancelled when the read ends first.
fn watch(io: Io, progress: *Progress, deadline_ms: u64, stall_ms: ?u64) void {
    const tick: u64 = @min(250, @max(1, deadline_ms / 4));
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
fn neverRead(req: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const empty = try arena.create(std.Io.Reader);
    empty.* = .fixed("");
    req.server.reader.in = empty;
    req.head.expect = null;
}

/// The host's upload slots (body.zig), who reads in each, and their lock:
/// connections take and give back from their own tasks.
var slots: body_rule.Slots = .{};
var slot_readers: [body_rule.upload_slots]?*Progress = @splat(null);
var slots_lock: Io.Mutex = .init;

/// How long an uploader waits for a slot; a test shortens it.
pub var slot_wait_for_test_ms: ?u64 = null;

/// A slot for `who`, waiting on this connection's own task for one to come
/// free, at most `body.slot_wait_ms`; null past that. **A HUMAN'S NEW UPLOAD
/// TAKES OVER THEIR OLD ONE** (170.1): the page uploads one at a time, so a
/// second is a retry, its first most likely a dropped phone's; the first is
/// ended (409), its slot given back, and taken here.
fn takeSlot(io: Io, who: u64, progress: *Progress) ?usize {
    const most = slot_wait_for_test_ms orelse body_rule.slot_wait_ms;
    var waited: u64 = 0;
    while (true) : (waited += 50) {
        slots_lock.lockUncancelable(io);
        const taken = slots.take(who);
        switch (taken) {
            .slot => |i| slot_readers[i] = progress,
            .human_has_one => if (slots.heldBy(who)) |i| if (slot_readers[i]) |old| old.end(.replaced),
            .all_busy => {},
        }
        slots_lock.unlock(io);
        switch (taken) {
            .slot => |i| return i,
            .all_busy, .human_has_one => if (waited >= most) return null,
        }
        sleepMs(io, 50) catch return null;
    }
}

fn readDone(io: Io, i: usize) void {
    slots_lock.lockUncancelable(io);
    defer slots_lock.unlock(io);
    slot_readers[i] = null;
}

fn giveBackSlot(io: Io, i: usize) void {
    slots_lock.lockUncancelable(io);
    defer slots_lock.unlock(io);
    slots.giveBack(i);
    slot_readers[i] = null;
}

/// Small bodies' bytes held now, against `body.small_budget` (170.3).
var small_held: u64 = 0;
var small_lock: Io.Mutex = .init;

fn chargeSmall(io: Io, n: u64) bool {
    small_lock.lockUncancelable(io);
    defer small_lock.unlock(io);
    const budget = small_budget_for_test orelse body_rule.small_budget;
    if (small_held + n > budget) return false;
    small_held += n;
    return true;
}

fn unchargeSmall(io: Io, n: u64) void {
    if (n == 0) return;
    small_lock.lockUncancelable(io);
    defer small_lock.unlock(io);
    small_held -= n;
}

/// A body being read whole, a few KiB a read so its progress is seen, and
/// how its read ended.
const Whole = struct {
    /// The most it may be (its Content-Length, or the route's cap).
    most: u64,
    progress: *Progress,
    /// A small body, charged to the small budget as its bytes arrive.
    small: bool,
    charged: *u64,
    state: union(enum) { reading, read: []u8, too_large, unreadable, busy } = .reading,

    fn read(self: *Whole, req: *std.http.Server.Request, arena: std.mem.Allocator) void {
        self.state = self.readAll(req, arena) catch .unreadable;
    }

    fn readAll(self: *Whole, req: *std.http.Server.Request, arena: std.mem.Allocator) !@FieldType(Whole, "state") {
        var transfer: [4096]u8 = undefined;
        const declared = req.head.content_length;
        const r = try req.readerExpectContinue(&transfer);
        // A Content-Length body has its memory once, exactly; a chunked one
        // (small only) grows as it comes.
        var list: std.ArrayList(u8) = .empty;
        // An upload's exact length at once (its slot is its bound); a small
        // body grows as it comes, a silent one holding nothing (170.3).
        if (!self.small) if (declared) |n| try list.ensureTotalCapacityPrecise(arena, @intCast(n));
        var chunk: [4096]u8 = undefined;
        while (true) {
            const room = if (declared) |n| @min(chunk.len, n - list.items.len) else chunk.len;
            if (room == 0) break;
            const got = r.readSliceShort(chunk[0..room]) catch return .unreadable;
            if (got == 0) break;
            if (list.items.len + got > self.most) return .too_large;
            if (self.small) {
                if (!chargeSmall(self.progress.io, got)) return .busy;
                self.charged.* += got;
            }
            try list.appendSlice(arena, chunk[0..got]);
            _ = self.progress.received.fetchAdd(got, .acq_rel);
        }
        // std ends a Content-Length body at the connection's end, short and
        // silent: that is no body (http.readLimitedBody says why).
        if (declared) |n| if (list.items.len != n) return .unreadable;
        return .{ .read = list.items };
    }
};

/// **ONE HANDLER AT A TIME**: held while `route` runs, so no two handlers
/// interleave, as on the bare-metal host, where one loop runs each to its
/// end. Reading the head and the body comes before it, and serving a kept
/// stream after it, so a slow client holds up nobody but itself. One per
/// process.
var turn: Io.Mutex = .init;

/// The port in the variable's text, or `default` when it is unset or is not a
/// port. A port override is load-bearing for running more than one server at
/// once (a test's server on a side port beside the development one).
fn portFrom(text: ?[]const u8, default: u16) u16 {
    const s = text orelse return default;
    return std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch default;
}

/// The connection's address as text with no port (`203.0.113.7`,
/// `2001:db8::1`): the peer a request's Bus carries (client_address.zig).
fn peerText(buf: []u8, a: net.IpAddress) ?[]const u8 {
    switch (a) {
        .ip4 => |v| return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ v.bytes[0], v.bytes[1], v.bytes[2], v.bytes[3] }) catch null,
        .ip6 => {
            const t = std.fmt.bufPrint(buf, "{f}", .{a}) catch return null; // "[addr]:port"
            const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
            if (t.len == 0 or t[0] != '[') return null;
            return t[1..close];
        },
    }
}

// ── the free space of the volume a path is on ────────────────────────────────

/// statfs(2)'s answer, as the kernel lays it out on a 64-bit machine. std has
/// no statfs, so it is asked directly.
const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

/// Free (to an unprivileged writer) and total bytes on the volume `path` is
/// on; null when statfs will not say. What an application's free-space reader
/// asks, at the folder its policy is about.
pub fn freeSpaceAt(path: []const u8) ?free_space.Space {
    if (@import("builtin").os.tag != .linux or @sizeOf(usize) != 8) return null;
    const linux = std.os.linux;
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    var st: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&z), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS or st.bsize <= 0) return null;
    const bsize: u64 = @intCast(st.bsize);
    return .{ .free = st.bavail * bsize, .total = st.blocks * bsize };
}

// ── the host's facts: what this Linux process says about itself ──────────────

var host_name: []const u8 = "";
var started_unix: i64 = 0;

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

/// This process's facts. Memory is the kernel's own account of it
/// (/proc/self/status), which is the whole process, not just what the meter
/// sees.
fn linuxFacts(io: Io, alloc: std.mem.Allocator) anyerror![]const host_facts.Fact {
    var facts: std.ArrayList(host_facts.Fact) = .empty;
    try facts.append(alloc, .{ .label = "host", .value = try std.fmt.allocPrint(alloc, "Linux, {s}, pid {d}", .{ host_name, std.os.linux.getpid() }) });
    try facts.append(alloc, .{ .label = "started", .value = try host_facts.utc(alloc, started_unix) });
    try facts.append(alloc, .{ .label = "up for", .value = try host_facts.duration(alloc, nowUnix(io) - started_unix) });
    try facts.append(alloc, .{ .label = "data directory", .value = linux_config.data_dir_shown });
    const status = readProcFile(alloc, "/proc/self/status") catch |e| {
        try facts.append(alloc, .{ .label = "memory", .value = try std.fmt.allocPrint(alloc, "/proc/self/status: {s}", .{@errorName(e)}) });
        return facts.items;
    };
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const label: []const u8 = if (std.mem.startsWith(u8, line, "VmRSS:"))
            "memory now (resident)"
        else if (std.mem.startsWith(u8, line, "VmHWM:"))
            "memory at most (resident)"
        else
            continue;
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        try facts.append(alloc, .{ .label = label, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") });
    }
    return facts.items;
}

/// A /proc file, read to its end. Not `readFileAlloc`: /proc files say their
/// size is zero, and a read sized by that comes back empty.
fn readProcFile(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const linux = std.os.linux;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) return out.items;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

test "portFrom: the variable's port, or the default when it is unset or not a port" {
    try std.testing.expectEqual(@as(u16, 9001), portFrom(null, 9001));
    try std.testing.expectEqual(@as(u16, 8080), portFrom(" 8080\n", 9001));
    try std.testing.expectEqual(@as(u16, 9001), portFrom("/home/x/build/port", 9001));
    try std.testing.expectEqual(@as(u16, 9001), portFrom("70000", 9001));
}

// ── a held body holds only its own connection: the turn never waits on the
// network (metal-vmm QUEUE 162, 166, 167, 169) ─────────────────────────────

/// A site for the host's own tests: `GET /` answers "ok", and a POST reads its
/// body (as a handler does, inside the turn) and answers its length. Its caps:
/// `/tiny` 4 bytes, `/upload` and `/refuses` past `body_rule.before_turn_most`
/// (uploads), anything else 64 KiB. Its uploader is the `x-who` header; an
/// upload without one is a stranger's, which `/upload` answers 401 unread.
const TestSite = struct {
    pub const Started = struct {};
    pub fn start(_: Io, _: anytype) !Started {
        return .{};
    }
    pub fn bodyLimit(target: []const u8) u64 {
        if (std.mem.eql(u8, target, "/tiny")) return 4;
        if (std.mem.eql(u8, target, "/upload")) return 4 * body_rule.before_turn_most;
        if (std.mem.eql(u8, target, "/refuses")) return 4 * body_rule.before_turn_most;
        return 64 * 1024;
    }
    pub fn uploader(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator) !?[]const u8 {
        const who = try http.header(req, alloc, "x-who");
        if (who) |w| if (std.mem.eql(u8, w, "boom")) return error.StoreUnreadable;
        return who;
    }
    pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *bus.Bus) !?bus.Kept {
        if (std.mem.eql(u8, try http.target(req, alloc), "/upload") and try uploader(req, io, alloc) == null) {
            try req.respond("who are you?\n", .{ .status = .unauthorized, .keep_alive = false });
            return null;
        }
        // A handler that refuses an upload without reading it.
        if (std.mem.eql(u8, try http.target(req, alloc), "/refuses")) {
            try http.redirect(req, "/login");
            return null;
        }
        if (req.head.method == .POST) {
            const cap = bodyLimit(try http.target(req, alloc));
            const got = (try http.readLimitedBody(req, alloc, cap)) orelse return null;
            try req.respond(try std.fmt.allocPrint(alloc, "{d}", .{got.len}), .{ .keep_alive = false });
            return null;
        }
        try req.respond("ok", .{ .keep_alive = false });
        return null;
    }
};

const TestHost = Server(TestSite);

/// One served connection's task, for a test: the host's own handling.
fn serveForTest(io: Io, hub: *bus.Hub, stream: net.Stream) void {
    TestHost.serveConn(io, std.testing.allocator, hub, stream);
}

/// Whether a client's answer came within `ms`: read on a task of its own,
/// so a host that never answers fails the test rather than hanging it.
const Answer = struct {
    done: std.atomic.Value(bool) = .init(false),
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn read(self: *Answer, io: Io, stream: net.Stream) void {
        var buf: [256]u8 = undefined;
        var r = stream.reader(io, &buf);
        self.len = r.interface.readSliceShort(&self.bytes) catch 0;
        self.done.store(true, .release);
    }

    fn within(self: *Answer, io: Io, ms: i64) bool {
        var waited: i64 = 0;
        while (!self.done.load(.acquire) and waited < ms) : (waited += 10) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
        }
        return self.done.load(.acquire);
    }

    fn got(self: *const Answer) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A listener on a free port, and the host's pieces, for one test.
const Bench = struct {
    threaded: std.Io.Threaded,
    hub: bus.Hub,
    listener: net.Server,

    fn init(self: *Bench) !void {
        self.threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        const io = self.threaded.io();
        self.hub = bus.Hub.init(io, std.testing.allocator);
        const any: net.IpAddress = try .parse("127.0.0.1", 0);
        self.listener = try any.listen(io, .{ .reuse_address = true });
    }

    fn deinit(self: *Bench) void {
        const io = self.threaded.io();
        self.listener.deinit(io);
        self.hub.entries.deinit(std.testing.allocator);
        self.threaded.deinit();
    }

    /// A client connected, its connection served on a thread of its own, and
    /// `raw` sent.
    fn client(self: *Bench, raw: []const u8) !Client {
        const io = self.threaded.io();
        const stream = try self.listener.socket.address.connect(io, .{ .mode = .stream });
        const served = try std.Thread.spawn(.{}, serveForTest, .{ io, &self.hub, try self.listener.accept(io) });
        var w = stream.writer(io, &.{});
        try w.interface.writeAll(raw);
        return .{ .stream = stream, .served = served };
    }
};

const Client = struct {
    stream: net.Stream,
    served: std.Thread,
    answer: Answer = .{},
    reading: ?std.Thread = null,

    fn listen(self: *Client, io: Io) !void {
        self.reading = try std.Thread.spawn(.{}, Answer.read, .{ &self.answer, io, self.stream });
    }

    /// Let it go, whatever came of it: the client hangs up, and the host's
    /// task and the reader end.
    fn end(self: *Client, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.served.join();
        if (self.reading) |t| t.join();
        self.stream.close(io);
    }
};

fn heldBodyHoldsOnlyItsConnection(held_head: []const u8) !void {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();

    // A client sends a head whose body it never finishes.
    var held = try bench.client(held_head);
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};

    // Another client's GET / is still served, promptly.
    var other = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try other.listen(io);
    const prompt = other.answer.within(io, 2000);
    held.end(io);
    other.end(io);
    try std.testing.expect(prompt);
    try std.testing.expect(std.mem.startsWith(u8, other.answer.got(), "HTTP/1.1 200"));
}

test "linux_host: a chunked body held open holds only its own connection, not the turn" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n");
}

test "linux_host: a body shorter than its Content-Length holds only its own connection" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 60000\r\n\r\n0123456789");
}

test "linux_host: a body waiting on 100-continue holds only its own connection" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 100\r\n\r\n");
}

/// What one request gets from the host, whole, within two seconds.
fn exchange(raw: []const u8) ![]const u8 {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client(raw);
    try c.listen(io);
    const prompt = c.answer.within(io, 2000);
    c.end(io);
    try std.testing.expect(prompt);
    return std.testing.allocator.dupe(u8, c.answer.got());
}

test "linux_host: a body never finished is a 408 at the deadline, and its connection closes" {
    deadline_for_test_ms = 200;
    defer deadline_for_test_ms = null;
    const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408"));
}

test "linux_host: a body read before the turn reaches its handler whole, in every framing" {
    for ([_][]const u8{
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
    }) |raw| {
        const got = try exchange(raw);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 200") != null);
        try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n5"));
    }
}

test "linux_host: a body past its route's cap is a 413, unread, and the cap is the route's (metal-vmm QUEUE 167.2)" {
    const over = try exchange("POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    defer std.testing.allocator.free(over);
    try std.testing.expect(std.mem.startsWith(u8, over, "HTTP/1.1 413"));
    const chunked = try exchange("POST /tiny HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    defer std.testing.allocator.free(chunked);
    try std.testing.expect(std.mem.startsWith(u8, chunked, "HTTP/1.1 413"));
    // Waiting on 100-continue past the cap: refused, never told to send.
    const expect = try exchange("POST /tiny HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n");
    defer std.testing.allocator.free(expect);
    try std.testing.expect(std.mem.startsWith(u8, expect, "HTTP/1.1 413"));
    // The same four bytes on its own route are taken.
    const fits = try exchange("POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nhell");
    defer std.testing.allocator.free(fits);
    try std.testing.expect(std.mem.endsWith(u8, fits, "\r\n\r\n4"));
}

test "linux_host: both Content-Length and chunked is a 400 (metal-vmm QUEUE 167.7)" {
    const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400"));
}

test "linux_host: an upload is read whole before the turn and reaches its handler (metal-vmm QUEUE 169)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    const n = body_rule.before_turn_most + 1;
    const head = try std.fmt.allocPrint(std.testing.allocator, "POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: {d}\r\n\r\n", .{n});
    defer std.testing.allocator.free(head);
    var c = try bench.client(head);
    try c.listen(io);
    const payload = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var w = c.stream.writer(io, &.{});
    try w.interface.writeAll(payload);
    const prompt = c.answer.within(io, 5000);
    c.end(io);
    try std.testing.expect(prompt);
    const want = try std.fmt.allocPrint(std.testing.allocator, "\r\n\r\n{d}", .{n});
    defer std.testing.allocator.free(want);
    try std.testing.expect(std.mem.endsWith(u8, c.answer.got(), want));
}

test "linux_host: a slow uploader holds no one: another's GET / is answered at once, and the upload, whole, after (metal-vmm QUEUE 169)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // An upload that sends a little, and the rest a second later.
    var up = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 8\r\n\r\nxxxx");
    try up.listen(io);
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};
    var other = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try other.listen(io);
    const prompt = other.answer.within(io, 500);
    const upload_waited = !up.answer.done.load(.acquire);
    var w = up.stream.writer(io, &.{});
    try w.interface.writeAll("yyyy");
    const whole = up.answer.within(io, 2000);
    up.end(io);
    other.end(io);
    try std.testing.expect(prompt);
    try std.testing.expect(std.mem.startsWith(u8, other.answer.got(), "HTTP/1.1 200"));
    try std.testing.expect(upload_waited);
    try std.testing.expect(whole);
    try std.testing.expect(std.mem.endsWith(u8, up.answer.got(), "\r\n\r\n8"));
}

test "linux_host: an upload never finished is a 408 at its deadline (metal-vmm QUEUE 169)" {
    deadline_for_test_ms = 200;
    defer deadline_for_test_ms = null;
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 2000000\r\n\r\nxxxx");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408"));
}

test "linux_host: a stranger's upload is never read: its route refuses it at once, never told to send (metal-vmm QUEUE 169)" {
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 401"));
    try std.testing.expectEqual(@as(usize, 0), slots.inUse());
}

test "linux_host: a human's new upload takes over their stalled one: the old is told 409, the new is read whole (metal-vmm QUEUE 170.1)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // A dropped phone: half an upload, then nothing, and no FIN.
    var first = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\nxx");
    try first.listen(io);
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};
    try std.testing.expectEqual(@as(usize, 1), slots.inUse());
    // The retry, from the same human.
    var again = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\n0123456789");
    try again.listen(io);
    const done = again.answer.within(io, 2000);
    const old_told = first.answer.within(io, 2000);
    again.end(io);
    first.end(io);
    try std.testing.expect(done and old_told);
    try std.testing.expect(std.mem.endsWith(u8, again.answer.got(), "\r\n\r\n10"));
    try std.testing.expect(std.mem.startsWith(u8, first.answer.got(), "HTTP/1.1 409"));
    try std.testing.expectEqual(@as(usize, 0), slots.inUse());
}

test "linux_host: an upload with no byte for the stall time gives its slot back, a 408 (metal-vmm QUEUE 170.1)" {
    stall_for_test_ms = 200;
    defer stall_for_test_ms = null;
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 2000000\r\n\r\nxxxx");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408"));
    try std.testing.expect(std.mem.indexOf(u8, got, "stalled") != null);
    try std.testing.expectEqual(@as(usize, 0), slots.inUse());
}

test "linux_host: small bodies are held to a budget, charged as they arrive: past it, 503 (metal-vmm QUEUE 170.3)" {
    small_budget_for_test = 8;
    defer small_budget_for_test = null;
    const over = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n123456789");
    defer std.testing.allocator.free(over);
    try std.testing.expect(std.mem.startsWith(u8, over, "HTTP/1.1 503"));
    // What was charged is given back: the next fits.
    const fits = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n12345678");
    defer std.testing.allocator.free(fits);
    try std.testing.expect(std.mem.endsWith(u8, fits, "\r\n\r\n8"));
    try std.testing.expectEqual(@as(u64, 0), small_held);
}

test "linux_host: an Expect other than 100-continue is refused from the head, 417 (metal-vmm QUEUE 170.4)" {
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nExpect: tea\r\nContent-Length: 10\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 417"));
}

test "linux_host: an error before the turn is answered 500, never a close with no answer (metal-vmm QUEUE 170.6)" {
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: boom\r\nContent-Length: 10\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500"));
}

test "linux_host: a chunked upload is refused, 411: an upload's memory is its length (metal-vmm QUEUE 169)" {
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nTransfer-Encoding: chunked\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 411"));
}

test "linux_host: three upload slots: a fourth uploader waits, then is told uploads are busy (metal-vmm QUEUE 169)" {
    slot_wait_for_test_ms = 200;
    defer slot_wait_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var held: [3]Client = undefined;
    for (&held, [_][]const u8{ "ann", "bob", "cy" }) |*c, who| {
        const head = try std.fmt.allocPrint(std.testing.allocator, "POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: {s}\r\nContent-Length: 10\r\n\r\nxx", .{who});
        defer std.testing.allocator.free(head);
        c.* = try bench.client(head);
    }
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};
    try std.testing.expectEqual(@as(usize, 3), slots.inUse());
    for ([_][]const u8{"dee"}) |who| {
        const head = try std.fmt.allocPrint(std.testing.allocator, "POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: {s}\r\nContent-Length: 10\r\n\r\nxx", .{who});
        defer std.testing.allocator.free(head);
        var late = try bench.client(head);
        try late.listen(io);
        const told = late.answer.within(io, 2000);
        late.end(io);
        try std.testing.expect(told);
        try std.testing.expect(std.mem.startsWith(u8, late.answer.got(), "HTTP/1.1 503"));
    }
    for (&held) |*c| c.end(io);
    try std.testing.expectEqual(@as(usize, 0), slots.inUse());
}

test "linux_host: a body already whole when its read starts leaves no task running (metal-vmm QUEUE 167.1)" {
    // The read can finish before the timer is spawned; every task must
    // still be awaited before the frame that holds the race ends.
    for (0..200) |_| {
        const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n5"));
    }
}

test "linux_host: a body refused in the turn without being read is never told to send (metal-vmm QUEUE 166)" {
    // A stranger's, never read, refused by its route with no 100 first.
    const got = try exchange("POST /refuses HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 303"));
    // An uploader's, told once, read before the turn (then late: nothing came).
    deadline_for_test_ms = 300;
    defer deadline_for_test_ms = null;
    const told = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n");
    defer std.testing.allocator.free(told);
    try std.testing.expect(std.mem.startsWith(u8, told, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 408"));
}
