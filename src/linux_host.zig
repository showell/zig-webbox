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
//! (Steve, 2026-10-07). A connection serves requests one after another
//! until one ends it (keep-alive, metal-vmm QUEUE 213): see handleConn.

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
const linux_durable = @import("linux_durable.zig");
const linux_fetch = @import("linux_fetch.zig");
const linux_writes = @import("linux_writes.zig");
const linux_streams = @import("linux_streams.zig");
const linux_reads = @import("linux_reads.zig");

/// The environment variables a host reads, named whole by the application,
/// so a search for one finds where it is read.
pub const Env = struct {
    /// The port; unset is `Options.default_port`, and one that is not a
    /// port stops the host (198.6).
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
/// `start`, `route`, `Started`, and optionally `between(io, Now) Wake`.
pub fn Server(comptime S: type) type {
    inline for (.{ "start", "route", "Started", "bodyLimit" }) |name| {
        if (!@hasDecl(S, name)) @compileError("linux_host.Server takes a site, which declares " ++ name ++ " (site.zig)");
    }
    return struct {
        const ServerType = @This();
        /// What the host's tests drive directly (linux_host_test.zig).
        pub const for_tests = struct {
            pub const serveConn = ServerType.serveConn;
            pub const betweenLoop = ServerType.betweenLoop;
            pub const startBetween = ServerType.startBetween;
        };
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
                .say = sayToStderr,
                .fetch = .{ .start = linux_fetch.start, .result = linux_fetch.result },
            });
            report(&started);
            // **NO RESPONSE BEFORE ITS WRITES ARE DURABLE** (HOST.md): the
            // data's filesystems, opened once, are synced before a response
            // that follows a write (linux_durable.zig).
            const synced = try durable.openRoots(io);
            // And on demand, answering whether it held (store.makeDurable:
            // the script route's sequence number, before the script runs).
            @import("webbox").store.durable_now = durableNow;
            std.debug.print("{s}: before a response that follows a write, syncs {s}\n", .{ options.name, synced });
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

            const port = portFrom(env.get(options.env.port), options.default_port) catch |e| {
                std.debug.print("{s}: {s}={s} is not a port (1 to 65535); not starting\n", .{ options.name, options.env.port, env.get(options.env.port) orelse "" });
                return e;
            };
            const addr = bind.address(env.get(options.env.bind), port) catch |e| {
                std.debug.print("{s}: {s}={s} is not an IP address; not starting\n", .{ options.name, options.env.bind, env.get(options.env.bind) orelse "" });
                return e;
            };
            var listener = try addr.listen(io, .{ .reuse_address = true });
            defer listener.deinit(io);
            // **BETWEEN HANDLERS, A SLICE AT A TIME** (metal-vmm QUEUE 211):
            // the site's background work on a thread of its own.
            // A fetch's end rings the between thread, as a handler's does.
            linux_fetch.on_end = .{ .io = io, .ring = ringBetween };
            startBetween(io, &never_stop);

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

        /// **STEPPED BEFORE THE FIRST REQUEST** (metal-vmm QUEUE 222): one
        /// call of the site's `between` on the starting thread, before any
        /// connection is accepted, then the thread that goes on calling it.
        /// A site that learns from its first `between` that its host steps
        /// background runs (angry-gopher's and Dog Park's script routes) so
        /// knows it before the first request, not only once the thread has
        /// first run, which a request right after start could beat.
        fn startBetween(io: Io, stop: *const std.atomic.Value(bool)) void {
            if (!@hasDecl(S, "between")) return;
            turn.lockUncancelable(io);
            _ = S.between(io, nowOf(io));
            turn.unlock(io);
            _ = std.Thread.spawn(.{}, betweenLoop, .{ io, stop }) catch |e| {
                std.debug.print("{s}: no thread for work between requests ({s}); a background run is never stepped\n", .{ host_name, @errorName(e) });
            };
        }

        /// **ONE SLICE A TURN, AND A WAITING HANDLER FIRST** (metal-vmm QUEUE
        /// 211, Steve's model: "on Linux, one runner thread takes the turn
        /// for each slice"): the site's `between` under the turn, then the
        /// turn let go, and taken again only once no handler waits for it,
        /// so a request arriving mid-run waits at most one slice. A mutex
        /// makes no promise of fairness, so the waiting handlers are counted.
        ///
        /// **THEN IT SLEEPS UNTIL IT IS WANTED** (zig-metal-unikernel's
        /// docs/designs/DESIGN-sleep.md), as the bare-metal host does: until
        /// the site's wake (`.at`), or, `.idle`, until something happens. The
        /// doorbell (`between_bell`) is rung by every handler's end and by a
        /// stop; its count is read before `between` is called, so a ring
        /// that comes while the thread decides to sleep has changed it, and
        /// the wait returns at once.
        fn betweenLoop(io: Io, stop: *const std.atomic.Value(bool)) void {
            while (!stop.load(.acquire)) {
                const rung = between_bell.load(.acquire);
                turn.lockUncancelable(io);
                const wake = S.between(io, nowOf(io));
                turn.unlock(io);
                // A handler waiting goes first: checked every millisecond,
                // not spun on (the box's cold review: a core burned).
                while (turn_waiting.load(.acquire) > 0 and !stop.load(.acquire)) sleepMs(io, 1) catch return;
                if (stop.load(.acquire)) return;
                switch (wake) {
                    .more => {},
                    .at => |at| io.futexWaitTimeout(u32, &between_bell.raw, rung, .{ .deadline = .{ .raw = .{ .nanoseconds = at }, .clock = .awake } }) catch return,
                    .idle => io.futexWait(u32, &between_bell.raw, rung) catch return,
                }
            }
        }

        /// The body of `req` read whole into memory before the turn, by the
        /// rule (body.zig), or the refusal to answer instead. An upload is
        /// read once its uploader is known (a stranger's never) and holds a
        /// slot; a small one is charged to the small budget as it arrives.
        fn bodyBeforeTurn(io: Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, owned: *?[]u8, req: *std.http.Server.Request, progress: *linux_reads.Progress, slot: *?usize, held: *?[]u8, charged: *u64) !?Refusal {
            const cap = S.bodyLimit(try http.target(req, arena));
            const planned = body_rule.plan(&req.head, cap);
            if (planned != .refused) body_rule.meetExpectation(&req.head);
            const read: body_rule.Read, const upload = switch (planned) {
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
                    try linux_reads.neverRead(req, arena);
                    return null;
                };
                slot.* = switch (linux_reads.takeSlot(io, body_rule.keyOf(who), progress, linux_reads.nextAsk(io))) {
                    .slot => |i| i,
                    .busy => return .{ .kind = .uploads_busy, .msg = "Uploads are busy; try again in a minute.\n" },
                    .replaced => return .{ .kind = .upload_replaced, .msg = "a newer upload took this one's place\n" },
                };
            }
            const began = Io.Clock.now(.awake, io);
            const length = req.head.content_length orelse 0;
            const got = try linux_reads.readWhole(io, arena, gpa, owned, req, read, upload, progress, charged);
            if (linux_reads.fail_after_read_for_test) return error.TestFailedAfterRead;
            // Read: nothing left to take over (a newer upload now waits for
            // this one's slot, which comes back when its request is done).
            if (slot.*) |i| linux_reads.readDone(io, i);
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

        /// **A CONNECTION SERVES REQUESTS UNTIL ONE ENDS IT** (metal-vmm
        /// QUEUE 213; it served one and closed, so a page reporting four
        /// times a second opened four connections a second, and a home
        /// router's ~1,000 source ports wrapped every few minutes). Each
        /// request has its own arena, body memory, slot and charge, all
        /// given back when it is answered. The connection closes when the
        /// client or a handler says close, a body was left unread, a
        /// stream was kept, it has served `requests_most`, the kept-open
        /// connections are at `kept_open_most`, or no next head comes
        /// within `idle_ms`. Pipelined requests are answered in order. The
        /// bare-metal host still serves one a connection.
        fn handleConn(io: std.Io, alloc: std.mem.Allocator, hub: *bus.Hub, stream: net.Stream) !void {
            defer stream.close(io);

            var read_buf: [http.head_bytes]u8 = undefined; // must hold the full request header
            var write_buf: [64 * 1024]u8 = undefined;
            var sr = stream.reader(io, &read_buf);
            // The socket's own writer, unbuffered, under the one every byte
            // goes through: it syncs the writes before it (linux_durable.zig).
            var socket_w = stream.writer(io, &.{});
            // Every write to the socket under a deadline (`linux_writes.Sent`).
            var sent: linux_writes.Sent = .{ .to = &socket_w.interface, .stream = stream, .io = io };
            var sw: linux_durable.Writer = .init(&sent.interface, &durable, &write_buf);
            // An answer held in memory while its handler has the turn (`linux_writes.Hold`).
            var hold: linux_writes.Hold = .{ .to = &sw.interface, .gpa = alloc };
            defer hold.list.deinit(alloc);
            // And above it, what each answer's head says of the connection.
            var said: HeadWatch = .{ .to = &hold.interface };
            var server = std.http.Server.init(&sr.interface, &said.interface);
            var conn: Connection = .{};
            defer conn.letGo();
            // A write shut at its deadline ends the connection, counted
            // (`linux_writes.writes_shut`), not logged as a connection's error.
            while (serveOne(io, alloc, hub, stream, &server, &sr.interface, &sw, &said, &conn, &hold, &sent) catch |e| {
                if (sent.shut) return;
                return e;
            }) {}
        }

        /// One request on the connection, answered: whether the connection
        /// serves another.
        fn serveOne(io: std.Io, alloc: std.mem.Allocator, hub: *bus.Hub, stream: net.Stream, server: *std.http.Server, socket_r: *std.Io.Reader, sw: *linux_durable.Writer, said: *HeadWatch, conn: *Connection, hold: *linux_writes.Hold, sent: *linux_writes.Sent) !bool {
            // The socket again, wherever the last request's body was read from.
            server.reader.in = socket_r;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            // **THE HEAD HAS A DEADLINE TOO** (metal-vmm QUEUE 184): a client
            // that connected and sent nothing, or a head a byte at a time,
            // held its task for ever (the body's deadline came only after).
            // The read races `linux_reads.watch`, as a body's does. **A HEAD AFTER THE
            // FIRST HAS THE IDLE TIMEOUT** (213): from the last answer, the
            // whole of the next head.
            const first = conn.served == 0;
            var head_progress: linux_reads.Progress = .{ .stream = stream, .io = io };
            var head_read: HeadRead = .{ .server = server };
            {
                var buffer: [2]linux_reads.Raced = undefined;
                var race: Io.Select(linux_reads.Raced) = .init(io, &buffer);
                const deadline = if (first) head_for_test_ms orelse head_ms else idle_for_test_ms orelse idle_ms;
                if (race.concurrent(.read, HeadRead.run, .{&head_read})) |_| {
                    if (race.concurrent(.watch, linux_reads.watch, .{ io, &head_progress, deadline, null })) |_| {
                        _ = race.await() catch {};
                    } else |_| head_progress.end(.deadline);
                    race.cancelDiscard();
                } else |_| head_read.run(); // no task for it: read here, as before
            }
            if (head_progress.ended_by.load(.acquire) == .deadline) {
                // An idle connection, not a byte of a next head: closed, as
                // a kept-open connection is, with no answer.
                if (!first and socket_r.bufferedLen() == 0) {
                    _ = idle_closed.fetchAdd(1, .acq_rel);
                    return false;
                }
                edge.count(.head_too_slow);
                sw.interface.writeAll("HTTP/1.1 408 Request Timeout\r\n" ++
                    "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
                sw.interface.flush() catch {};
                return false;
            }
            var req = head_read.got.? catch |e| switch (e) {
                // The client gone, between requests or partway through a head.
                error.HttpConnectionClosing, error.HttpRequestTruncated => return false,
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
                    return false;
                },
                // **A HEAD THAT IS NOT HTTP IS A 400, COUNTED** (edge.zig's
                // rule, metal-vmm QUEUE 172): it was closed with no answer
                // and no counter. Best-effort, as the 431.
                error.HttpHeadersInvalid => {
                    edge.count(.head_malformed);
                    sw.interface.writeAll("HTTP/1.1 400 Bad Request\r\n" ++
                        "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
                    sw.interface.flush() catch {};
                    return false;
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
            var progress: linux_reads.Progress = .{ .stream = stream, .io = io };
            var slot: ?usize = null;
            defer if (slot) |i| linux_reads.giveBackSlot(io, i);
            var held_body: ?[]u8 = null;
            // The body's memory (177.2), freed when the connection is done,
            // as the arena is: after the route and any stream it kept.
            var body_mem: ?[]u8 = null;
            defer if (body_mem) |m| alloc.free(m);
            var charged: u64 = 0;
            defer linux_reads.unchargeSmall(io, charged);
            // **AN ERROR BEFORE THE TURN IS ANSWERED** (170.6): a 500, as
            // one in the turn is, never a close with no answer.
            const refusal = bodyBeforeTurn(io, arena.allocator(), alloc, &body_mem, &req, &progress, &slot, &held_body, &charged) catch |e| {
                if (!@import("builtin").is_test) std.debug.print("{s}: before the turn: {s}\n", .{ host_name, @errorName(e) });
                req.head.keep_alive = false;
                req.head.expect = null;
                req.respond("The server failed before it could answer.\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
                return false;
            };
            if (refusal) |r| {
                refuse(&req, r.kind, r.msg);
                return false;
            }
            // **WHETHER THIS ANSWER KEEPS THE CONNECTION** is decided before
            // the handler runs, so its head says it: not past the
            // connection's most requests, nor past the kept-open most.
            conn.served += 1;
            if (!req.head.keep_alive or conn.served >= requests_most_for_test orelse requests_most or !conn.keepOpen()) req.head.keep_alive = false;
            said.begin();
            var b = bus.Bus.of(hub);
            var peer_buf: [64]u8 = undefined;
            b.peer = peerText(&peer_buf, stream.socket.address);
            b.at_unix_ms = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms));
            takeTurn(io);
            // **THE TURN NEVER WAITS ON THE NETWORK** (the box's cold review
            // of 213: a client that pipelined answers and read none blocked
            // a write in the turn, and the whole site with it): the answer is
            // held in memory while the handler has the turn, and goes out
            // after, on this connection's own task. Past `linux_writes.held_most` it is
            // written in the turn, each write under the turn's deadline.
            hold.begin();
            sent.in_turn = true;
            // The body read before the turn, handed to the handler's read
            // as it is (170.5: an upload in memory once, not twice).
            http.held_body = held_body;
            const routed = S.route(&req, io, arena.allocator(), &b);
            http.held_body = null;
            sent.in_turn = false;
            turn.unlock(io);
            // The request may have started work between requests (a
            // background run): the thread that does it is woken to look.
            ringBetween(io);
            // Out now, outside the turn: until it has gone, this connection
            // reads no next head, so answers never pile up unread.
            hold.release() catch {
                if (try routed) |k| bus.drop(hub, k);
                return false;
            };
            // The body's charge back now, before a kept stream holds the
            // connection (metal-vmm QUEUE 176.3: ~64 open streams of 1 MiB
            // posts pinned the whole budget).
            linux_reads.unchargeSmall(io, charged);
            charged = 0;
            // A stream the handler kept is route's answer, served here, on
            // this connection's own task, until its client goes away; on an
            // error route has dropped it (metal-vmm QUEUE 157(a)).
            // **AT MOST `linux_streams.streams_most` HELD** (metal-vmm QUEUE 184): each
            // held a task and its buffers for as long as its client stayed,
            // with no count; a member could open them until no thread was
            // left. One more ends the oldest, as the kernel's do: a browser
            // whose stream ends reconnects and resumes.
            const kept = (try routed) orelse {
                // Served again only when the answer said so, its request
                // read to its end and the client asked for no close.
                return req.head.keep_alive and said.whole and !said.close and server.reader.state == .ready;
            };
            {
                const held_stream = linux_streams.holdStream(io, stream);
                defer linux_streams.letGoStream(io, held_stream);
                // **ITS WRITES WATCHED** (198.6): a write under way and
                // unmoved past the deadline has its socket shut, so it fails
                // and the stream ends. A stream with no watcher is not
                // served without one.
                var watched: linux_writes.WriteWatch = .{ .stream = stream, .ms = linux_writes.write_deadline_for_test_ms orelse linux_writes.kept_write_deadline_ms };
                const watcher = std.Thread.spawn(.{}, linux_writes.WriteWatch.run, .{ &watched, io }) catch {
                    std.debug.print("{s}: a kept stream's writes could not be watched; the stream ends\n", .{host_name});
                    bus.drop(hub, kept);
                    return false;
                };
                defer {
                    watched.end(io);
                    watcher.join();
                }
                bus.serveKeptCounted(hub, kept, &sw.interface, &watched.writes);
            }
            // A kept stream is the connection's last answer.
            return false;
        }
    };
}

/// A connection there is no task to serve: a 503 written straight to it (a
/// few bytes, which the socket's own buffer takes), and closed.
fn busy(io: Io, stream: net.Stream) void {
    defer stream.close(io);
    durable.beforeBytes();
    edge.count(.no_deadline);
    var w = stream.writer(io, &.{});
    w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
}

const Refusal = struct { kind: edge.RejectKind, msg: []const u8 };

/// The most a request's head may take to arrive whole (184), and a test's own.
pub const head_ms: u64 = 10_000;
pub var head_for_test_ms: ?u64 = null;

/// **A KEPT-OPEN CONNECTION'S LIMITS** (metal-vmm QUEUE 213), each with a
/// test's own. **The idle timeout**: from an answer, the whole of the next
/// head, the same time a first head has, so a connection waiting for its
/// next request is held no longer than one waiting for its first.
pub const idle_ms: u64 = head_ms;
pub var idle_for_test_ms: ?u64 = null;
/// **The most requests one connection serves**: its last answer says close.
pub const requests_most: u64 = 1000;
pub var requests_most_for_test: ?u64 = null;
/// **The most connections kept open at once**, idle or not, as many as the
/// streams held: past it, an answer says close, as one did before 213, so a
/// client that opens many keeps no task from anyone.
pub const kept_open_most: usize = 64;
pub var kept_open_most_for_test: ?usize = null;
var kept_open: std.atomic.Value(usize) = .init(0);
/// Idle connections closed at the timeout, for tests and the host's report.
pub var idle_closed: std.atomic.Value(u64) = .init(0);

/// One connection's account: its requests, and whether it holds one of
/// the kept-open places.
const Connection = struct {
    served: u64 = 0,
    holds_place: bool = false,

    /// A kept-open place for this connection, held until it closes; false
    /// when every place is taken.
    fn keepOpen(self: *Connection) bool {
        if (self.holds_place) return true;
        const most = kept_open_most_for_test orelse kept_open_most;
        var now = kept_open.load(.acquire);
        while (now < most) {
            now = kept_open.cmpxchgWeak(now, now + 1, .acq_rel, .acquire) orelse {
                self.holds_place = true;
                return true;
            };
        }
        return false;
    }

    fn letGo(self: *Connection) void {
        if (self.holds_place) _ = kept_open.fetchSub(1, .acq_rel);
        self.holds_place = false;
    }
};

/// **WHAT AN ANSWER'S HEAD SAYS OF ITS CONNECTION** (metal-vmm QUEUE 213):
/// std's `respond` writes `connection: close` when its handler asked for
/// one (respond's own `keep_alive = false`) or the request's body could not
/// be discarded, and the server must then close (RFC 9112, 9.6); nothing
/// else tells the host. Every byte of an answer passes through it,
/// unbuffered, and the head's lines are looked at as they go.
const HeadWatch = struct {
    to: *std.Io.Writer,
    interface: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },
    /// Since `begin`: whether a head has been written whole, and whether it
    /// said close.
    whole: bool = false,
    close: bool = false,
    line: [32]u8 = undefined,
    line_len: usize = 0,
    /// The line is longer than any this looks for.
    line_long: bool = false,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    /// The next bytes are a new answer's.
    fn begin(self: *HeadWatch) void {
        self.whole = false;
        self.close = false;
        self.line_len = 0;
        self.line_long = false;
    }

    fn see(self: *HeadWatch, bytes: []const u8) void {
        for (bytes) |c| {
            if (self.whole) return;
            switch (c) {
                '\r' => {},
                '\n' => {
                    const l = self.line[0..self.line_len];
                    if (!self.line_long) {
                        if (l.len == 0) self.whole = true;
                        if (std.ascii.eqlIgnoreCase(l, "connection: close")) self.close = true;
                    }
                    self.line_len = 0;
                    self.line_long = false;
                },
                else => if (self.line_len < self.line.len) {
                    self.line[self.line_len] = c;
                    self.line_len += 1;
                } else {
                    self.line_long = true;
                },
            }
        }
    }

    /// On to `to`; what it took, looked at.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HeadWatch = @alignCast(@fieldParentPtr("interface", w));
        const n = try self.to.writeSplat(data, splat);
        var left = n;
        for (data[0 .. data.len - 1]) |d| {
            const k = @min(left, d.len);
            self.see(d[0..k]);
            left -= k;
        }
        const last = data[data.len - 1];
        while (left > 0 and !self.whole) {
            const k = @min(left, last.len);
            self.see(last[0..k]);
            left -= k;
        }
        return n;
    }

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const self: *HeadWatch = @alignCast(@fieldParentPtr("interface", w));
        // A file in a head is std's to write by `drain`.
        if (!self.whole) return error.Unimplemented;
        return self.to.sendFile(file_reader, limit);
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *HeadWatch = @alignCast(@fieldParentPtr("interface", w));
        return self.to.flush();
    }
};

/// A request head read, beside its watchdog.
const HeadRead = struct {
    server: *std.http.Server,
    got: ?(std.http.Server.ReceiveHeadError!std.http.Server.Request) = null,
    fn run(h: *HeadRead) void {
        h.got = h.server.receiveHead();
    }
};

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

/// The process's one account of what is durable (linux_durable.zig). Until
/// `run` opens the roots it syncs nothing, which is what a test's server,
/// with none, wants.
var durable: linux_durable.Durable = .init(linux_durable.syncRoots, 0);

fn durableNow() bool {
    return durable.now();
}

/// The handlers waiting for the turn, so the work between them lets them
/// go first (`betweenLoop`).
var turn_waiting: std.atomic.Value(u32) = .init(0);

/// The turn, for a handler: counted while it waits.
fn takeTurn(io: Io) void {
    _ = turn_waiting.fetchAdd(1, .acq_rel);
    turn.lockUncancelable(io);
    _ = turn_waiting.fetchSub(1, .acq_rel);
}

var never_stop: std.atomic.Value(bool) = .init(false);

/// **THE BETWEEN THREAD'S DOORBELL** (`betweenLoop`): a count, rung by a
/// handler's end and a stop, which the thread's futex waits on.
var between_bell: std.atomic.Value(u32) = .init(0);

fn ringBetween(io: Io) void {
    _ = between_bell.fetchAdd(1, .release);
    io.futexWake(u32, &between_bell.raw, 1);
}

/// Stops a between thread: the flag, then the bell, so a thread asleep
/// until a far wake, or until anything, sees it at once.
fn stopBetween(io: Io, stop: *std.atomic.Value(bool)) void {
    stop.store(true, .release);
    ringBetween(io);
}

/// **ONE HANDLER AT A TIME**: held while `route` runs, so no two handlers
/// interleave, as on the bare-metal host, where one loop runs each to its
/// end. Reading the head and the body comes before it, and serving a kept
/// stream after it, so a slow client holds up nobody but itself. One per
/// process.
var turn: Io.Mutex = .init;

/// The port in the variable's text, or `default` when it is unset. A port
/// override is load-bearing for running more than one server at once (a
/// test's server on a side port beside the development one). **SET AND NOT
/// A PORT, IT IS REFUSED** (metal-vmm QUEUE 198.6): decimal digits, 1 to
/// 65535, around whitespace; metal stops on a setting it cannot read, and a
/// typo that served on the default instead ran a second server beside the
/// one it meant to stand apart from.
fn portFrom(text: ?[]const u8, default: u16) error{NotAPort}!u16 {
    const s = std.mem.trim(u8, text orelse return default, " \t\r\n");
    if (s.len == 0) return error.NotAPort;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.NotAPort;
    const port = std.fmt.parseInt(u16, s, 10) catch return error.NotAPort;
    return if (port == 0) error.NotAPort else port;
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

/// An application's line (host_facts.say), on standard error with the
/// host's own.
fn sayToStderr(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}

/// Both clocks, for `between` (site.zig's `Now`).
fn nowOf(io: Io) @import("webbox").site.Now {
    return .{ .awake_ns = Io.Clock.now(.awake, io).nanoseconds, .unix_s = nowUnix(io) };
}

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
    // **WHAT DURABILITY COST** (198.6): a sync that failed is a response
    // that went out with the writes before it not yet on the disk.
    try facts.append(alloc, .{ .label = "data syncs failed", .value = try std.fmt.allocPrint(alloc, "{d} (each a response sent before the writes it followed were durable)", .{durable.failures.load(.acquire)}) });
    try facts.append(alloc, .{ .label = "kept streams ended by a stalled write", .value = try std.fmt.allocPrint(alloc, "{d} (a reader that stayed connected and stopped reading for {d} s)", .{ linux_writes.writes_ended_by_deadline.load(.acquire), linux_writes.kept_write_deadline_ms / std.time.ms_per_s }) });
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

/// **WHAT THE HOST'S TESTS REACH** of its insides (linux_host_test.zig),
/// named once here, so its interface stays what an application sees.
pub const for_tests = struct {
    pub const HeadWatch = host_file.HeadWatch;
    pub const sleepMs = host_file.sleepMs;
    pub const takeTurn = host_file.takeTurn;
    pub const ringBetween = host_file.ringBetween;
    pub const stopBetween = host_file.stopBetween;
    pub const portFrom = host_file.portFrom;
    pub const linuxFacts = host_file.linuxFacts;
    pub const turn = &host_file.turn;
    pub const durable = &host_file.durable;
    pub const kept_open = &host_file.kept_open;
};
const host_file = @This();

test {
    _ = @import("linux_host_test.zig");
}
