//! linux_host.zig's tests, and the sites and benches they run the host on.
//! They reach the host's insides only through `for_tests` (its own and
//! Server's), so the host's interface is what an application sees.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;
const mem_meter = @import("webbox").mem_meter;
const bus = @import("webbox").bus;
const edge = @import("webbox").edge;
const http = @import("webbox").http;
const body_rule = @import("webbox").body;
const host_facts = @import("webbox").host_facts;
const free_space = @import("webbox").free_space;
const linux_writes = @import("linux_writes.zig");
const linux_streams = @import("linux_streams.zig");
const linux_reads = @import("linux_reads.zig");
const host = @import("linux_host.zig");

test "portFrom: the variable's port, the default when it is unset, and a refusal when it is set and is not a port (metal-vmm QUEUE 198.6)" {
    try std.testing.expectEqual(@as(u16, 9001), try host.for_tests.portFrom(null, 9001));
    try std.testing.expectEqual(@as(u16, 8080), try host.for_tests.portFrom(" 8080\n", 9001));
    // Set, and not a port: metal stops on such a setting, and so does
    // Linux. It used to serve on the default, so a typo ran a second server
    // on the development one's port.
    for ([_][]const u8{ "/home/x/build/port", "70000", "0", "", " ", "+80", "8_080", "80x", "-1" }) |bad|
        try std.testing.expectError(error.NotAPort, host.for_tests.portFrom(bad, 9001));
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
        host.for_tests.sleepMs(io, between_slice_ms) catch {};
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
        // A background run started by a request, as a script route starts
        // one: three slices, stepped by the between thread.
        if (std.mem.eql(u8, t, "/start-run")) {
            slices_left.store(3, .release);
            try req.respond("started\n", .{ .keep_alive = false });
            return null;
        }
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
        // answer's head says close (host.for_tests.HeadWatch).
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

const TestHost = host.Server(TestSite);

/// One served connection's task, for a test: the host's own handling.
fn serveForTest(io: Io, hub: *bus.Hub, stream: net.Stream) void {
    TestHost.for_tests.serveConn(io, std.testing.allocator, hub, stream);
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
    linux_reads.deadline_for_test_ms = 200;
    defer linux_reads.deadline_for_test_ms = null;
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
    linux_reads.deadline_for_test_ms = 200;
    defer linux_reads.deadline_for_test_ms = null;
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
    var progress: linux_reads.Progress = .{ .stream = ours, .io = io };
    var reader: std.Io.Reader = .fixed("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000\r\n\r\nxxxx");
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var charged: u64 = 0;
    var whole: linux_reads.Whole = .{ .most = 2_000_000, .progress = &progress, .small = false, .charged = &charged, .gpa = failing.allocator() };
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
    while (linux_reads.small_held != 0 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), linux_reads.small_held);
}

test "linux_host: an upload that trickles, a few bytes at a time, is slow, not stalled: a stall is no byte, not no 4 KiB (metal-vmm QUEUE 176.7)" {
    linux_reads.stall_for_test_ms = 200;
    defer linux_reads.stall_for_test_ms = null;
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
    linux_reads.deadline_for_test_ms = 200;
    defer linux_reads.deadline_for_test_ms = null;
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
    try std.testing.expectEqual(@as(u64, 0), linux_reads.small_held);
}

test "linux_host: a stranger's upload is never read: its route refuses it at once, never told to send (metal-vmm QUEUE 169)" {
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 401"));
    try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
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
    try std.testing.expectEqual(@as(usize, 1), linux_reads.slots.inUse());
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
    try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
}

test "linux_host: a human's older retry, still waiting, never takes over their newest upload: it is told 409 (metal-vmm QUEUE 171)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    const ann = body_rule.keyOf("ann");
    // The older retry asked first; the newest then took the slot.
    const older = linux_reads.nextAsk(io);
    const peer = try bench.listener.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    const ours = try bench.listener.accept(io);
    defer ours.close(io);
    var newest: linux_reads.Progress = .{ .stream = ours, .io = io };
    const held = switch (linux_reads.takeSlot(io, ann, &newest, linux_reads.nextAsk(io))) {
        .slot => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer linux_reads.giveBackSlot(io, held);
    linux_reads.slot_wait_for_test_ms = 100;
    defer linux_reads.slot_wait_for_test_ms = null;
    var waiting: linux_reads.Progress = .{ .stream = ours, .io = io };
    try std.testing.expect(linux_reads.takeSlot(io, ann, &waiting, older) == .replaced);
    try std.testing.expectEqual(linux_reads.Progress.Ended.nothing, newest.ended_by.load(.acquire));
}

test "linux_host: an upload with no byte for the stall time gives its slot back, a 408 (metal-vmm QUEUE 170.1)" {
    linux_reads.stall_for_test_ms = 200;
    defer linux_reads.stall_for_test_ms = null;
    const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 2000000\r\n\r\nxxxx");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 408"));
    try std.testing.expect(std.mem.indexOf(u8, got, "stalled") != null);
    try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
}

test "linux_host: small bodies are held to a budget, charged as they arrive: past it, 503 (metal-vmm QUEUE 170.3)" {
    linux_reads.small_budget_for_test = 8;
    defer linux_reads.small_budget_for_test = null;
    const over = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n123456789");
    defer std.testing.allocator.free(over);
    try std.testing.expect(std.mem.startsWith(u8, over, "HTTP/1.1 503"));
    // What was charged is given back: the next fits.
    const fits = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n12345678");
    defer std.testing.allocator.free(fits);
    try std.testing.expect(std.mem.endsWith(u8, fits, "\r\n\r\n8"));
    try std.testing.expectEqual(@as(u64, 0), linux_reads.small_held);
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
    linux_reads.slot_wait_for_test_ms = 200;
    defer linux_reads.slot_wait_for_test_ms = null;
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
    try std.testing.expectEqual(@as(usize, 3), linux_reads.slots.inUse());
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
    try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
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
    linux_reads.deadline_for_test_ms = 300;
    defer linux_reads.deadline_for_test_ms = null;
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
    const whole: linux_reads.Got = .{ .whole = @constCast("x") };
    for ([_]linux_reads.Progress.Ended{ .nothing, .deadline, .stalled, .replaced }) |why| {
        // Its own end stands: whole, too large, the budget spent.
        try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).whole, std.meta.activeTag(linux_reads.verdict(whole, why)));
        try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).too_large, std.meta.activeTag(linux_reads.verdict(.too_large, why)));
        try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).busy, std.meta.activeTag(linux_reads.verdict(.busy, why)));
    }
    // An unreadable end is the shut socket's, named by who shut it.
    try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).unreadable, std.meta.activeTag(linux_reads.verdict(.unreadable, .nothing)));
    try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).too_slow, std.meta.activeTag(linux_reads.verdict(.unreadable, .deadline)));
    try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).stalled, std.meta.activeTag(linux_reads.verdict(.unreadable, .stalled)));
    try std.testing.expectEqual(std.meta.Tag(linux_reads.Got).replaced, std.meta.activeTag(linux_reads.verdict(.unreadable, .replaced)));
}

test "linux_host: an error before the turn once a slot is taken or a charge made is a 500, and gives both back (metal-vmm QUEUE 176.8)" {
    linux_reads.fail_after_read_for_test = true;
    defer linux_reads.fail_after_read_for_test = false;
    {
        const got = try exchange("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500"));
        try std.testing.expectEqual(@as(u64, 0), linux_reads.small_held);
    }
    {
        const got = try exchange("POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: ann\r\nContent-Length: 10\r\n\r\n0123456789");
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 500"));
        try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
    }
}

test "linux_host: a takeover just before the stall, and just after it fired: 409 before, 408 after, and the new upload read whole either way (metal-vmm QUEUE 176.8, 186.1)" {
    // **THE RACE MET** (186.1): the watcher ticks every 50 ms and the stall
    // is 600 ms, so silence is counted as it passes. A takeover at 450 ms
    // comes before the stall (the old is told 409); one at 800 ms comes
    // after it fired (the old was told 408, and its slot was given back).
    linux_reads.stall_for_test_ms = 600;
    defer linux_reads.stall_for_test_ms = null;
    linux_reads.tick_for_test_ms = 50;
    defer linux_reads.tick_for_test_ms = null;
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
        try std.testing.expectEqual(@as(usize, 0), linux_reads.slots.inUse());
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
        const charged = linux_reads.small_held - self.held_before;
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
    var progress: linux_reads.Progress = .{ .stream = ours, .io = io };
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
    var peak: HeldPeak = .{ .child = counted.allocator(), .held_before = linux_reads.small_held };
    var charged: u64 = 0;
    defer linux_reads.unchargeSmall(io, charged);
    var whole: linux_reads.Whole = .{ .most = n, .progress = &progress, .small = true, .charged = &charged, .gpa = peak.allocator() };
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
    host.head_for_test_ms = 400;
    defer host.head_for_test_ms = null;
    linux_reads.tick_for_test_ms = 50;
    defer linux_reads.tick_for_test_ms = null;
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
    linux_writes.write_deadline_for_test_ms = 300;
    defer linux_writes.write_deadline_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client("POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx");
    defer c.end(io);
    var waited: u32 = 0;
    while (linux_streams.heldStreams(io) < 1 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), linux_streams.heldStreams(io));
    // The reader reads nothing more. Events far past what the sockets
    // buffer: the host's write blocks, and a write with no deadline blocks
    // for good (the mailbox's overflow is only looked at between writes).
    const big = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'e');
    waited = 0;
    while (linux_streams.heldStreams(io) > 0 and waited < 5000) : (waited += 20) {
        bench.hub.publish("test-stream", big);
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(20) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), linux_streams.heldStreams(io));
}

test "linux_host: a kept stream's connection is let go as its client hangs up, not at its write watcher's next look" {
    // The watcher looks every quarter of the write deadline (7.5 s); the
    // stream's end must not wait for it, nor hold the stream's slot.
    bus.Subscriber.keepalive_ms = 200;
    defer bus.Subscriber.keepalive_ms = bus.Subscriber.keepalive_s * std.time.ms_per_s;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    var c = try bench.client("POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx");
    var waited: u32 = 0;
    while (linux_streams.heldStreams(io) < 1 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), linux_streams.heldStreams(io));
    const from = Io.Clock.now(.awake, io);
    c.end(io);
    const ms = @divFloor(from.durationTo(Io.Clock.now(.awake, io)).nanoseconds, std.time.ns_per_ms);
    errdefer std.debug.print("let go after {d} ms\n", .{ms});
    try std.testing.expect(ms < 1000);
    try std.testing.expectEqual(@as(usize, 0), linux_streams.heldStreams(io));
}

test "linux_host: at most streams_most streams are held: one more ends the oldest, as the kernel does (metal-vmm QUEUE 184)" {
    // A kept stream notices its client has gone on the ping that fails to
    // send: pinged every 200 ms, not every 25 s, the test's end is not a wait.
    bus.Subscriber.keepalive_ms = 200;
    defer bus.Subscriber.keepalive_ms = bus.Subscriber.keepalive_s * std.time.ms_per_s;
    linux_streams.streams_most_for_test = 2;
    defer linux_streams.streams_most_for_test = null;
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
        while (linux_streams.heldStreams(io) < @min(k + 1, 2) and waited < 2000) : (waited += 10) {
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
    try std.testing.expectEqual(@as(usize, 2), linux_streams.heldStreams(io));
}

test "linux_host: /admin/host says how many syncs of the data failed, and how many kept streams ended at their write's deadline (metal-vmm QUEUE 198.6)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const before = host.for_tests.durable.failures.load(.acquire);
    defer host.for_tests.durable.failures.store(before, .release);
    host.for_tests.durable.failures.store(3, .release);
    const facts = try host.for_tests.linuxFacts(threaded.io(), arena.allocator());
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
    const s = host.freeSpaceAt(dir).?;
    try std.testing.expect(s.total > 0 and s.free <= s.total);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ dir, "missing" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(?free_space.Space, null), host.freeSpaceAt(missing));
}

test "linux_host: /admin/host's process facts come from the real getpid and /proc/self/status (metal-vmm QUEUE 198.6)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const facts = try host.for_tests.linuxFacts(threaded.io(), arena.allocator());
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
    const runner = try std.Thread.spawn(.{}, TestHost.for_tests.betweenLoop, .{ io, &stop });
    defer {
        host.for_tests.stopBetween(io, &stop);
        runner.join();
        TestSite.slices_left.store(0, .release);
    }
    host.for_tests.sleepMs(io, 100) catch {};
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
        host.for_tests.sleepMs(io, 45) catch {};
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
    TestHost.for_tests.startBetween(io, &stop);
    defer {
        // The stop rings the bell: the thread, asleep until anything, sees it.
        host.for_tests.stopBetween(io, &stop);
        host.for_tests.sleepMs(io, 20) catch {};
        TestSite.slices_left.store(0, .release);
    }
    try std.testing.expectEqual(std.Thread.getCurrentId(), TestSite.first_between_thread.load(.acquire));
    try std.testing.expect(TestSite.slices_run.load(.acquire) >= 1);
    // And the rest of the run is stepped on the thread.
    var waited: u32 = 0;
    while (TestSite.slices_run.load(.acquire) < 3 and waited < 100) : (waited += 1) host.for_tests.sleepMs(io, 10) catch {};
    try std.testing.expectEqual(@as(u32, 3), TestSite.slices_run.load(.acquire));
}

test "linux_host: a request that starts a run wakes the between thread from its idle sleep, and the run is stepped (DESIGN-sleep.md)" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    TestSite.slices_left.store(0, .release);
    TestSite.slices_run.store(0, .release);
    var stop: std.atomic.Value(bool) = .init(false);
    const runner = try std.Thread.spawn(.{}, TestHost.for_tests.betweenLoop, .{ io, &stop });
    defer {
        host.for_tests.stopBetween(io, &stop);
        runner.join();
        TestSite.slices_left.store(0, .release);
    }
    // Idle: nothing to do, so the thread sleeps until something happens.
    host.for_tests.sleepMs(io, 50) catch {};
    try std.testing.expectEqual(@as(u32, 0), TestSite.slices_run.load(.acquire));
    var c = try bench.client("GET /start-run HTTP/1.1\r\nHost: x\r\n\r\n");
    try c.listen(io);
    try std.testing.expect(c.answer.within(io, 2000));
    c.end(io);
    // The handler's end rang the bell: the three slices, within half a
    // second (each is `between_slice_ms`), not never.
    var waited: u32 = 0;
    while (TestSite.slices_run.load(.acquire) < 3 and waited < 100) : (waited += 1) host.for_tests.sleepMs(io, 5) catch {};
    try std.testing.expectEqual(@as(u32, 3), TestSite.slices_run.load(.acquire));
}

/// A site whose `between` asks for a wake at `due`, and counts its calls
/// and when they came: the between thread's sleep, by counts.
const WakeSite = struct {
    pub const Started = struct {};
    pub fn start(_: Io, _: anytype) !Started {
        return .{};
    }
    pub fn bodyLimit(_: []const u8) u64 {
        return 0;
    }
    pub fn route(_: *std.http.Server.Request, _: Io, _: std.mem.Allocator, _: *bus.Bus) !?bus.Kept {
        return null;
    }
    var due: std.atomic.Value(i64) = .init(0);
    var calls: std.atomic.Value(u32) = .init(0);
    /// Calls before `due`, after the first; and the first call at or after it.
    var early: std.atomic.Value(u32) = .init(0);
    var first_after: std.atomic.Value(i64) = .init(0);
    pub fn between(_: Io, now: @import("webbox").site.Now) @import("webbox").site.Wake {
        const n = calls.fetchAdd(1, .acq_rel);
        const d = due.load(.acquire);
        const t: i64 = @intCast(now.awake_ns);
        if (t < d) {
            if (n > 0) _ = early.fetchAdd(1, .acq_rel);
            return .{ .at = d };
        }
        _ = first_after.cmpxchgStrong(0, t, .acq_rel, .acquire);
        return .idle;
    }
    fn reset(io: Io, in_ns: i64) void {
        calls.store(0, .release);
        early.store(0, .release);
        first_after.store(0, .release);
        due.store(@as(i64, @intCast(Io.Clock.now(.awake, io).nanoseconds)) + in_ns, .release);
    }
};
const WakeHost = host.Server(WakeSite);

test "linux_host: the between thread sleeps until the site's wake: no call before it, one at or after it, then none (DESIGN-sleep.md)" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    WakeSite.reset(io, 100 * std.time.ns_per_ms);
    var stop: std.atomic.Value(bool) = .init(false);
    const runner = try std.Thread.spawn(.{}, WakeHost.for_tests.betweenLoop, .{ io, &stop });
    defer runner.join();
    defer host.for_tests.stopBetween(io, &stop);
    host.for_tests.sleepMs(io, 250) catch {};
    // The first call asked for the wake; the second came at it; then idle.
    try std.testing.expectEqual(@as(u32, 0), WakeSite.early.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), WakeSite.calls.load(.acquire));
    const late_ms = @divTrunc(WakeSite.first_after.load(.acquire) - WakeSite.due.load(.acquire), std.time.ns_per_ms);
    try std.testing.expect(late_ms >= 0);
    // Reported, bounded loosely: a loaded 2-core box is no place to gate ms.
    if (late_ms > 1000) {
        std.debug.print("the wake came {d} ms late\n", .{late_ms});
        return error.TestUnexpectedResult;
    }
}

test "linux_host: a handler's end rings the between thread awake from a far wake, and a stop ends it at once (DESIGN-sleep.md)" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    WakeSite.reset(io, 60 * std.time.ns_per_s);
    var stop: std.atomic.Value(bool) = .init(false);
    const runner = try std.Thread.spawn(.{}, WakeHost.for_tests.betweenLoop, .{ io, &stop });
    var waited: u32 = 0;
    while (WakeSite.calls.load(.acquire) < 1 and waited < 200) : (waited += 1) host.for_tests.sleepMs(io, 5) catch {};
    try std.testing.expectEqual(@as(u32, 1), WakeSite.calls.load(.acquire));
    // A handler's turn, and its end.
    host.for_tests.takeTurn(io);
    host.for_tests.turn.unlock(io);
    host.for_tests.ringBetween(io);
    waited = 0;
    while (WakeSite.calls.load(.acquire) < 2 and waited < 200) : (waited += 1) host.for_tests.sleepMs(io, 5) catch {};
    try std.testing.expectEqual(@as(u32, 2), WakeSite.calls.load(.acquire));
    // Still a minute from its wake: a stop ends the thread now, not then.
    const began = Io.Clock.now(.awake, io).nanoseconds;
    host.for_tests.stopBetween(io, &stop);
    runner.join();
    const took_ms = @divTrunc(Io.Clock.now(.awake, io).nanoseconds - began, std.time.ns_per_ms);
    try std.testing.expect(took_ms < 1000);
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
                TestHost.for_tests.serveConn(i, a, hub, s);
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
    host.idle_for_test_ms = 300;
    defer host.idle_for_test_ms = null;
    linux_reads.tick_for_test_ms = 20;
    defer linux_reads.tick_for_test_ms = null;
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
    host.requests_most_for_test = 2;
    defer host.requests_most_for_test = null;
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
    host.kept_open_most_for_test = 1;
    defer host.kept_open_most_for_test = null;
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
    while (host.for_tests.kept_open.load(.acquire) != 0 and waited < 2000) : (waited += 10) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), host.for_tests.kept_open.load(.acquire));
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
    host.for_tests.sleepMs(io, 300) catch {};
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
    linux_writes.turn_write_deadline_for_test_ms = 300;
    defer linux_writes.turn_write_deadline_for_test_ms = null;
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const io = bench.threaded.io();
    // Eight megabytes in one answer: past `linux_writes.held_most`, written in the turn.
    var stuck = try neverReads(&bench, 1, 8 * 1024);
    host.for_tests.sleepMs(io, 100) catch {};
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
