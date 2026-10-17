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
        /// so a request arriving mid-run waits at most one slice. With
        /// nothing to do, it sleeps `between_idle_ms`. A mutex makes no
        /// promise of fairness, so the waiting handlers are counted.
        fn betweenLoop(io: Io, stop: *const std.atomic.Value(bool)) void {
            while (!stop.load(.acquire)) {
                turn.lockUncancelable(io);
                const more = S.between(io, nowOf(io)) == .more;
                turn.unlock(io);
                // A handler waiting goes first: checked every millisecond,
                // not spun on (the box's cold review: a core burned).
                while (turn_waiting.load(.acquire) > 0 and !stop.load(.acquire)) sleepMs(io, 1) catch return;
                if (!more) sleepMs(io, between_idle_ms) catch return;
            }
        }

        /// The body of `req` read whole into memory before the turn, by the
        /// rule (body.zig), or the refusal to answer instead. An upload is
        /// read once its uploader is known (a stranger's never) and holds a
        /// slot; a small one is charged to the small budget as it arrives.
        fn bodyBeforeTurn(io: Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, owned: *?[]u8, req: *std.http.Server.Request, progress: *Progress, slot: *?usize, held: *?[]u8, charged: *u64) !?Refusal {
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
                    try neverRead(req, arena);
                    return null;
                };
                slot.* = switch (takeSlot(io, body_rule.keyOf(who), progress, nextAsk(io))) {
                    .slot => |i| i,
                    .busy => return .{ .kind = .uploads_busy, .msg = "Uploads are busy; try again in a minute.\n" },
                    .replaced => return .{ .kind = .upload_replaced, .msg = "a newer upload took this one's place\n" },
                };
            }
            const began = Io.Clock.now(.awake, io);
            const length = req.head.content_length orelse 0;
            const got = try readWhole(io, arena, gpa, owned, req, read, upload, progress, charged);
            if (fail_after_read_for_test) return error.TestFailedAfterRead;
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
            // Every write to the socket under a deadline (`Sent`).
            var sent: Sent = .{ .to = &socket_w.interface, .stream = stream, .io = io };
            var sw: linux_durable.Writer = .init(&sent.interface, &durable, &write_buf);
            // An answer held in memory while its handler has the turn (`Hold`).
            var hold: Hold = .{ .to = &sw.interface, .gpa = alloc };
            defer hold.list.deinit(alloc);
            // And above it, what each answer's head says of the connection.
            var said: HeadWatch = .{ .to = &hold.interface };
            var server = std.http.Server.init(&sr.interface, &said.interface);
            var conn: Connection = .{};
            defer conn.letGo();
            // A write shut at its deadline ends the connection, counted
            // (`writes_shut`), not logged as a connection's error.
            while (serveOne(io, alloc, hub, stream, &server, &sr.interface, &sw, &said, &conn, &hold, &sent) catch |e| {
                if (sent.shut) return;
                return e;
            }) {}
        }

        /// One request on the connection, answered: whether the connection
        /// serves another.
        fn serveOne(io: std.Io, alloc: std.mem.Allocator, hub: *bus.Hub, stream: net.Stream, server: *std.http.Server, socket_r: *std.Io.Reader, sw: *linux_durable.Writer, said: *HeadWatch, conn: *Connection, hold: *Hold, sent: *Sent) !bool {
            // The socket again, wherever the last request's body was read from.
            server.reader.in = socket_r;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            // **THE HEAD HAS A DEADLINE TOO** (metal-vmm QUEUE 184): a client
            // that connected and sent nothing, or a head a byte at a time,
            // held its task for ever (the body's deadline came only after).
            // The read races `watch`, as a body's does. **A HEAD AFTER THE
            // FIRST HAS THE IDLE TIMEOUT** (213): from the last answer, the
            // whole of the next head.
            const first = conn.served == 0;
            var head_progress: Progress = .{ .stream = stream, .io = io };
            var head_read: HeadRead = .{ .server = server };
            {
                var buffer: [2]Raced = undefined;
                var race: Io.Select(Raced) = .init(io, &buffer);
                const deadline = if (first) head_for_test_ms orelse head_ms else idle_for_test_ms orelse idle_ms;
                if (race.concurrent(.read, HeadRead.run, .{&head_read})) |_| {
                    if (race.concurrent(.watch, watch, .{ io, &head_progress, deadline, null })) |_| {
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
            var progress: Progress = .{ .stream = stream, .io = io };
            var slot: ?usize = null;
            defer if (slot) |i| giveBackSlot(io, i);
            var held_body: ?[]u8 = null;
            // The body's memory (177.2), freed when the connection is done,
            // as the arena is: after the route and any stream it kept.
            var body_mem: ?[]u8 = null;
            defer if (body_mem) |m| alloc.free(m);
            var charged: u64 = 0;
            defer unchargeSmall(io, charged);
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
            // after, on this connection's own task. Past `held_most` it is
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
            // Out now, outside the turn: until it has gone, this connection
            // reads no next head, so answers never pile up unread.
            hold.release() catch {
                if (try routed) |k| bus.drop(hub, k);
                return false;
            };
            // The body's charge back now, before a kept stream holds the
            // connection (metal-vmm QUEUE 176.3: ~64 open streams of 1 MiB
            // posts pinned the whole budget).
            unchargeSmall(io, charged);
            charged = 0;
            // A stream the handler kept is route's answer, served here, on
            // this connection's own task, until its client goes away; on an
            // error route has dropped it (metal-vmm QUEUE 157(a)).
            // **AT MOST `streams_most` HELD** (metal-vmm QUEUE 184): each
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
                const held_stream = holdStream(io, stream);
                defer letGoStream(io, held_stream);
                // **ITS WRITES WATCHED** (198.6): a write under way and
                // unmoved past the deadline has its socket shut, so it fails
                // and the stream ends. A stream with no watcher is not
                // served without one.
                var watched: WriteWatch = .{ .stream = stream, .ms = write_deadline_for_test_ms orelse kept_write_deadline_ms };
                const watcher = std.Thread.spawn(.{}, WriteWatch.run, .{ &watched, io }) catch {
                    std.debug.print("{s}: a kept stream's writes could not be watched; the stream ends\n", .{host_name});
                    bus.drop(hub, kept);
                    return false;
                };
                defer {
                    watched.done.store(true, .release);
                    watcher.join();
                }
                bus.serveKeptCounted(hub, kept, &sw.interface, &watched.writes);
            }
            // A kept stream is the connection's last answer.
            return false;
        }
    };
}

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
const Hold = struct {
    to: *std.Io.Writer,
    gpa: std.mem.Allocator,
    holding: bool = false,
    /// Past `held_most`: what was held has been written, and the rest goes
    /// straight on.
    spilled: bool = false,
    list: std.ArrayList(u8) = .empty,
    interface: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    fn begin(h: *Hold) void {
        h.holding = true;
        h.spilled = false;
    }

    /// What was held, written and flushed; holding no more. Its memory
    /// given back, so a kept connection holds none between requests.
    fn release(h: *Hold) std.Io.Writer.Error!void {
        h.holding = false;
        defer h.list.clearAndFree(h.gpa);
        if (h.list.items.len > 0) try h.to.writeAll(h.list.items);
        try h.to.flush();
    }

    fn spill(h: *Hold) std.Io.Writer.Error!void {
        h.spilled = true;
        try h.to.writeAll(h.list.items);
        h.list.clearAndFree(h.gpa);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
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

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const h: *Hold = @alignCast(@fieldParentPtr("interface", w));
        // Held, a file is read into memory by `drain`.
        if (h.holding and !h.spilled) return error.Unimplemented;
        return h.to.sendFile(file_reader, limit);
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const h: *Hold = @alignCast(@fieldParentPtr("interface", w));
        if (h.holding and !h.spilled) return;
        return h.to.flush();
    }
};

/// The socket's writes, each under its deadline (`watchWrite`).
const Sent = struct {
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

    fn deadline(s: *const Sent) u64 {
        return if (s.in_turn) turn_write_deadline_for_test_ms orelse turn_write_deadline_ms else answer_write_deadline_for_test_ms orelse answer_write_deadline_ms;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *Sent = @alignCast(@fieldParentPtr("interface", w));
        const t = watchWrite(s.io, s.stream, s.deadline());
        defer if (!doneWrite(s.io, t)) {
            s.shut = true;
        };
        return s.to.writeSplat(data, splat);
    }

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const s: *Sent = @alignCast(@fieldParentPtr("interface", w));
        const t = watchWrite(s.io, s.stream, s.deadline());
        defer if (!doneWrite(s.io, t)) {
            s.shut = true;
        };
        return s.to.sendFile(file_reader, limit);
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
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
        sleepMs(io, 50) catch {};
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
const WriteWatch = struct {
    stream: net.Stream,
    ms: u64,
    writes: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *WriteWatch, io: Io) void {
        const step = @max(self.ms / 4, 10);
        var last = self.writes.load(.acquire);
        var still: u64 = 0;
        while (!self.done.load(.acquire)) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(@intCast(step)) }, io) catch {};
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

/// A connection there is no task to serve: a 503 written straight to it (a
/// few bytes, which the socket's own buffer takes), and closed.
fn busy(io: Io, stream: net.Stream) void {
    defer stream.close(io);
    durable.beforeBytes();
    edge.count(.no_deadline);
    var w = stream.writer(io, &.{});
    w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
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

/// The request's body read into memory from `gpa` (its slice left in
/// `owned`, the caller's to free; the head is copied into `arena`), before
/// the turn, and the request left to its handler as if it had not been: the head copied out of the
/// read buffer (a body read reuses it), the body served from memory under
/// a plain Content-Length (and handed over as it is: `http.held_body`).
fn readWhole(io: Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, owned: *?[]u8, req: *std.http.Server.Request, plan: body_rule.Read, upload: bool, progress: *Progress, charged: *u64) !Got {
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

const Raced = union(enum) { read: void, watch: void };

/// The most streams held at once (184), as the kernel's default, and a test's own.
pub const streams_most: usize = 64;
pub var streams_most_for_test: ?usize = null;
var held_streams: [streams_most]?struct { stream: net.Stream, since: u64 } = @splat(null);
var held_lock: Io.Mutex = .init;
var held_count: u64 = 0;

const Held = struct { slot: usize, ticket: u64 };

/// A slot for a stream about to be served; the oldest ended to make room.
fn holdStream(io: Io, stream: net.Stream) Held {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    const most = @min(streams_most_for_test orelse streams_most, streams_most);
    held_count += 1;
    var free: ?usize = null;
    var oldest: usize = 0;
    for (held_streams[0..most], 0..) |h, i| {
        if (h) |x| {
            if (held_streams[oldest] == null or x.since < held_streams[oldest].?.since) oldest = i;
        } else if (free == null) free = i;
    }
    const i = free orelse at: {
        // Its socket shut: its writes fail, and its task lets the slot go.
        held_streams[oldest].?.stream.shutdown(io, .both) catch {};
        break :at oldest;
    };
    held_streams[i] = .{ .stream = stream, .since = held_count };
    return .{ .slot = i, .ticket = held_count };
}

/// A stream's slot given back, unless a newer stream has taken it.
fn letGoStream(io: Io, h: Held) void {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    if (held_streams[h.slot]) |x| if (x.since == h.ticket) {
        held_streams[h.slot] = null;
    };
}

/// How many streams are held now, for tests.
fn heldStreams(io: Io) usize {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    var n: usize = 0;
    for (held_streams) |h| if (h != null) {
        n += 1;
    };
    return n;
}

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

/// **A READ IS NAMED BY HOW IT ENDED** (170.7): whole is whole, whatever
/// fired beside it; one ended from outside by why; else its own end (too
/// large, unreadable, the budget), never a 408 for one that was not late.
/// An unreadable end is the shut socket's when something outside shut it.
fn verdict(own: Got, ended_by: Progress.Ended) Got {
    if (own != .unreadable) return own;
    return switch (ended_by) {
        .nothing => .unreadable,
        .deadline => .too_slow,
        .stalled => .stalled,
        .replaced => .replaced,
    };
}

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
fn neverRead(req: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const empty = try arena.create(std.Io.Reader);
    empty.* = .fixed("");
    req.server.reader.in = empty;
    req.head.expect = null;
    // Its body is still on the socket: the connection's last request.
    req.head.keep_alive = false;
}

/// The host's upload slots (body.zig), who reads in each, and their lock:
/// connections take and give back from their own tasks.
var slots: body_rule.Slots = .{};
var slot_readers: [body_rule.upload_slots]?*Progress = @splat(null);
/// When each slot's upload asked for it, in order (`nextAsk`): of a human's
/// uploads, the one that asked last is the retry (metal-vmm QUEUE 171's
/// simulator: two retries waiting took the slot from each other).
var slot_asked: [body_rule.upload_slots]u64 = @splat(0);
var asks: u64 = 0;

fn nextAsk(io: Io) u64 {
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
fn takeSlot(io: Io, who: u64, progress: *Progress, asked: u64) Taken {
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
    /// **THE BODY'S MEMORY IS ITS OWN, NOT THE ARENA'S** (metal-vmm QUEUE
    /// 177.2): an arena frees or grows in place only its newest allocation
    /// in a node, so a list that outgrew its node left its old copy behind
    /// (1.5-4.5x what was charged). This allocator frees what a growth
    /// leaves; the caller frees the list itself when the request is done.
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    state: union(enum) { reading, read: []u8, too_large, unreadable, busy } = .reading,

    fn read(self: *Whole, req: *std.http.Server.Request) void {
        // Memory that runs out is the host's busy (503, the client may try
        // again), never the client's unreadable body (metal-vmm QUEUE 172).
        self.state = self.readAll(req) catch |e| switch (e) {
            error.OutOfMemory => .busy,
            else => .unreadable,
        };
    }

    fn readAll(self: *Whole, req: *std.http.Server.Request) !@FieldType(Whole, "state") {
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

/// How long the work between requests sleeps when there is none.
pub const between_idle_ms: u64 = 50;
var never_stop: std.atomic.Value(bool) = .init(false);

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
    try facts.append(alloc, .{ .label = "kept streams ended by a stalled write", .value = try std.fmt.allocPrint(alloc, "{d} (a reader that stayed connected and stopped reading for {d} s)", .{ writes_ended_by_deadline.load(.acquire), kept_write_deadline_ms / std.time.ms_per_s }) });
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

test "portFrom: the variable's port, the default when it is unset, and a refusal when it is set and is not a port (metal-vmm QUEUE 198.6)" {
    try std.testing.expectEqual(@as(u16, 9001), try portFrom(null, 9001));
    try std.testing.expectEqual(@as(u16, 8080), try portFrom(" 8080\n", 9001));
    // Set, and not a port: metal stops on such a setting, and so does
    // Linux. It used to serve on the default, so a typo ran a second server
    // on the development one's port.
    for ([_][]const u8{ "/home/x/build/port", "70000", "0", "", " ", "+80", "8_080", "80x", "-1" }) |bad|
        try std.testing.expectError(error.NotAPort, portFrom(bad, 9001));
}

// ── a held body holds only its own connection: the turn never waits on the
// network (metal-vmm QUEUE 162, 166, 167, 169) ─────────────────────────────

/// A site for the host's own tests: `GET /` answers "ok", and a POST reads its
/// body (as a handler does, inside the turn) and answers its length. Its caps:
/// `/tiny` 4 bytes, `/upload`, `/upload-same` and `/refuses` past
/// `body_rule.before_turn_most` (uploads), anything else 64 KiB; `/same` and
/// `/upload-same` answer whether the body read is the one the host held. Its uploader is the `x-who` header; an
/// upload without one is a stranger's, which `/upload` answers 401 unread.
const TestSite = struct {
    pub const Started = struct {};
    pub fn start(_: Io, _: anytype) !Started {
        return .{};
    }
    pub fn bodyLimit(target: []const u8) u64 {
        if (std.mem.eql(u8, target, "/tiny")) return 4;
        if (std.mem.eql(u8, target, "/upload")) return 4 * body_rule.before_turn_most;
        if (std.mem.eql(u8, target, "/upload-same")) return 4 * body_rule.before_turn_most;
        if (std.mem.eql(u8, target, "/refuses")) return 4 * body_rule.before_turn_most;
        return 64 * 1024;
    }
    pub fn uploader(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator) !?[]const u8 {
        const who = try http.header(req, alloc, "x-who");
        if (who) |w| if (std.mem.eql(u8, w, "boom")) return error.StoreUnreadable;
        return who;
    }
    /// A background run's slices, each `between_slice_ms` under the turn.
    var slices_left: std.atomic.Value(u32) = .init(0);
    var slices_run: std.atomic.Value(u32) = .init(0);
    /// The thread of the first `between` call since it was last zeroed.
    var first_between_thread: std.atomic.Value(std.Thread.Id) = .init(0);
    pub fn between(io: Io, _: @import("webbox").site.Now) @import("webbox").site.Wake {
        _ = first_between_thread.cmpxchgStrong(0, std.Thread.getCurrentId(), .acq_rel, .acquire);
        if (slices_left.load(.acquire) == 0) return .idle;
        sleepMs(io, between_slice_ms) catch {};
        _ = slices_run.fetchAdd(1, .acq_rel);
        return if (slices_left.fetchSub(1, .acq_rel) > 1) .more else .idle;
    }
    fn streamFrame(_: []const u8, _: std.mem.Allocator, blob: []const u8) error{OutOfMemory}!?[]const u8 {
        return blob;
    }
    pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, b: *bus.Bus) !?bus.Kept {
        if (std.mem.eql(u8, try http.target(req, alloc), "/upload") and try uploader(req, io, alloc) == null) {
            try req.respond("who are you?\n", .{ .status = .unauthorized, .keep_alive = false });
            return null;
        }
        // Whether the body the handler reads is the one the host held, not
        // a copy (170.5): "same", or "copied".
        const t = try http.target(req, alloc);
        if (std.mem.eql(u8, t, "/same") or std.mem.eql(u8, t, "/upload-same")) {
            const held = http.held_body;
            const got = (try http.readLimitedBody(req, alloc, bodyLimit(t))) orelse return null;
            const same = if (held) |h| h.ptr == got.ptr and h.len == got.len else false;
            try req.respond(if (same) "same" else "copied", .{ .keep_alive = false });
            return null;
        }
        // A handler that refuses an upload without reading it.
        if (std.mem.eql(u8, try http.target(req, alloc), "/refuses")) {
            try http.redirect(req, "/login");
            return null;
        }
        // A stream kept after its body was read: the host serves it on.
        if (std.mem.eql(u8, try http.target(req, alloc), "/stream")) {
            _ = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return null;
            var held = b.hold(try b.open("test-stream"));
            defer held.release();
            var hbuf: [256]u8 = undefined;
            var body = try @import("webbox").sse.respond(req, &hbuf);
            try body.flush();
            held.keep(streamFrame, "");
            const kept = b.kept;
            b.kept = null;
            return kept;
        }
        // **KEEP-ALIVE'S ROUTES** (metal-vmm QUEUE 213): answered as a
        // handler answers by default, the connection left to the host: the
        // target back, after the body's length if there is one.
        // A handler that reads its body through std's reader, not the held
        // one, then answers close: the reader is left ready, so only the
        // answer's head says close (HeadWatch).
        // An answer of `big_kib` KiB, kept alive: what a client that never
        // reads makes the host write. Its size is the test's, never the
        // request's: a test site's route parses no number.
        if (std.mem.eql(u8, t, "/big")) {
            const page = try alloc.alloc(u8, big_kib * 1024);
            @memset(page, 'x');
            try req.respond(page, .{});
            return null;
        }
        if (std.mem.eql(u8, t, "/raw-close")) {
            var buf: [256]u8 = undefined;
            const r = try req.readerExpectContinue(&buf);
            _ = try r.allocRemaining(alloc, .limited(1024));
            try req.respond("read", .{ .keep_alive = false });
            return null;
        }
        if (std.mem.startsWith(u8, t, "/ka")) {
            const n = if (req.head.method == .POST) ((try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return null).len else 0;
            try req.respond(try std.fmt.allocPrint(alloc, "{s} {d}", .{ t, n }), .{});
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

test "linux_host: a head that is not HTTP is answered 400 and counted, never closed with no answer (metal-vmm QUEUE 172)" {
    for ([_][]const u8{
        "NOT HTTP AT ALL\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: twelve\r\n\r\n",
    }) |raw| {
        const before = edge.countOf(.head_malformed);
        const got = try exchange(raw);
        defer std.testing.allocator.free(got);
        errdefer std.debug.print("got: {s}\n", .{got});
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400"));
        try std.testing.expectEqual(before + 1, edge.countOf(.head_malformed));
    }
}

test "linux_host: a body read out of memory is the host's busy (503), never the client's unreadable (400) (metal-vmm QUEUE 172)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    const peer = try bench.listener.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    const ours = try bench.listener.accept(io);
    defer ours.close(io);
    var progress: Progress = .{ .stream = ours, .io = io };
    var reader: std.Io.Reader = .fixed("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000\r\n\r\nxxxx");
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var charged: u64 = 0;
    var whole: Whole = .{ .most = 2_000_000, .progress = &progress, .small = false, .charged = &charged, .gpa = failing.allocator() };
    whole.read(&req);
    try std.testing.expect(whole.state == .busy);
}

test "linux_host: an Expect a request cannot meet is answered 417, never no answer; a mixed-case 100-continue is met, and an exact one with no body is std's (metal-vmm QUEUE 175.4, 177.4)" {
    for ([_][]const u8{
        "GET / HTTP/1.1\r\nHost: x\r\nExpect: tea\r\n\r\n",
    }) |raw| {
        const got = try exchange(raw);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 417"));
    }
    const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-Continue\r\nContent-Length: 5\r\n\r\nhello");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n5"));
    // An exact 100-continue with no body is std's to answer, and answered
    // (177.4): the 100, then the page.
    // In any case (180.7): the host makes it std's exact one.
    for ([_][]const u8{ "100-continue", "100-Continue" }) |e| {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "GET / HTTP/1.1\r\nHost: x\r\nExpect: {s}\r\n\r\n", .{e});
        defer std.testing.allocator.free(raw);
        const plain = try exchange(raw);
        defer std.testing.allocator.free(plain);
        try std.testing.expect(std.mem.startsWith(u8, plain, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"));
    }
}

test "linux_host: a stream kept after its request's body gives the body's charge back when the route returns, not when the stream ends (metal-vmm QUEUE 176.3)" {
    // A kept stream notices its client has gone on the ping that fails to
    // send: pinged every 200 ms, not every 25 s, the test's end is not a wait.
    bus.Subscriber.keepalive_ms = 200;
    defer bus.Subscriber.keepalive_ms = bus.Subscriber.keepalive_s * std.time.ms_per_s;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client("POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ "x" ** 100);
    defer c.end(io);
    // The stream's head came: the stream is open. The route flushes that
    // head before it returns, so the charge comes back a moment after: it
    // is waited for, while the stream stays open.
    var buf: [512]u8 = undefined;
    var r = c.stream.reader(io, &buf);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(std.testing.allocator);
    while (std.mem.indexOf(u8, head.items, "\r\n\r\n") == null) {
        var one: [1]u8 = undefined;
        try r.interface.readSliceAll(&one);
        try head.append(std.testing.allocator, one[0]);
    }
    var waited: u32 = 0;
    while (small_held != 0 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), small_held);
}

test "linux_host: an upload that trickles, a few bytes at a time, is slow, not stalled: a stall is no byte, not no 4 KiB (metal-vmm QUEUE 176.7)" {
    stall_for_test_ms = 200;
    defer stall_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 300\r\n\r\n");
    try c.listen(io);
    // Ten bytes every 50 ms: 1.5 s in all, never 200 ms without a byte.
    var w = c.stream.writer(io, &.{});
    for (0..30) |_| {
        try w.interface.writeAll("0123456789");
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(50) }, io) catch {};
    }
    const done = c.answer.within(io, 3000);
    c.end(io);
    try std.testing.expect(done);
    try std.testing.expect(std.mem.endsWith(u8, c.answer.got(), "\r\n\r\n300"));
}

test "linux_host: a small body charged as it came gives its charge back when it is refused 408 (metal-vmm QUEUE 176.8)" {
    deadline_for_test_ms = 200;
    defer deadline_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // Forty bytes of a hundred, then nothing: charged forty, then 408.
    var c = try bench.client("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ "x" ** 40);
    try c.listen(io);
    const done = c.answer.within(io, 2000);
    c.end(io);
    try std.testing.expect(done);
    try std.testing.expect(std.mem.startsWith(u8, c.answer.got(), "HTTP/1.1 408"));
    try std.testing.expectEqual(@as(u64, 0), small_held);
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

test "linux_host: a human's older retry, still waiting, never takes over their newest upload: it is told 409 (metal-vmm QUEUE 171)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    const ann = body_rule.keyOf("ann");
    // The older retry asked first; the newest then took the slot.
    const older = nextAsk(io);
    const peer = try bench.listener.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    const ours = try bench.listener.accept(io);
    defer ours.close(io);
    var newest: Progress = .{ .stream = ours, .io = io };
    const held = switch (takeSlot(io, ann, &newest, nextAsk(io))) {
        .slot => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer giveBackSlot(io, held);
    slot_wait_for_test_ms = 100;
    defer slot_wait_for_test_ms = null;
    var waiting: Progress = .{ .stream = ours, .io = io };
    try std.testing.expect(takeSlot(io, ann, &waiting, older) == .replaced);
    try std.testing.expectEqual(Progress.Ended.nothing, newest.ended_by.load(.acquire));
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

test "linux_host: the body read before the turn reaches its handler as it is, never copied, small or an upload (metal-vmm QUEUE 176.8, 170.5)" {
    {
        const got = try exchange("POST /same HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nsame"));
    }
    {
        const got = try exchange("POST /upload-same HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 2000000\r\n\r\n" ++ "u" ** 2000000);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nsame"));
    }
}

test "linux_host: a read is named by how it ended, whatever fired beside it (metal-vmm QUEUE 176.8, 170.7)" {
    const whole: Got = .{ .whole = @constCast("x") };
    for ([_]Progress.Ended{ .nothing, .deadline, .stalled, .replaced }) |why| {
        // Its own end stands: whole, too large, the budget spent.
        try std.testing.expectEqual(std.meta.Tag(Got).whole, std.meta.activeTag(verdict(whole, why)));
        try std.testing.expectEqual(std.meta.Tag(Got).too_large, std.meta.activeTag(verdict(.too_large, why)));
        try std.testing.expectEqual(std.meta.Tag(Got).busy, std.meta.activeTag(verdict(.busy, why)));
    }
    // An unreadable end is the shut socket's, named by who shut it.
    try std.testing.expectEqual(std.meta.Tag(Got).unreadable, std.meta.activeTag(verdict(.unreadable, .nothing)));
    try std.testing.expectEqual(std.meta.Tag(Got).too_slow, std.meta.activeTag(verdict(.unreadable, .deadline)));
    try std.testing.expectEqual(std.meta.Tag(Got).stalled, std.meta.activeTag(verdict(.unreadable, .stalled)));
    try std.testing.expectEqual(std.meta.Tag(Got).replaced, std.meta.activeTag(verdict(.unreadable, .replaced)));
}

test "linux_host: an error before the turn once a slot is taken or a charge made is a 500, and gives both back (metal-vmm QUEUE 176.8)" {
    fail_after_read_for_test = true;
    defer fail_after_read_for_test = false;
    {
        const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500"));
        try std.testing.expectEqual(@as(u64, 0), small_held);
    }
    {
        const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\n0123456789");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500"));
        try std.testing.expectEqual(@as(usize, 0), slots.inUse());
    }
}

test "linux_host: a takeover just before the stall, and just after it fired: 409 before, 408 after, and the new upload read whole either way (metal-vmm QUEUE 176.8, 186.1)" {
    // **THE RACE MET** (186.1): the watcher ticks every 50 ms and the stall
    // is 600 ms, so silence is counted as it passes. A takeover at 450 ms
    // comes before the stall (the old is told 409); one at 800 ms comes
    // after it fired (the old was told 408, and its slot was given back).
    stall_for_test_ms = 600;
    defer stall_for_test_ms = null;
    tick_for_test_ms = 50;
    defer tick_for_test_ms = null;
    for ([_]struct { at_ms: i64, old: []const u8 }{ .{ .at_ms = 450, .old = "HTTP/1.1 409" }, .{ .at_ms = 800, .old = "HTTP/1.1 408" } }) |c| {
        var bench: Bench = undefined;
        try bench.init();
        defer bench.deinit();
        const io = bench.threaded.io();
        var first = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\nxx");
        try first.listen(io);
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(c.at_ms) }, io) catch {};
        var again = try bench.client("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\n0123");
        try again.listen(io);
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};
        var w = again.stream.writer(io, &.{});
        try w.interface.writeAll("456789");
        const done = again.answer.within(io, 3000);
        const old_told = first.answer.within(io, 3000);
        again.end(io);
        first.end(io);
        try std.testing.expect(done and old_told);
        try std.testing.expect(std.mem.endsWith(u8, again.answer.got(), "\r\n\r\n10"));
        if (!std.mem.startsWith(u8, first.answer.got(), c.old)) {
            std.debug.print("taken over at {d} ms: the old was told {s}\n", .{ c.at_ms, first.answer.got()[0..@min(12, first.answer.got().len)] });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(@as(usize, 0), slots.inUse());
    }
}

/// A test's allocator that asks, at each allocation or growth, whether
/// what is held then is within what the small budget has charged (beyond
/// what it held before the test).
const HeldPeak = struct {
    child: std.mem.Allocator,
    held_before: u64,
    live: u64 = 0,
    over: ?struct { held: u64, charged: u64 } = null,

    fn allocator(self: *HeldPeak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn judge(self: *HeldPeak, held: u64) void {
        const charged = small_held - self.held_before;
        if (held > charged and self.over == null) self.over = .{ .held = held, .charged = charged };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *HeldPeak = @ptrCast(@alignCast(ctx));
        self.judge(self.live + len);
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *HeldPeak = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, new_len, ra)) return false;
        self.live = self.live - m.len + new_len;
        self.judge(self.live);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *HeldPeak = @ptrCast(@alignCast(ctx));
        // A remap may copy: both rooms, for that moment.
        if (new_len > m.len) self.judge(self.live + new_len);
        const p = self.child.rawRemap(m, a, new_len, ra) orelse return null;
        self.live = self.live - m.len + new_len;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *HeldPeak = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

test "linux_host: a small body's read holds no more memory than it charged (metal-vmm QUEUE 177.2)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    const peer = try bench.listener.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    const ours = try bench.listener.accept(io);
    defer ours.close(io);
    var progress: Progress = .{ .stream = ours, .io = io };
    const n = 300 * 1024;
    const raw = try std.fmt.allocPrint(std.testing.allocator, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{n});
    defer std.testing.allocator.free(raw);
    const whole_raw = try std.mem.concat(std.testing.allocator, u8, &.{ raw, &([_]u8{'x'} ** n) });
    defer std.testing.allocator.free(whole_raw);
    var reader: std.Io.Reader = .fixed(whole_raw);
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    // What the read holds, counted where it is held, at every moment: the
    // old room beside the new one while a growth copies too (180.6).
    var counted: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer _ = counted.deinit();
    var peak: HeldPeak = .{ .child = counted.allocator(), .held_before = small_held };
    var charged: u64 = 0;
    defer unchargeSmall(io, charged);
    var whole: Whole = .{ .most = n, .progress = &progress, .small = true, .charged = &charged, .gpa = peak.allocator() };
    defer whole.list.deinit(peak.allocator());
    whole.read(&req);
    try std.testing.expect(whole.state == .read);
    try std.testing.expectEqual(@as(u64, n), charged);
    if (peak.over) |o| {
        std.debug.print("held {d} bytes while {d} were charged\n", .{ o.held, o.charged });
        return error.TestUnexpectedResult;
    }
}

test "linux_host: a request head not finished within its deadline is a 408, counted, and one finished just before it is served (metal-vmm QUEUE 184)" {
    head_for_test_ms = 400;
    defer head_for_test_ms = null;
    tick_for_test_ms = 50;
    defer tick_for_test_ms = null;
    for ([_]struct { rest_after_ms: ?i64, want: []const u8 }{ .{ .rest_after_ms = 200, .want = "HTTP/1.1 200" }, .{ .rest_after_ms = null, .want = "HTTP/1.1 408" } }) |c| {
        var bench: Bench = undefined;
        try bench.init();
        defer bench.deinit();
        const io = bench.threaded.io();
        // Half a head, then (or never) the rest.
        var half = try bench.client("GET / HTTP/1.1\r\nHo");
        try half.listen(io);
        if (c.rest_after_ms) |ms| {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
            var w = half.stream.writer(io, &.{});
            try w.interface.writeAll("st: x\r\n\r\n");
        }
        const answered = half.answer.within(io, 3000);
        half.end(io);
        try std.testing.expect(answered);
        if (!std.mem.startsWith(u8, half.answer.got(), c.want)) {
            std.debug.print("the rest after {?d} ms: told {s}\n", .{ c.rest_after_ms, half.answer.got()[0..@min(12, half.answer.got().len)] });
            return error.TestUnexpectedResult;
        }
    }
}

test "linux_host: a kept stream whose reader stays connected but stops reading ends at its write's deadline (metal-vmm QUEUE 198.6)" {
    write_deadline_for_test_ms = 300;
    defer write_deadline_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client("POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx");
    defer c.end(io);
    var waited: u32 = 0;
    while (heldStreams(io) < 1 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), heldStreams(io));
    // The reader reads nothing more. Events far past what the sockets
    // buffer: the host's write blocks, and a write with no deadline blocks
    // for good (the mailbox's overflow is only looked at between writes).
    const big = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'e');
    waited = 0;
    while (heldStreams(io) > 0 and waited < 5000) : (waited += 20) {
        bench.hub.publish("test-stream", big);
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(20) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), heldStreams(io));
}

test "linux_host: at most streams_most streams are held: one more ends the oldest, as the kernel does (metal-vmm QUEUE 184)" {
    // A kept stream notices its client has gone on the ping that fails to
    // send: pinged every 200 ms, not every 25 s, the test's end is not a wait.
    bus.Subscriber.keepalive_ms = 200;
    defer bus.Subscriber.keepalive_ms = bus.Subscriber.keepalive_s * std.time.ms_per_s;
    streams_most_for_test = 2;
    defer streams_most_for_test = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var clients: [3]@TypeOf(try bench.client("")) = undefined;
    for (&clients, 0..) |*c, k| {
        c.* = try bench.client("POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx");
        // Each held before the next opens, so the first is the oldest.
        var buf: [512]u8 = undefined;
        var r = c.stream.reader(io, &buf);
        var seen: usize = 0;
        var tail: [4]u8 = @splat(0);
        while (!std.mem.eql(u8, &tail, "\r\n\r\n")) : (seen += 1) {
            var one: [1]u8 = undefined;
            try r.interface.readSliceAll(&one);
            std.mem.copyForwards(u8, tail[0..3], tail[1..4]);
            tail[3] = one[0];
        }
        var waited: u32 = 0;
        while (heldStreams(io) < @min(k + 1, 2) and waited < 2000) : (waited += 10) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
        }
    }
    defer for (&clients) |*c| c.end(io);
    // The first's connection is ended: its read meets the end.
    var buf: [64]u8 = undefined;
    var r = clients[0].stream.reader(io, &buf);
    var ended = false;
    var waited: u32 = 0;
    while (!ended and waited < 3000) : (waited += 1) {
        var one: [1]u8 = undefined;
        r.interface.readSliceAll(&one) catch {
            ended = true;
        };
    }
    try std.testing.expect(ended);
    try std.testing.expectEqual(@as(usize, 2), heldStreams(io));
}

test "linux_host: /admin/host says how many syncs of the data failed, and how many kept streams ended at their write's deadline (metal-vmm QUEUE 198.6)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const before = durable.failures.load(.acquire);
    defer durable.failures.store(before, .release);
    durable.failures.store(3, .release);
    const facts = try linuxFacts(threaded.io(), arena.allocator());
    var syncs: ?[]const u8 = null;
    var streams: ?[]const u8 = null;
    for (facts) |f| {
        if (std.mem.eql(u8, f.label, "data syncs failed")) syncs = f.value;
        if (std.mem.eql(u8, f.label, "kept streams ended by a stalled write")) streams = f.value;
    }
    try std.testing.expect(std.mem.startsWith(u8, syncs.?, "3"));
    try std.testing.expect(streams != null);
}

test "linux_host: freeSpaceAt asks statfs itself: a real folder's volume has room and a size, and a missing one says nothing (metal-vmm QUEUE 198.6)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir);
    const s = freeSpaceAt(dir).?;
    try std.testing.expect(s.total > 0 and s.free <= s.total);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ dir, "missing" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(?free_space.Space, null), freeSpaceAt(missing));
}

test "linux_host: /admin/host's process facts come from the real getpid and /proc/self/status (metal-vmm QUEUE 198.6)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const facts = try linuxFacts(threaded.io(), arena.allocator());
    var pid_seen = false;
    var resident: ?[]const u8 = null;
    const pid = try std.fmt.allocPrint(arena.allocator(), "pid {d}", .{std.os.linux.getpid()});
    for (facts) |f| {
        if (std.mem.eql(u8, f.label, "host") and std.mem.indexOf(u8, f.value, pid) != null) pid_seen = true;
        if (std.mem.eql(u8, f.label, "memory now (resident)")) resident = f.value;
        try std.testing.expect(!std.mem.eql(u8, f.label, "memory")); // the /proc read's failure
    }
    try std.testing.expect(pid_seen);
    try std.testing.expect(std.mem.endsWith(u8, resident.?, "kB"));
}

// ── work between requests (metal-vmm QUEUE 211, step 5) ─────────────────

const between_slice_ms: u64 = 30;

test "linux_host: a request that arrives mid-run waits at most one slice of the work between requests, and the run goes on after it (metal-vmm QUEUE 211)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // Thirty slices of 30 ms: most of a second of background work.
    TestSite.slices_left.store(30, .release);
    TestSite.slices_run.store(0, .release);
    var stop: std.atomic.Value(bool) = .init(false);
    const runner = try std.Thread.spawn(.{}, TestHost.betweenLoop, .{ io, &stop });
    defer {
        stop.store(true, .release);
        runner.join();
        TestSite.slices_left.store(0, .release);
    }
    sleepMs(io, 100) catch {};
    var worst: i64 = 0;
    for (0..5) |_| {
        const began = Io.Clock.now(.awake, io).nanoseconds;
        var c = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        try c.listen(io);
        const answered = c.answer.within(io, 2000);
        const took: i64 = @intCast(@divTrunc(Io.Clock.now(.awake, io).nanoseconds - began, std.time.ns_per_ms));
        c.end(io);
        try std.testing.expect(answered);
        worst = @max(worst, took);
        sleepMs(io, 45) catch {};
    }
    // One slice (30 ms) and the request's own time, never the run's.
    if (worst > 3 * between_slice_ms) {
        std.debug.print("a request waited {d} ms for the turn\n", .{worst});
        return error.TestUnexpectedResult;
    }
    // And the run went on between them, not stopped by them.
    try std.testing.expect(TestSite.slices_run.load(.acquire) >= 5);
}

test "linux_host: the work between requests is first stepped on the starting thread, before any request, and then goes on on its own thread (metal-vmm QUEUE 222)" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    TestSite.first_between_thread.store(0, .release);
    TestSite.slices_left.store(3, .release);
    TestSite.slices_run.store(0, .release);
    var stop: std.atomic.Value(bool) = .init(false);
    TestHost.startBetween(io, &stop);
    defer {
        stop.store(true, .release);
        // The thread sleeps at most `between_idle_ms` before it sees the stop.
        sleepMs(io, 2 * between_idle_ms) catch {};
        TestSite.slices_left.store(0, .release);
    }
    try std.testing.expectEqual(std.Thread.getCurrentId(), TestSite.first_between_thread.load(.acquire));
    try std.testing.expect(TestSite.slices_run.load(.acquire) >= 1);
    // And the rest of the run is stepped on the thread.
    var waited: u32 = 0;
    while (TestSite.slices_run.load(.acquire) < 3 and waited < 100) : (waited += 1) sleepMs(io, 10) catch {};
    try std.testing.expectEqual(@as(u32, 3), TestSite.slices_run.load(.acquire));
}

// ── keep-alive (metal-vmm QUEUE 213) ────────────────────────────────────────

/// Everything a client is sent on one connection, read on a task of its own
/// until the host closes it.
const Talk = struct {
    bytes: [16 * 1024]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),

    fn read(self: *Talk, io: Io, stream: net.Stream) void {
        var buf: [256]u8 = undefined;
        var r = stream.reader(io, &buf);
        while (true) {
            const at = self.len.load(.acquire);
            if (at == self.bytes.len) break;
            var bufs: [1][]u8 = .{self.bytes[at..]};
            const n = r.interface.readVec(&bufs) catch break;
            self.len.store(at + n, .release);
        }
        self.closed.store(true, .release);
    }

    fn got(self: *const Talk) []const u8 {
        return self.bytes[0..self.len.load(.acquire)];
    }

    /// Whether `n` answers have come whole (each with its body) within `ms`.
    fn answers(self: *const Talk, io: Io, n: usize, ms: i64) bool {
        var waited: i64 = 0;
        while (waited < ms) : (waited += 10) {
            if (countAnswers(self.got()) >= n) return true;
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
        }
        return countAnswers(self.got()) >= n;
    }

    /// Whether the host closed the connection within `ms`.
    fn closedWithin(self: *const Talk, io: Io, ms: i64) bool {
        var waited: i64 = 0;
        while (!self.closed.load(.acquire) and waited < ms) : (waited += 10) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
        }
        return self.closed.load(.acquire);
    }
};

/// The answers in `bytes` that have come whole: a head, and its body by its
/// content-length.
fn countAnswers(bytes: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "\r\n\r\n")) |end| {
        const head = bytes[at..end];
        const length: usize = if (std.ascii.indexOfIgnoreCase(head, "content-length: ")) |i| std.fmt.parseInt(usize, std.mem.sliceTo(head[i + 16 ..], '\r'), 10) catch 0 else 0;
        if (bytes.len < end + 4 + length) break;
        n += 1;
        at = end + 4 + length;
    }
    return n;
}

/// A client on one connection the host serves on a task of its own, its
/// answers read as they come.
const Conn = struct {
    stream: net.Stream,
    served: std.Thread,
    talk: Talk = .{},
    reading: std.Thread = undefined,

    fn open(self: *Conn, bench: *Bench, alloc: std.mem.Allocator) !void {
        const io = bench.threaded.io();
        self.* = .{ .stream = try bench.listener.socket.address.connect(io, .{ .mode = .stream }), .served = undefined };
        self.served = try std.Thread.spawn(.{}, struct {
            fn f(i: Io, a: std.mem.Allocator, hub: *bus.Hub, s: net.Stream) void {
                TestHost.serveConn(i, a, hub, s);
            }
        }.f, .{ io, alloc, &bench.hub, try bench.listener.accept(io) });
        self.reading = try std.Thread.spawn(.{}, Talk.read, .{ &self.talk, io, self.stream });
    }

    fn send(self: *Conn, io: Io, raw: []const u8) !void {
        var w = self.stream.writer(io, &.{});
        try w.interface.writeAll(raw);
    }

    fn end(self: *Conn, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.served.join();
        self.reading.join();
        self.stream.close(io);
    }
};

test "linux_host: two requests on one connection are both answered, and it stays open between them (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "GET /ka-one HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 1, 2000));
    try std.testing.expect(std.mem.indexOf(u8, c.talk.got(), "connection: close") == null);
    try std.testing.expect(!c.talk.closedWithin(io, 100));
    try c.send(io, "POST /ka-two HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    try std.testing.expect(c.talk.answers(io, 2, 2000));
    try std.testing.expect(std.mem.endsWith(u8, c.talk.got(), "/ka-two 5"));
}

test "linux_host: a pipelined pair is answered in order, on one connection (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "POST /ka-a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /ka-b HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 2, 2000));
    const a = std.mem.indexOf(u8, c.talk.got(), "/ka-a 3").?;
    const b = std.mem.indexOf(u8, c.talk.got(), "/ka-b 0").?;
    try std.testing.expect(a < b);
}

test "linux_host: the memory a request took is given back when it is answered, not when its connection closes (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var counted: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .thread_safe = true }) = .init;
    defer _ = counted.deinit();
    var c: Conn = undefined;
    try c.open(&bench, counted.allocator());
    defer c.end(io);
    for (0..3) |i| {
        try c.send(io, "POST /ka-body HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
        try std.testing.expect(c.talk.answers(io, i + 1, 2000));
        // Back to nothing held, soon after the answer.
        var waited: i64 = 0;
        while (counted.total_requested_bytes != 0 and waited < 2000) : (waited += 10) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
        }
        if (counted.total_requested_bytes != 0) {
            std.debug.print("after answer {d}, still held: {d} bytes\n", .{ i + 1, counted.total_requested_bytes });
            return error.TestUnexpectedResult;
        }
    }
}

test "linux_host: an idle connection is closed at the idle timeout, with no answer (metal-vmm QUEUE 213)" {
    idle_for_test_ms = 300;
    defer idle_for_test_ms = null;
    tick_for_test_ms = 20;
    defer tick_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "GET /ka-one HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 1, 2000));
    try std.testing.expect(!c.talk.closedWithin(io, 150));
    try std.testing.expect(c.talk.closedWithin(io, 2000));
    try std.testing.expectEqual(@as(usize, 1), countAnswers(c.talk.got()));
    try std.testing.expect(std.mem.indexOf(u8, c.talk.got(), "408") == null);
}

test "linux_host: a second request that stalls holds only its own connection, never the turn (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "GET /ka-one HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 1, 2000));
    // Half a second head, and then a body that never comes.
    try c.send(io, "GET /ka-two HTTP/1.1\r\nHo");
    var d: Conn = undefined;
    try d.open(&bench, std.testing.allocator);
    defer d.end(io);
    try d.send(io, "POST /ka-three HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhal");
    var other = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try other.listen(io);
    const prompt = other.answer.within(io, 2000);
    other.end(io);
    try std.testing.expect(prompt);
    try std.testing.expect(std.mem.startsWith(u8, other.answer.got(), "HTTP/1.1 200"));
}

test "linux_host: the client's connection: close is honoured, and so is a handler's (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    for ([_][]const u8{
        "GET /ka-one HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        // TestSite's "/" answers with respond's own keep_alive = false.
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        // And after reading a body.
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi",
        // And after reading it through std's reader, which leaves it ready:
        // only the answer's head says close.
        "POST /raw-close HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi",
    }) |raw| {
        var c: Conn = undefined;
        try c.open(&bench, std.testing.allocator);
        defer c.end(io);
        try c.send(io, raw);
        try std.testing.expect(c.talk.answers(io, 1, 2000));
        try std.testing.expect(std.mem.indexOf(u8, c.talk.got(), "connection: close") != null);
        try std.testing.expect(c.talk.closedWithin(io, 1000));
    }
}

test "linux_host: a connection serves at most requests_most requests, the last one saying close (metal-vmm QUEUE 213)" {
    requests_most_for_test = 2;
    defer requests_most_for_test = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "GET /ka-1 HTTP/1.1\r\nHost: x\r\n\r\nGET /ka-2 HTTP/1.1\r\nHost: x\r\n\r\nGET /ka-3 HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 2, 2000));
    try std.testing.expect(c.talk.closedWithin(io, 1000));
    try std.testing.expectEqual(@as(usize, 2), countAnswers(c.talk.got()));
    const second = std.mem.lastIndexOf(u8, c.talk.got(), "HTTP/1.1 200").?;
    try std.testing.expect(std.mem.indexOf(u8, c.talk.got()[second..], "connection: close") != null);
}

test "linux_host: at most kept_open_most connections are kept open: past it, an answer says close (metal-vmm QUEUE 213)" {
    kept_open_most_for_test = 1;
    defer kept_open_most_for_test = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var a: Conn = undefined;
    try a.open(&bench, std.testing.allocator);
    try a.send(io, "GET /ka-a HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(a.talk.answers(io, 1, 2000));
    try std.testing.expect(!a.talk.closedWithin(io, 100));
    var b: Conn = undefined;
    try b.open(&bench, std.testing.allocator);
    defer b.end(io);
    try b.send(io, "GET /ka-b HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(b.talk.answers(io, 1, 2000));
    try std.testing.expect(std.mem.indexOf(u8, b.talk.got(), "connection: close") != null);
    try std.testing.expect(b.talk.closedWithin(io, 1000));
    // A closed, its place is free again.
    a.end(io);
    var waited: i64 = 0;
    while (kept_open.load(.acquire) != 0 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), kept_open.load(.acquire));
}

test "linux_host: a request refused before the turn closes its connection: what was pipelined after it is never answered (metal-vmm QUEUE 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c: Conn = undefined;
    try c.open(&bench, std.testing.allocator);
    defer c.end(io);
    try c.send(io, "POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789GET /ka-after HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(c.talk.answers(io, 1, 2000));
    try std.testing.expect(c.talk.closedWithin(io, 1000));
    try std.testing.expect(std.mem.indexOf(u8, c.talk.got(), "/ka-after") == null);
}

// ── a client that never reads (the box's cold review of 213, finding 1) ──

/// The size of TestSite's `/big` answer, in KiB.
var big_kib: usize = 0;

/// A client that pipelines `n` requests for `/big`, `kib` KiB each, with a
/// small receive buffer, and reads none of the answers.
fn neverReads(bench: *Bench, n: usize, kib: usize) !Client {
    big_kib = kib;
    const io = bench.threaded.io();
    const stream = try bench.listener.socket.address.connect(io, .{ .mode = .stream });
    const small: c_int = 4096;
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&small)) catch {};
    const served = try std.Thread.spawn(.{}, serveForTest, .{ io, &bench.hub, try bench.listener.accept(io) });
    var w = stream.writer(io, &.{});
    for (0..n) |_| w.interface.writeAll("GET /big HTTP/1.1\r\nHost: x\r\n\r\n") catch break;
    return .{ .stream = stream, .served = served };
}

/// The never-reading client gone: closed with its answers unread, which
/// resets the connection (a shutdown would leave the host's write waiting
/// on a window that never opens), then its host task joined.
fn endUnread(io: Io, c: *Client) void {
    c.stream.close(io);
    c.served.join();
}

test "linux_host: a client that pipelines answers and never reads them holds up no one else: the turn never waits on its socket (the box's cold review of 213)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // Forty half-megabyte answers asked for, none read: far past what the
    // sockets' buffers hold.
    var stuck = try neverReads(&bench, 40, 512);
    sleepMs(io, 300) catch {};
    var other = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try other.listen(io);
    const prompt = other.answer.within(io, 2000);
    // The stuck one let go first: the other's task may be waiting on it.
    endUnread(io, &stuck);
    other.end(io);
    try std.testing.expect(prompt);
    try std.testing.expect(std.mem.startsWith(u8, other.answer.got(), "HTTP/1.1 200"));
}

test "linux_host: an answer past what the turn holds, to a client that never reads, holds the turn no longer than the in-turn write deadline (the box's cold review of 213)" {
    turn_write_deadline_for_test_ms = 300;
    defer turn_write_deadline_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // Eight megabytes in one answer: past `held_most`, written in the turn.
    var stuck = try neverReads(&bench, 1, 8 * 1024);
    sleepMs(io, 100) catch {};
    const began = Io.Clock.now(.awake, io).nanoseconds;
    var other = try bench.client("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try other.listen(io);
    const prompt = other.answer.within(io, 3000);
    const took = @divTrunc(Io.Clock.now(.awake, io).nanoseconds - began, std.time.ns_per_ms);
    endUnread(io, &stuck);
    other.end(io);
    try std.testing.expect(prompt);
    if (took > 1500) {
        std.debug.print("the other client waited {d} ms\n", .{took});
        return error.TestUnexpectedResult;
    }
}
