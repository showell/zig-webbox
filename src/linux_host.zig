//! linux_host: a site served as a Linux process. Part of the `webbox` library,
//! and host-only: sockets, a thread pool, the environment, /proc. Nothing the
//! site reaches imports it (the portability lint holds that); an application
//! calls it from its `main`, and a machine with no operating system replaces
//! all of it while calling the same `start` and `route`.
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
const Io = std.Io;
const net = std.Io.net;
const mem_meter = @import("mem_meter.zig");
const bind = @import("bind.zig");
const bus = @import("bus.zig");
const edge = @import("edge.zig");
const http = @import("http.zig");
const host_facts = @import("host_facts.zig");
const free_space = @import("free_space.zig");
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
    /// The largest request body any route takes: every body is read whole
    /// before the turn (metal-vmm QUEUE 162), and one past this is a 413
    /// before a byte of it is read.
    largest_body: usize,
    /// How the data volume's free space is read, given the environment (an
    /// application may have a setting of its own for it, and say so).
    free_space: *const fn (env: *const std.process.Environ.Map) free_space.FreeSpace,
};

/// `S` is a site (site.zig's `Site(App)`, or a namespace that re-exports one):
/// `start`, `route`, `Started`.
pub fn Server(comptime S: type) type {
    inline for (.{ "start", "route", "Started" }) |name| {
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
            largest_body = options.largest_body;
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
                    // Pool exhausted / concurrency unavailable: fall back to
                    // serving this one inline rather than dropping it. A kept
                    // stream served inline holds the accept loop for its life.
                    std.debug.print("spawn failed ({s}); serving inline\n", .{@errorName(e)});
                    serveConn(io, alloc, hub, stream);
                };
            }
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
            // **EVERY BODY ARRIVES BEFORE THE TURN** (metal-vmm QUEUE 162):
            // read here, whole, under `body_deadline_ms` and `largest_body`,
            // so a client slow to send one, or one that never finishes it
            // (chunked, a Content-Length longer than it sends, waiting on
            // `100-continue`), holds up only its own connection. The handler
            // then reads it from memory, as it would have from the socket.
            switch (try readBodyBeforeTurn(io, arena.allocator(), &req, stream)) {
                .in_memory, .none => {},
                .too_large => return refuse(&req, .body_too_large, "request body too large\n"),
                .unreadable => return refuse(&req, .body_unreadable, "read body\n"),
                .too_slow => return refuse(&req, .body_too_slow, "request body too slow\n"),
            }
            req.head.keep_alive = false; // force `connection: close` without touching each handler
            var b = bus.Bus.of(hub);
            var peer_buf: [64]u8 = undefined;
            b.peer = peerText(&peer_buf, stream.socket.address);
            turn.lockUncancelable(io);
            const routed = S.route(&req, io, arena.allocator(), &b);
            turn.unlock(io);
            // A stream the handler kept is route's answer, served here, on
            // this connection's own task, until its client goes away; on an
            // error route has dropped it (metal-vmm QUEUE 157(a)).
            if (try routed) |kept| bus.serveKept(hub, kept, &sw.interface);
        }
    };
}

/// How long a request's body may take to arrive, whole, before the turn:
/// past it the request is a 408, and its connection closes. A `var` so a
/// test can shorten it.
pub var body_deadline_ms: i64 = 10_000;

/// The largest body any route takes (the application's own caps are each
/// at most this, and are checked again by its handlers): past it a request
/// is a 413 before a byte of its body is read. Set from `Options` by `run`.
pub var largest_body: usize = 1 << 20;

const BodyRead = enum { none, in_memory, too_large, unreadable, too_slow };

/// The request's body read into `arena`, before the turn, and the request
/// left to its handler as if it had not been: the head copied out of the
/// read buffer (a body read reuses it), the body served from memory under
/// the head's own framing, now a plain Content-Length.
fn readBodyBeforeTurn(io: Io, arena: std.mem.Allocator, req: *std.http.Server.Request, stream: net.Stream) !BodyRead {
    if (!req.head.method.requestHasBody()) return .none;
    if (req.head.transfer_encoding == .none and req.head.content_length == null) return .none;
    if (req.head.content_length) |len| if (len > largest_body) return .too_large;
    const head = try arena.dupe(u8, req.head_buffer);
    var whole: Whole = .{};
    {
        // The read and a timer, whichever ends first: past the deadline the
        // socket is shut, which ends the read.
        var buffer: [2]Raced = undefined;
        var race: Io.Select(Raced) = .init(io, &buffer);
        race.concurrent(.read, Whole.read, .{ &whole, req, arena }) catch {
            // No unit of concurrency to spare: read with no deadline, still
            // before the turn.
            whole.read(req, arena);
            race.cancelDiscard();
        };
        if (whole.state == .reading) {
            race.concurrent(.timer, timer, .{ io, body_deadline_ms }) catch {};
            const first = race.await() catch .timer;
            if (first == .timer) stream.shutdown(io, .recv) catch {};
            // The read has ended either way once this returns.
            race.cancelDiscard();
            if (first == .timer) whole.state = .too_slow;
        }
    }
    const body = switch (whole.state) {
        .read => |b| b,
        .reading => unreachable, // the read ended, or the timer said so
        .too_large => return .too_large,
        .unreadable => return .unreadable,
        .too_slow => return .too_slow,
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
    return .in_memory;
}

const Raced = union(enum) { read: void, timer: void };

/// A request refused before the turn, its connection closed after: what of
/// its body is unread stays unread. The answer is best-effort, as the
/// client may be gone.
fn refuse(req: *std.http.Server.Request, kind: edge.RejectKind, msg: []const u8) void {
    req.head.keep_alive = false;
    edge.reject(req, kind, msg) catch {};
}

fn timer(io: Io, ms: i64) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
}

/// A body being read whole, and how its read ended.
const Whole = struct {
    state: union(enum) { reading, read: []u8, too_large, unreadable, too_slow } = .reading,

    fn read(self: *Whole, req: *std.http.Server.Request, arena: std.mem.Allocator) void {
        var transfer: [4096]u8 = undefined;
        const r = req.readerExpectContinue(&transfer) catch {
            self.state = .unreadable;
            return;
        };
        self.state = if (r.allocRemaining(arena, .limited(largest_body + 1))) |b| .{ .read = b } else |e| switch (e) {
            error.StreamTooLong => .too_large,
            else => .unreadable,
        };
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

// ── a held body holds only its own connection (metal-vmm QUEUE 162) ─────────

/// A site of two routes for the host's own tests: `GET /` answers "ok", and
/// a POST reads its body (as a handler does, inside the turn) and answers
/// its length.
const TestSite = struct {
    pub const Started = struct {};
    pub fn start(_: Io, _: anytype) !Started {
        return .{};
    }
    pub fn route(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, _: *bus.Bus) !?bus.Kept {
        if (req.head.method == .POST) {
            const body = (try http.readLimitedBody(req, alloc, 1 << 20)) orelse return null;
            try req.respond(try std.fmt.allocPrint(alloc, "{d}", .{body.len}), .{ .keep_alive = false });
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
};

fn heldBodyHoldsOnlyItsConnection(held_head: []const u8) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hub = bus.Hub.init(io, std.testing.allocator);
    defer hub.entries.deinit(std.testing.allocator);
    const any: net.IpAddress = try .parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const at = listener.socket.address;

    // A client sends a head whose body it never finishes.
    const held = try at.connect(io, .{ .mode = .stream });
    var held_writer = held.writer(io, &.{});
    try held_writer.interface.writeAll(held_head);
    const held_served = try std.Thread.spawn(.{}, serveForTest, .{ io, &hub, try listener.accept(io) });
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io) catch {};

    // Another client's GET / is still served, promptly.
    const other = try at.connect(io, .{ .mode = .stream });
    var other_writer = other.writer(io, &.{});
    try other_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    const other_served = try std.Thread.spawn(.{}, serveForTest, .{ io, &hub, try listener.accept(io) });
    var answer: Answer = .{};
    const reading = try std.Thread.spawn(.{}, Answer.read, .{ &answer, io, other });
    const prompt = answer.within(io, 2000);

    // Let everything go, whatever came of it.
    held.close(io);
    held_served.join();
    other_served.join();
    reading.join();
    other.close(io);
    try std.testing.expect(prompt);
    try std.testing.expect(std.mem.startsWith(u8, answer.bytes[0..answer.len], "HTTP/1.1 200"));
}

test "linux_host: a chunked body held open holds only its own connection, not the turn" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n");
}

test "linux_host: a body shorter than its Content-Length holds only its own connection" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n0123456789");
}

test "linux_host: a body waiting on 100-continue holds only its own connection" {
    try heldBodyHoldsOnlyItsConnection("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 100\r\n\r\n");
}

/// What one request gets from the host, whole, within two seconds.
fn exchange(raw: []const u8) ![]const u8 {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hub = bus.Hub.init(io, std.testing.allocator);
    defer hub.entries.deinit(std.testing.allocator);
    const any: net.IpAddress = try .parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var w = client.writer(io, &.{});
    try w.interface.writeAll(raw);
    const served = try std.Thread.spawn(.{}, serveForTest, .{ io, &hub, try listener.accept(io) });
    var answer: Answer = .{};
    const reading = try std.Thread.spawn(.{}, Answer.read, .{ &answer, io, client });
    const prompt = answer.within(io, 2000);
    client.shutdown(io, .both) catch {};
    served.join();
    reading.join();
    try std.testing.expect(prompt);
    return std.testing.allocator.dupe(u8, answer.bytes[0..answer.len]);
}

test "linux_host: a body never finished is a 408 at the deadline, and its connection closes" {
    const saved = body_deadline_ms;
    defer body_deadline_ms = saved;
    body_deadline_ms = 200;
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

test "linux_host: a body past the largest any route takes is a 413, unread" {
    const saved = largest_body;
    defer largest_body = saved;
    largest_body = 4;
    const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 413"));
    const chunked = try exchange("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    defer std.testing.allocator.free(chunked);
    try std.testing.expect(std.mem.startsWith(u8, chunked, "HTTP/1.1 413"));
}
