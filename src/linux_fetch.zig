//! linux_fetch: **THE APPLICATION'S FETCH ON LINUX** (webbox's host_fetch;
//! zig-metal-unikernel's docs/designs/DESIGN-sleep.md, chunk 6). Part of the
//! `webbox` library's Linux half.
//!
//! One GET at a time, on a thread of its own, so the turn is never held: a
//! blocking socket whose send timeout bounds the connect (`connect_ms`), whose
//! receive timeout bounds each silence (`idle_ms`, never past what is left of
//! `total_ms`), and the total checked between reads. Linux's own retries never
//! end a fetch; its deadlines do. Its end is published for `result`, and the
//! host is told (`on_end`), so `between` is called at once.
//!
//! The outcome words are host_fetch's, which are the kernel's client's. Linux
//! says them from its errors:
//!
//!   ECONNREFUSED                 refused
//!   ECONNRESET, EPIPE            reset
//!   EHOSTUNREACH                 no_arp (nobody answered at the address)
//!   ENETUNREACH, EADDRNOTAVAIL   no_route
//!
//! `given_up` (the kernel's retransmission timer) has no Linux twin.
//!
//! The answer is read here by its own reader (`Answer`), not the kernel's:
//! two readers of one format, each tested against the same answers.

const std = @import("std");
const linux = std.os.linux;
const Io = @import("host_io").Io;
const host_fetch = @import("webbox").host_fetch;

const Outcome = host_fetch.Outcome;

/// The most head an answer may have.
pub const head_max = 4096;

/// **THE ANSWER, READ AS IT ARRIVES**: the head kept to its blank line, its
/// status and content-length taken from it, the body kept to
/// `host_fetch.body_most` and counted past it.
pub const Answer = struct {
    head: [head_max]u8 = undefined,
    head_len: usize = 0,
    state: enum { head, body, bad } = .head,
    status: u16 = 0,
    length: ?u64 = null,
    body: [host_fetch.body_most]u8 = undefined,
    body_len: usize = 0,
    /// Body bytes past `body_most`, not kept.
    past: u64 = 0,

    pub fn feed(self: *Answer, bytes: []const u8) void {
        var rest = bytes;
        if (self.state == .bad) return;
        if (self.state == .head) {
            const from = self.head_len -| 3;
            const take = @min(head_max - self.head_len, rest.len);
            @memcpy(self.head[self.head_len..][0..take], rest[0..take]);
            self.head_len += take;
            const end = std.mem.indexOf(u8, self.head[from..self.head_len], "\r\n\r\n") orelse {
                if (self.head_len == head_max) self.state = .bad;
                return;
            };
            const head_end = from + end + 4;
            if (!self.parseHead(self.head[0..head_end])) {
                self.state = .bad;
                return;
            }
            self.state = .body;
            // What came after the blank line in this feed is body.
            const used = head_end - (self.head_len - take);
            rest = rest[used..];
        }
        const room = self.body.len - self.body_len;
        const n = @min(room, rest.len);
        @memcpy(self.body[self.body_len..][0..n], rest[0..n]);
        self.body_len += n;
        self.past += rest.len - n;
    }

    fn parseHead(self: *Answer, head: []const u8) bool {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const first = lines.next() orelse return false;
        if (!std.mem.startsWith(u8, first, "HTTP/1.")) return false;
        var words = std.mem.tokenizeScalar(u8, first, ' ');
        _ = words.next();
        self.status = std.fmt.parseInt(u16, words.next() orelse return false, 10) catch return false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) continue;
            self.length = std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return false;
        }
        return true;
    }

    fn total(self: *const Answer) u64 {
        return self.body_len + self.past;
    }

    /// The whole body is here, by its content-length.
    pub fn complete(self: *const Answer) bool {
        return self.state == .body and if (self.length) |n| self.total() >= n else false;
    }

    /// How it ended, once the server finished (its FIN) or the body is whole.
    pub fn outcome(self: *const Answer) Outcome {
        if (self.state != .body or self.status != 200) return .bad_answer;
        if (self.length) |n| {
            if (self.total() < n) return .short_answer;
            if (self.total() > n) return .bad_answer;
        }
        if (self.past > 0) return .too_long;
        return .ok;
    }
};

/// What a socket error says, as host_fetch says it; null for one with no word.
fn outcomeOf(e: linux.E) ?Outcome {
    return switch (e) {
        .CONNREFUSED => .refused,
        .CONNRESET, .PIPE => .reset,
        .HOSTUNREACH => .no_arp,
        .NETUNREACH, .ADDRNOTAVAIL => .no_route,
        else => null,
    };
}

fn timeval(ms: u64) linux.timeval {
    return .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
}

fn setTimeout(fd: i32, which: u32, ms: u64) void {
    // Never 0: that is no timeout at all.
    const tv = timeval(@max(ms, 1));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, which, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

fn msSince(io: Io, from: i96) u64 {
    return @intCast(@max(0, @divTrunc(Io.Clock.now(.awake, io).nanoseconds - from, std.time.ns_per_ms)));
}

/// **ONE GET, BLOCKING**, bounded by `d`: how it ended, the answer in `a`.
pub fn get(io: Io, t: host_fetch.Target, d: host_fetch.Deadlines, a: *Answer) Outcome {
    const began = Io.Clock.now(.awake, io).nanoseconds;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return .no_route;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    setTimeout(fd, linux.SO.SNDTIMEO, @min(d.connect_ms, d.total_ms));
    const addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, t.port), .addr = @bitCast(t.ip) };
    switch (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        // The send timeout ran out first (Linux says the connect is still in
        // progress).
        .INPROGRESS, .AGAIN, .TIMEDOUT => return if (d.connect_ms <= d.total_ms) .connect_deadline else .total_deadline,
        else => |e| return outcomeOf(e) orelse .reset,
    }
    var request: [512]u8 = undefined;
    var host: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&host, "{d}.{d}.{d}.{d}", .{ t.ip[0], t.ip[1], t.ip[2], t.ip[3] }) catch unreachable;
    const req = std.fmt.bufPrint(&request, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ t.path, name }) catch return .bad_answer;
    setTimeout(fd, linux.SO.SNDTIMEO, d.idle_ms);
    var sent: usize = 0;
    while (sent < req.len) {
        const n = linux.sendto(fd, req[sent..].ptr, req.len - sent, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(n)) {
            .SUCCESS => sent += n,
            .INTR => {},
            .AGAIN => return .idle_deadline,
            else => |e| return outcomeOf(e) orelse .reset,
        }
    }
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const spent = msSince(io, began);
        if (spent >= d.total_ms) return .total_deadline;
        const left = d.total_ms - spent;
        setTimeout(fd, linux.SO.RCVTIMEO, @min(d.idle_ms, left));
        const n = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => return if (d.idle_ms <= left) .idle_deadline else .total_deadline,
            else => |e| return outcomeOf(e) orelse .reset,
        }
        if (n == 0) return a.outcome(); // the server finished
        a.feed(buf[0..n]);
        if (a.state == .bad) return .bad_answer;
        if (a.complete()) return a.outcome();
    }
}

/// **THE HOST'S ONE FETCH**: running, or ended and its result not yet taken.
const State = struct {
    running: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    target: host_fetch.Target = undefined,
    path: [host_fetch.path_most]u8 = undefined,
    deadlines: host_fetch.Deadlines = undefined,
    answer: Answer = .{},
    result: host_fetch.Result = undefined,
};
var state: State = .{};

/// The host's `Io`, and what it does when a fetch ends (rings its between
/// thread awake). Set by the host before the first fetch.
pub var on_end: ?struct { io: Io, ring: *const fn (Io) void } = null;

/// host_fetch's `start`, on Linux. Busy while one runs, or until its end is
/// taken (`result`).
pub fn start(t: host_fetch.Target, d: host_fetch.Deadlines) host_fetch.StartError!void {
    if (state.running.load(.acquire)) return error.Busy;
    if (t.path.len > state.path.len) return error.PathTooLong;
    const hook = on_end orelse return error.Busy;
    state.done.store(false, .release);
    @memcpy(state.path[0..t.path.len], t.path);
    state.target = .{ .ip = t.ip, .port = t.port, .path = state.path[0..t.path.len] };
    state.deadlines = d;
    state.answer = .{};
    state.running.store(true, .release);
    const thread = std.Thread.spawn(.{}, run, .{hook.io}) catch {
        state.running.store(false, .release);
        return error.Busy;
    };
    thread.detach();
}

fn run(io: Io) void {
    const o = get(io, state.target, state.deadlines, &state.answer);
    state.result = .{ .outcome = o, .status = state.answer.status, .body = state.answer.body[0..state.answer.body_len] };
    state.done.store(true, .release);
    if (on_end) |h| h.ring(h.io);
}

/// host_fetch's `result`, on Linux: the ended fetch, once.
pub fn result() ?host_fetch.Result {
    if (!state.done.load(.acquire)) return null;
    state.done.store(false, .release);
    const r = state.result;
    state.running.store(false, .release);
    return r;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "linux_fetch: an answer fed whole or a byte at a time reads the same, and ends by its length" {
    const text = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var whole: Answer = .{};
    whole.feed(text);
    var bytes: Answer = .{};
    for (text) |b| bytes.feed(&.{b});
    for ([_]*const Answer{ &whole, &bytes }) |a| {
        try testing.expect(a.complete());
        try testing.expectEqual(Outcome.ok, a.outcome());
        try testing.expectEqualStrings("hello", a.body[0..a.body_len]);
    }
    var short: Answer = .{};
    short.feed("HTTP/1.1 200 OK\r\ncontent-length: 9\r\n\r\nhello");
    try testing.expectEqual(Outcome.short_answer, short.outcome());
    var not_ok: Answer = .{};
    not_ok.feed("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n");
    try testing.expectEqual(Outcome.bad_answer, not_ok.outcome());
    var not_http: Answer = .{};
    not_http.feed("hello\r\n\r\n");
    try testing.expectEqual(Outcome.bad_answer, not_http.outcome());
}

/// A server on 127.0.0.1 that does one thing to its one client.
const Script = enum { answers, short, mute, trickles, huge, not_ok };

const TestServer = struct {
    fd: i32,
    port: u16,

    fn open() !TestServer {
        const fd: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Bind;
        if (linux.errno(linux.listen(fd, 4)) != .SUCCESS) return error.Listen;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = linux.getsockname(fd, @ptrCast(&addr), &len);
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn serve(self: TestServer, io: Io, script: Script) void {
        const c: i32 = @intCast(linux.accept(self.fd, null, null));
        defer _ = linux.close(c);
        var buf: [1024]u8 = undefined;
        _ = linux.recvfrom(c, &buf, buf.len, 0, null, null);
        const send = struct {
            fn all(fd: i32, bytes: []const u8) void {
                _ = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
            }
        }.all;
        switch (script) {
            .answers => send(c, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello"),
            .short => send(c, "HTTP/1.1 200 OK\r\ncontent-length: 9\r\n\r\nhello"),
            .not_ok => send(c, "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\n\r\n"),
            .mute => Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(600) }, io) catch {},
            .trickles => {
                send(c, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n");
                for (0..20) |_| {
                    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(40) }, io) catch {};
                    send(c, "x");
                }
            },
            .huge => {
                send(c, "HTTP/1.1 200 OK\r\n\r\n");
                var chunk: [8192]u8 = @splat('y');
                var left: usize = host_fetch.body_most + 10;
                while (left > 0) {
                    const n = @min(left, chunk.len);
                    send(c, chunk[0..n]);
                    left -= n;
                }
            },
        }
    }

    fn close(self: TestServer) void {
        _ = linux.close(self.fd);
    }
};

const quick: host_fetch.Deadlines = .{ .connect_ms = 300, .idle_ms = 150, .total_ms = 1000 };

fn fetchFrom(io: Io, script: Script, d: host_fetch.Deadlines, a: *Answer) !Outcome {
    const server = try TestServer.open();
    defer server.close();
    const serving = try std.Thread.spawn(.{}, TestServer.serve, .{ server, io, script });
    defer serving.join();
    return get(io, .{ .ip = .{ 127, 0, 0, 1 }, .port = server.port, .path = "/version" }, d, a);
}

test "linux_fetch: against a local server, each ending in host_fetch's word: ok, short, not a 200, too long, idle, total (DESIGN-sleep.md chunk 6)" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = try testing.allocator.create(Answer);
    defer testing.allocator.destroy(a);
    a.* = .{};
    try testing.expectEqual(Outcome.ok, try fetchFrom(io, .answers, quick, a));
    try testing.expectEqualStrings("hello", a.body[0..a.body_len]);
    a.* = .{};
    try testing.expectEqual(Outcome.short_answer, try fetchFrom(io, .short, quick, a));
    a.* = .{};
    try testing.expectEqual(Outcome.bad_answer, try fetchFrom(io, .not_ok, quick, a));
    try testing.expectEqual(@as(u16, 503), a.status);
    a.* = .{};
    try testing.expectEqual(Outcome.too_long, try fetchFrom(io, .huge, quick, a));
    try testing.expectEqual(@as(usize, host_fetch.body_most), a.body_len);
    a.* = .{};
    try testing.expectEqual(Outcome.idle_deadline, try fetchFrom(io, .mute, quick, a));
    // A byte every 40 ms is never idle for 150 ms, and is not done by 400.
    a.* = .{};
    try testing.expectEqual(Outcome.total_deadline, try fetchFrom(io, .trickles, .{ .connect_ms = 300, .idle_ms = 150, .total_ms = 400 }, a));
}

test "linux_fetch: a port nobody listens on is refused" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const server = try TestServer.open();
    const port = server.port;
    server.close();
    var a: Answer = .{};
    try testing.expectEqual(Outcome.refused, get(io, .{ .ip = .{ 127, 0, 0, 1 }, .port = port, .path = "/" }, quick, &a));
}

test "linux_fetch: the host's fetch runs on its own thread, says its end once, and rings the host" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Rung = struct {
        var count: std.atomic.Value(u32) = .init(0);
        fn ring(_: Io) void {
            _ = count.fetchAdd(1, .acq_rel);
        }
    };
    const was = on_end;
    defer on_end = was;
    on_end = .{ .io = io, .ring = Rung.ring };
    const server = try TestServer.open();
    defer server.close();
    const serving = try std.Thread.spawn(.{}, TestServer.serve, .{ server, io, Script.answers });
    defer serving.join();
    try start(.{ .ip = .{ 127, 0, 0, 1 }, .port = server.port, .path = "/version" }, quick);
    try testing.expectError(error.Busy, start(.{ .ip = .{ 127, 0, 0, 1 }, .port = server.port, .path = "/" }, quick));
    var waited: u32 = 0;
    while (Rung.count.load(.acquire) == 0 and waited < 200) : (waited += 1) {
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(5) }, io) catch {};
    }
    try testing.expectEqual(@as(u32, 1), Rung.count.load(.acquire));
    const r = result().?;
    try testing.expectEqual(Outcome.ok, r.outcome);
    try testing.expectEqualStrings("hello", r.body);
    try testing.expectEqual(@as(?host_fetch.Result, null), result());
}
