//! site: an application made servable. Part of the `webbox` library.
//!
//! `Site(App)` is everything a host calls around an application's own route
//! table (`App.routes`): the serving that is the same for every application,
//! so none of them writes it again.
//!
//! **THE KEPT STREAM IS ITS ANSWER** (metal-vmm QUEUE 157(a)): `route` answers
//! the stream a handler kept, which the host must serve or drop
//! (`bus.serveKept`, `bus.nextFrame`, `bus.drop`); Zig makes the caller use
//! it. On an error it is dropped here, where a host that read `bus.kept` after
//! `try` left a kept stream's subscriber in the Hub for ever.

const std = @import("std");
const Io = std.Io;
const bus = @import("bus.zig");
const Bus = bus.Bus;
const Kept = bus.Kept;

/// `App` declares `routes(req, io, alloc, bus) !void`: its route table.
pub fn Site(comptime App: type) type {
    if (!@hasDecl(App, "routes")) @compileError("a site's application declares routes(req, io, alloc, bus) !void: its route table");
    return struct {
        pub fn route(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, b: *Bus) !?Kept {
            var sent: Sent = undefined;
            // Small, on the stack: only a chunk's header is formatted in place, and
            // anything longer passes straight to the connection's own buffer.
            var buffer: [1024]u8 = undefined;
            sent.lend(req, &buffer);
            const done = App.routes(req, io, alloc, b);
            sent.giveBack(req);
            return settle(b, done) catch |e| {
                // **A FAILURE IS A 500, NEVER SILENCE** (metal-vmm QUEUE 123, Steve:
                // louder is better): an error that escapes a handler before its
                // head is sent is answered here, for both hosts, and still goes on
                // to the host to log. Once the head is out, the answer is the
                // handler's, cut short, and only the connection's close can say so.
                if (e == error.MalformedForm) {
                    // The client's, not the server's (http.formField): said as such,
                    // and nothing for the host to log.
                    if (!sent.any) req.respond("The form was malformed.\n", .{ .status = .bad_request, .keep_alive = false }) catch {};
                    return null;
                }
                answerFailure(req, &sent);
                return e;
            };
        }
    };
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
/// does. So the router lends each handler a writer of its own in place of
/// the connection's, which passes every byte through to it, and notes that
/// one was written. It buffers as the connection's does (the protocol's
/// writers format chunk headers in place), and is given back, its buffer
/// passed on unflushed, when the handler returns: before the host flushes
/// or serves a kept stream, on the connection's own writer.
const Sent = struct {
    to: *std.Io.Writer,
    any: bool,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .sendFile = sendFile, .flush = flush };

    fn lend(self: *Sent, req: *std.http.Server.Request, buffer: []u8) void {
        self.* = .{ .to = req.server.out, .any = false, .writer = .{ .buffer = buffer, .vtable = &vtable } };
        req.server.out = &self.writer;
    }

    /// Back to the connection's writer, with what this one still holds.
    fn giveBack(self: *Sent, req: *std.http.Server.Request) void {
        self.pass() catch {};
        req.server.out = self.to;
    }

    /// What is buffered, to the connection's writer.
    fn pass(self: *Sent) std.Io.Writer.Error!void {
        const w = &self.writer;
        if (w.end == 0) return;
        self.any = true;
        defer w.end = 0;
        try self.to.writeAll(w.buffer[0..w.end]);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sent = @alignCast(@fieldParentPtr("writer", w));
        try self.pass();
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
fn answerFailure(req: *std.http.Server.Request, sent: *const Sent) void {
    if (sent.any) return;
    req.respond("The server failed.\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
}

const testing = std.testing;

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
    answerFailure(&req, &sent);
    try out.writer.flush();
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "500") == null);
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

test "site: an application's failure is a 500 that names nothing, a malformed form a 400, and success what it answered" {
    const App = struct {
        pub fn routes(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, _: *Bus) !void {
            const target = try @import("http.zig").target(req, alloc);
            defer alloc.free(target);
            if (std.mem.eql(u8, target, "/fails")) return error.SomethingBroke;
            if (std.mem.eql(u8, target, "/form")) return error.MalformedForm;
            try req.respond("hello", .{ .keep_alive = false });
        }
    };
    const Served = Site(App);
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var hub = bus.Hub.init(threaded.io(), testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    for ([_]struct { target: []const u8, head: []const u8, body: []const u8, err: ?anyerror }{
        .{ .target = "/fails", .head = "HTTP/1.1 500", .body = "The server failed.\n", .err = error.SomethingBroke },
        .{ .target = "/form", .head = "HTTP/1.1 400", .body = "The form was malformed.\n", .err = null },
        .{ .target = "/", .head = "HTTP/1.1 200", .body = "hello", .err = null },
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
        try out.writer.flush();
        try testing.expect(std.mem.startsWith(u8, out.written(), case.head));
        try testing.expect(std.mem.endsWith(u8, out.written(), case.body));
    }
}
