//! site: an application made servable. Part of the `webbox` library.
//!
//! `Site(App)` is everything a host calls, around an application's own route
//! table and its own one-time setup: the serving that is the same for every
//! application, so none of them writes it again. The host contract, three
//! calls:
//!
//!   1. `mem_meter.init(base)`  the process-lifetime allocator, before
//!                              anything else (a host builds its own I/O and
//!                              heaps on it). An allocation before it panics.
//!   2. `start(io, Host)`       once, before the first request: everything
//!                              the host supplies, in one `Host`, set in the
//!                              one right order around the application's
//!                              `setup`. Answers the Hub and what the
//!                              application's setup did.
//!   3. per request, `route`,   then serve the stream it answered, if any:
//!                              `bus.serveKept` blocks until the client goes
//!                              away; `bus.nextFrame` hands over the next
//!                              event, for a host with one loop. Either way
//!                              `bus.drop` ends it.
//!
//! **THE KEPT STREAM IS ITS ANSWER** (metal-vmm QUEUE 157(a)): `route` answers
//! the stream a handler kept, which the host must serve or drop
//! (`bus.serveKept`, `bus.nextFrame`, `bus.drop`); Zig makes the caller use
//! it. On an error it is dropped here, where a host that read `bus.kept` after
//! `try` left a kept stream's subscriber in the Hub for ever.

const std = @import("std");
const Io = @import("host_io").Io;
const bus = @import("bus.zig");
const traffic = @import("traffic.zig");
const Bus = bus.Bus;
const Kept = bus.Kept;
const mem_meter = @import("mem_meter.zig");
const store = @import("store.zig");
const host_facts = @import("host_facts.zig");
const free_space = @import("free_space.zig");
const client_address = @import("client_address.zig");

/// Where an application's data (`data_dir`) and its secrets (`auth_dir`)
/// live, as the host spells them.
pub const Roots = struct {
    data_dir: []const u8,
    auth_dir: []const u8,
};

/// Everything a host supplies, once, as it starts.
pub const Host = struct {
    /// Where the data and the secrets live; null is the application's
    /// development defaults, right for a checkout and nothing else.
    roots: ?Roots,
    /// How the data volume's free space is read.
    free_space: free_space.FreeSpace,
    /// The reverse proxy whose X-Forwarded-For is believed, as text; null:
    /// every request is the address it came from.
    trusted_proxy: ?[]const u8,
    /// The host's own facts and log, for a page that shows them; null: that
    /// page shows the application's half only.
    facts: ?host_facts.Report = null,
    log: ?host_facts.Log = null,
    /// The host's whole log, both boots, for /admin/log (189.3).
    logs: ?host_facts.LogsSource = null,
};

/// `App` declares, each required:
///   - `routes(req, io, alloc, bus) !void`: its route table (`bus` is the
///     request's handle on the pub/sub, and carries the connection's
///     address, `bus.peer`);
///   - `setup(io, base, roots: ?Roots) !StartReport`: what it does once,
///     before its first request, in its own order, with `base` (the metered
///     process allocator) for whatever must live as long as the process;
///   - `StartReport`: what its setup did, for the host to say in its log;
///   - `bodyLimit(path) u64`: the most any handler on that path reads of a
///     request's body, which the host reads it by (body.zig);
///   - and, if any route's cap is past `body.before_turn_most` (an upload),
///     `uploader(req, io, alloc) !?[]const u8`: who is asking, from the head
///     alone, or null for a stranger, whose upload is never read (body.zig).
pub fn Site(comptime App: type) type {
    inline for (.{
        .{ "routes", "routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *Bus) !void" },
        .{ "setup", "setup(io: Io, base: std.mem.Allocator, roots: ?Roots) !StartReport" },
        .{ "StartReport", "StartReport: a struct, what its setup did" },
        .{ "bodyLimit", "bodyLimit(path: []const u8) u64: the most any handler on that path reads of a body (body.zig)" },
    }) |decl| {
        if (!@hasDecl(App, decl[0])) @compileError("a site's application declares " ++ decl[1] ++ " (site.zig, Site)");
    }
    return struct {
        /// What `start` made, and what the application's setup did.
        pub const Started = struct {
            /// The registry live streams publish through, one per process.
            hub: bus.Hub,
            app: App.StartReport,
        };

        /// **THE SETUP, ONCE, BEFORE THE FIRST REQUEST**, in the one right
        /// order: the store pointed at the host's roots, the application's
        /// own setup, then the host's facts, how its free space is read, the
        /// trusted proxy, and the Hub.
        pub fn start(io: Io, host: Host) !Started {
            const base = mem_meter.base();
            if (host.roots) |r| store.setBases(try base.dupe(u8, r.data_dir), try base.dupe(u8, r.auth_dir));
            const app = try App.setup(io, base, host.roots);
            if (host.facts) |f| host_facts.provide(f);
            if (host.log) |l| host_facts.provideLog(l);
            if (host.logs) |l| host_facts.provideLogs(l);
            free_space.reader = switch (host.free_space) {
                .reader => |r| r,
                .unknown => null,
            };
            client_address.trusted_proxy = host.trusted_proxy;
            return .{ .hub = bus.Hub.init(io, base), .app = app };
        }

        /// **BETWEEN REQUESTS** (metal-vmm QUEUE 211): the application's
        /// work a host does between handlers, under the turn, one slice at a
        /// time (a background script's, `script_route.sliceBackground`);
        /// whether there is more. A site with none says no.
        pub fn between(io: Io, now: i64) bool {
            if (!@hasDecl(App, "between")) return false;
            return App.between(io, now);
        }

        /// The route's cap on a body, from the head's target (its path; the
        /// query is no part of it): what a host plans the body's read by
        /// (body.zig's `plan`).
        pub fn bodyLimit(target: []const u8) u64 {
            return App.bodyLimit(pathOf(target));
        }

        /// Who is asking to upload, from the head (body.zig): the
        /// application's name for them, or null for a stranger, and for
        /// everyone on a site that takes no uploads.
        pub fn uploader(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !?[]const u8 {
            if (!@hasDecl(App, "uploader")) return null;
            return App.uploader(req, io, alloc);
        }

        /// **EVERY REQUEST COUNTED** (metal-vmm QUEUE 189.5, traffic.zig): its
        /// family (the application's `family`, if it has one), its status,
        /// how long the route took, and a 5xx's error. The path is copied
        /// first (http.pathInto): the target is borrowed from a buffer the
        /// handler's body read may consume.
        pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, b: *Bus) !?Kept {
            var path_buf: [traffic.Text.capacity]u8 = undefined;
            const kept_path = @import("http.zig").pathInto(req, &path_buf);
            // The family from the whole path: a buffer the size of a head
            // holds any target (the counted path above may be cut short).
            var family_buf: [@import("http.zig").head_bytes]u8 = undefined;
            const family = familyName(App, @import("http.zig").pathInto(req, &family_buf));
            const began = Io.Clock.now(.awake, io).nanoseconds;
            const out = answer(req, io, alloc, b);
            const took = Io.Clock.now(.awake, io).nanoseconds - began;
            traffic.global.note(.{
                .family = family,
                .status = b.status,
                .took_ns = @intCast(@max(took, 0)),
                .target = kept_path,
                .at_unix_ms = b.at_unix_ms,
                .err = if (out) |_| null else |e| @errorName(e),
            });
            return out;
        }

        fn answer(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, b: *Bus) !?Kept {
            // **100-continue IN ANY CASE IS MET HERE, FOR EVERY HOST** (180.6's
            // review): the body rule takes it, std answers only the exact
            // spelling, and a host that routed it as sent answered nothing.
            // A refused expectation never reaches here (the host's 417).
            @import("body.zig").meetExpectation(&req.head);
            var sent: Sent = undefined;
            // Small, on the stack: only a chunk's header is formatted in place, and
            // anything longer passes straight to the connection's own buffer.
            var buffer: [1024]u8 = undefined;
            sent.lend(req, &buffer);
            const done = App.routes(req, io, alloc, b);
            sent.giveBack(req);
            b.status = sent.status();
            return settle(b, done) catch |e| {
                // **A FAILURE IS A 500, NEVER SILENCE** (metal-vmm QUEUE 123, Steve:
                // louder is better): an error that escapes a handler before its
                // head is sent is answered here, for both hosts, and still goes on
                // to the host to log. Once the head is out, the answer is the
                // handler's, cut short, and only the connection's close can say so.
                if (e == error.MalformedForm) {
                    // The client's, not the server's (http.formField): said as such,
                    // and nothing for the host to log.
                    if (!sent.any) {
                        req.respond("The form was malformed.\n", .{ .status = .bad_request, .keep_alive = false }) catch {};
                        b.status = 400;
                    }
                    return null;
                }
                if (answerFailure(req, &sent, e)) |code| b.status = code;
                return e;
            };
        }
    };
}

fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

/// What `route` hands the host: the kept stream on success, taken off the
/// bus; on an error, none, and a stream the handler kept before it failed is
/// dropped, never left for a host to forget.
fn settle(b: *Bus, done: anyerror!void) anyerror!?Kept {
    const kept = b.kept;
    b.kept = null;
    done catch |e| {
        if (kept) |k| bus.drop(b.hub, k);
        return e;
    };
    return kept;
}

/// **WHETHER ANY OF THE ANSWER WENT OUT** (metal-vmm QUEUE 127(b)): the
/// reader's state cannot say, since reading a body moves it on as answering
/// does. So `route` lends each handler a writer of its own in place of
/// the connection's, which passes every byte through to it, and notes that
/// one was written. It buffers as the connection's does (the protocol's
/// writers format chunk headers in place), and is given back, its buffer
/// passed on unflushed, when the handler returns: before the host flushes
/// or serves a kept stream, on the connection's own writer.
const Sent = struct {
    to: *std.Io.Writer,
    any: bool,
    writer: std.Io.Writer,
    /// The answer's first bytes, `HTTP/1.1 200`, for `status` (189.2).
    head: [12]u8 = undefined,
    head_len: usize = 0,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    fn lend(self: *Sent, req: *std.http.Server.Request, buffer: []u8) void {
        self.* = .{ .to = req.server.out, .any = false, .writer = .{ .buffer = buffer, .vtable = &vtable }, .head_len = 0 };
        req.server.out = &self.writer;
    }

    /// Back to the connection's writer, with what this one still holds.
    fn giveBack(self: *Sent, req: *std.http.Server.Request) void {
        self.pass() catch {};
        req.server.out = self.to;
    }

    /// Keeps the answer's first bytes, for `status`.
    fn note(self: *Sent, bytes: []const u8) void {
        const n = @min(bytes.len, self.head.len - self.head_len);
        @memcpy(self.head[self.head_len..][0..n], bytes[0..n]);
        self.head_len += n;
    }

    /// The code the answer's status line gave, `HTTP/1.x NNN`, or 0 when
    /// none went out whole. Its digits read by hand: a number this parses is
    /// the server's own, not a request's (router's edge harness).
    fn status(self: *const Sent) u16 {
        if (self.head_len < self.head.len) return 0;
        const h = &self.head;
        if (!std.mem.startsWith(u8, h, "HTTP/1.") or h[8] != ' ') return 0;
        var code: u16 = 0;
        for (h[9..12]) |c| {
            if (c < '0' or c > '9') return 0;
            code = code * 10 + (c - '0');
        }
        return code;
    }

    /// What is buffered, to the connection's writer.
    fn pass(self: *Sent) std.Io.Writer.Error!void {
        const w = &self.writer;
        if (w.end == 0) return;
        self.note(w.buffer[0..w.end]);
        self.any = true;
        defer w.end = 0;
        try self.to.writeAll(w.buffer[0..w.end]);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sent = @alignCast(@fieldParentPtr("writer", w));
        try self.pass();
        for (data[0 .. data.len - 1]) |d| self.note(d);
        for (0..splat) |_| self.note(data[data.len - 1]);
        const n = try self.to.writeSplat(data, splat);
        if (n > 0) self.any = true;
        return n;
    }

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const self: *Sent = @alignCast(@fieldParentPtr("writer", w));
        try self.pass();
        const n = try self.to.sendFile(file_reader, limit);
        if (n > 0) self.any = true;
        return n;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Sent = @alignCast(@fieldParentPtr("writer", w));
        try self.pass();
        return self.to.flush();
    }
};

/// The 500 for an error no byte of an answer went out before; nothing once
/// one did. Not kept alive, so whatever of the request's body is unread
/// stays unread. **ITS BODY NAMES NOTHING** (metal-vmm QUEUE 134(f)): an
/// error's name says what of the server failed, which is the log's to know,
/// not a client's; `route` returns the error for the host to log.
///
/// **A REFUSED WRITE IS A 503** (metal-vmm QUEUE 188.2): a volume whose FAT
/// copies could not be weighed at mount serves reads and refuses every
/// write, which io answers as `error.ReadOnlyFileSystem`, until a weighing
/// succeeds (the kernel tries again once a minute). That is the server not
/// taking writes for now, not a failure of the request: said as such, with
/// when to come back. Still the host's to log.
/// Answers the status it sent, or null when the answer was already out.
fn answerFailure(req: *std.http.Server.Request, sent: *const Sent, e: anyerror) ?u16 {
    if (sent.any) return null;
    if (e == error.ReadOnlyFileSystem) {
        req.respond("The server is taking no writes just now. Try again in a minute.\n", .{
            .status = .service_unavailable,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "retry-after", .value = "60" }},
        }) catch {};
        return 503;
    }
    req.respond("The server failed.\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
    return 500;
}

const testing = std.testing;

/// The application's family for a request, from its whole path (no
/// query): the kept copy is cut at 120 bytes, and a long topic's upload
/// read from it was counted as chat (189's minor 10). Read before the
/// route, while the target is still the head's.
fn familyName(comptime A: type, target: []const u8) []const u8 {
    if (!@hasDecl(A, "family")) return "all";
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    return @tagName(A.family(path));
}

test "site: a long topic's upload is counted under uploads: the family is read from the whole path (189's minor 10)" {
    const A = struct {
        const Family = enum { chat, uploads };
        fn family(path: []const u8) Family {
            return if (std.mem.endsWith(u8, path, "/upload")) .uploads else .chat;
        }
    };
    const topic = "t" ** 150;
    try testing.expectEqualStrings("uploads", familyName(A, "/chat/c/1_2/" ++ topic ++ "/upload?x=1"));
    try testing.expectEqualStrings("chat", familyName(A, "/chat/c/1_2/" ++ topic));
    try testing.expectEqualStrings("all", familyName(struct {}, "/x"));
}

test "site: an error after the head went out is not answered again (metal-vmm QUEUE 127(b))" {
    // A handler that answered, then failed: the answer stands, cut short or
    // whole, and no second head follows it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var reader: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    const failing = struct {
        fn handle(r: *std.http.Server.Request) !void {
            try r.respond("fine", .{ .keep_alive = false });
            return error.AfterTheHead;
        }
    };
    var sent: Sent = undefined;
    var buffer: [4096]u8 = undefined;
    sent.lend(&req, &buffer);
    const got = failing.handle(&req);
    sent.giveBack(&req);
    try testing.expectError(error.AfterTheHead, got);
    try testing.expect(sent.any);
    _ = answerFailure(&req, &sent, error.AfterTheHead);
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "500") == null);
}

test "site: an error before a streamed answer's first byte sends one status line, never a 500 after the head (metal-vmm QUEUE 177.3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var reader: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    const failing = struct {
        // chat_upload.streamFile's shape: the head begun, then the first
        // read fails.
        fn handle(r: *std.http.Server.Request) !void {
            var hbuf: [1024]u8 = undefined;
            var body = try r.respondStreaming(&hbuf, .{ .respond_options = .{ .keep_alive = false } });
            _ = &body;
            return error.FirstReadFailed;
        }
    };
    var sent: Sent = undefined;
    var buffer: [1024]u8 = undefined;
    sent.lend(&req, &buffer);
    const got = failing.handle(&req);
    sent.giveBack(&req);
    try testing.expectError(error.FirstReadFailed, got);
    _ = answerFailure(&req, &sent, error.FirstReadFailed);
    try out.writer.flush();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "HTTP/1.1 "));
}

test "site: a stream a handler kept and then failed is dropped, and a kept one is the host's to take (metal-vmm QUEUE 157(a))" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = bus.Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    var b = Bus.of(&hub);
    const sub = try b.open("k");
    b.keep(.{ .sub = sub, .render = undefined });
    try testing.expectError(error.HandlerFailed, settle(&b, error.HandlerFailed));
    try testing.expectEqual(@as(usize, 0), hub.entries.items.len);
    try testing.expect(b.kept == null);
    // On success the stream is the answer, and off the bus.
    const sub2 = try b.open("k");
    b.keep(.{ .sub = sub2, .render = undefined });
    const k = (try settle(&b, {})).?;
    try testing.expect(b.kept == null);
    bus.drop(&hub, k);
    try testing.expectEqual(@as(usize, 0), hub.entries.items.len);
}

test "site: a bodiless request expecting 100-Continue in any case is answered, on every host (metal-vmm QUEUE 180.6's review)" {
    // The body rule takes 100-continue in any case (body.plan), and std
    // answers only its exact spelling: a host that routed it without the
    // rewrite answered nothing at all (metal's did). So route makes it, for
    // every host. Both sides: the exact spelling, and another case.
    const App = struct {
        pub const StartReport = struct {};
        pub fn setup(_: Io, _: std.mem.Allocator, _: ?Roots) !StartReport {
            return .{};
        }
        pub fn bodyLimit(_: []const u8) u64 {
            return 0;
        }
        pub fn routes(req: *std.http.Server.Request, _: Io, _: std.mem.Allocator, _: *Bus) !void {
            try req.respond("hello", .{ .keep_alive = false });
        }
    };
    const Served = Site(App);
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = bus.Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    for ([_][]const u8{ "100-continue", "100-Continue" }) |spelled| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const raw = try std.fmt.allocPrint(testing.allocator, "GET / HTTP/1.1\r\nHost: x\r\nExpect: {s}\r\n\r\n", .{spelled});
        defer testing.allocator.free(raw);
        var reader: std.Io.Reader = .fixed(raw);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        var b = Bus.of(&hub);
        try testing.expect((try Served.route(&req, threaded.io(), testing.allocator, &b)) == null);
        try out.writer.flush();
        try testing.expect(std.mem.indexOf(u8, out.written(), "HTTP/1.1 200") != null);
        try testing.expect(std.mem.endsWith(u8, out.written(), "hello"));
    }
}

test "site: an application's failure is a 500 that names nothing, a refused write a 503, a malformed form a 400, and success what it answered" {
    const App = struct {
        pub const StartReport = struct {};
        pub fn setup(_: Io, _: std.mem.Allocator, _: ?Roots) !StartReport {
            return .{};
        }
        pub fn bodyLimit(_: []const u8) u64 {
            return 0;
        }
        pub fn routes(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, _: *Bus) !void {
            const target = try @import("http.zig").target(req, alloc);
            defer alloc.free(target);
            if (std.mem.eql(u8, target, "/fails")) return error.SomethingBroke;
            if (std.mem.eql(u8, target, "/form")) return error.MalformedForm;
            // A volume refusing writes (metal-vmm QUEUE 188.2): the store's
            // write, failed as io answers it, before any answer.
            if (std.mem.eql(u8, target, "/refused")) return error.ReadOnlyFileSystem;
            // A streamed answer begun, then failed before its first byte
            // (chat_upload.streamFile's first readAt, admin_backup's archive):
            // its head stands alone, with no 500 after it (177.3).
            if (std.mem.eql(u8, target, "/streams")) {
                var hbuf: [1024]u8 = undefined;
                var body = try req.respondStreaming(&hbuf, .{ .respond_options = .{ .keep_alive = false } });
                _ = &body;
                return error.FirstReadFailed;
            }
            try req.respond("hello", .{ .keep_alive = false });
        }
    };
    const Served = Site(App);
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = bus.Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    for ([_]struct { target: []const u8, head: []const u8, status: u16, body: []const u8, err: ?anyerror }{
        .{ .target = "/fails", .head = "HTTP/1.1 500", .status = 500, .body = "The server failed.\n", .err = error.SomethingBroke },
        .{ .target = "/refused", .head = "HTTP/1.1 503", .status = 503, .body = "The server is taking no writes just now. Try again in a minute.\n", .err = error.ReadOnlyFileSystem },
        .{ .target = "/form", .head = "HTTP/1.1 400", .status = 400, .body = "The form was malformed.\n", .err = null },
        .{ .target = "/", .head = "HTTP/1.1 200", .status = 200, .body = "hello", .err = null },
        .{ .target = "/streams", .head = "HTTP/1.1 200", .status = 200, .body = "\r\n\r\n", .err = error.FirstReadFailed },
    }) |case| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const raw = try std.fmt.allocPrint(testing.allocator, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{case.target});
        defer testing.allocator.free(raw);
        var reader: std.Io.Reader = .fixed(raw);
        var server = std.http.Server.init(&reader, &out.writer);
        var req = try server.receiveHead();
        var b = Bus.of(&hub);
        const got = Served.route(&req, threaded.io(), testing.allocator, &b);
        if (case.err) |e| try testing.expectError(e, got) else try testing.expect((try got) == null);
        // **THE STATUS IS THE HOST'S TO LOG** (metal-vmm QUEUE 189.2): what
        // the answer's status line said, whoever wrote it.
        try testing.expectEqual(case.status, b.status);
        try out.writer.flush();
        try testing.expect(std.mem.startsWith(u8, out.written(), case.head));
        try testing.expect(std.mem.endsWith(u8, out.written(), case.body));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "HTTP/1.1 "));
    }
}
