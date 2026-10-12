//! sse: Server-Sent Events for any application. Part of the `webbox` library.
//!
//! A stream is a response whose body is a run of frames, written as they
//! happen. A handler opens it (`respond`), writes what is already known (a
//! backlog, a preamble) with `push`, and then keeps its subscriber on the
//! request's Bus (bus.zig): the host serves the live part, long after the
//! handler has returned, and sends the `: ping` keepalives. `forward` is the
//! whole of the simplest stream: live only, each published blob one `data:`
//! frame, verbatim.
//!
//! **THE BODY IS DELIMITED BY THE CONNECTION CLOSING**, not chunked: the host
//! writes each live frame as it is, and there is no chunk framing for it to
//! carry on.

const std = @import("std");
const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;
const http = @import("http.zig");
const Bus = @import("bus.zig").Bus;

/// The response headers for an event stream: the content type, no-cache, and
/// x-accel-buffering off (defeats reverse-proxy buffering so frames arrive
/// live).
pub const headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

/// Opens the stream: the event-stream head, and a body written unframed.
/// `head_buffer` holds the head while it is written.
pub fn respond(req: *Request, head_buffer: []u8) !std.http.BodyWriter {
    return req.respondStreaming(head_buffer, .{
        .respond_options = .{ .extra_headers = &headers, .transfer_encoding = .none },
    });
}

/// Sends one frame live. Two flushes are required and the order matters:
/// body.writer.flush() drains the BodyWriter's own buffer into the protocol
/// output, then body.flush() pushes that out the socket. body.flush() ALONE
/// is a no-op while bytes still sit in the writer buffer — the subtle bit
/// that makes SSE actually stream.
pub fn push(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.writer.flush();
    try body.flush();
}

/// **THE SIMPLEST STREAM**: subscribes to `key` and hands the stream to the
/// host, which forwards each blob published to it as one `data:` frame,
/// verbatim. Live only: a page rendered by the server is its backlog, and a
/// published blob is already the JSON its client parses.
pub fn forward(req: *Request, bus: *Bus, key: []const u8) !void {
    const sub = try bus.open(key);
    var held = bus.hold(sub);
    defer held.release();

    var hbuf: [4096]u8 = undefined;
    var body = respond(req, &hbuf) catch return;
    // Send the head now: a live-only stream may have nothing to say for a
    // while, and the browser should know it is connected.
    body.flush() catch return;

    held.keep(renderForward, "");
}

fn renderForward(_: []const u8, arena: Alloc, blob: []const u8) Alloc.Error!?[]const u8 {
    return try std.fmt.allocPrint(arena, "data: {s}\n\n", .{blob});
}

/// **WHERE A STREAM RESUMES**, from the request: its Last-Event-ID (a
/// reconnect) or its `?since=` (a first load); see `resumeAt`.
pub fn readResume(req: *Request, alloc: Alloc) !usize {
    return resumeAt(try http.header(req, alloc, "last-event-id"), http.queryValue(try http.target(req, alloc), "since"));
}

/// The decision, pure: a parseable Last-Event-ID wins (a reconnect resumes
/// AFTER the last frame delivered: n+1); else a parseable `?since=N` (a first
/// load resumes AT n); else 0. A malformed source falls through to the next,
/// so a junk Last-Event-ID doesn't strand a valid `?since`.
pub fn resumeAt(last_event_id: ?[]const u8, since_q: ?[]const u8) usize {
    if (last_event_id) |lei| {
        const t = std.mem.trim(u8, lei, " \t");
        if (std.fmt.parseInt(usize, t, 10)) |n| return n + 1 else |_| {}
    }
    if (since_q) |q| {
        if (std.fmt.parseInt(usize, q, 10)) |n| return n else |_| {}
    }
    return 0;
}

const testing = std.testing;

test "resumeAt: Last-Event-ID resumes after n; ?since resumes at n; junk falls through" {
    // Last-Event-ID (reconnect) → n+1
    try testing.expectEqual(@as(usize, 6), resumeAt("5", null));
    try testing.expectEqual(@as(usize, 6), resumeAt("  5 ", null)); // trimmed
    // ?since (initial load) → n
    try testing.expectEqual(@as(usize, 5), resumeAt(null, "5"));
    // neither present → 0
    try testing.expectEqual(@as(usize, 0), resumeAt(null, null));
    // Last-Event-ID wins over ?since when both are present and valid
    try testing.expectEqual(@as(usize, 6), resumeAt("5", "99"));
    // a junk Last-Event-ID must NOT strand a valid ?since — it falls through
    try testing.expectEqual(@as(usize, 5), resumeAt("garbage", "5"));
    // both unparseable → 0
    try testing.expectEqual(@as(usize, 0), resumeAt("x", "y"));
}

test "forward's frame: a blob as one data frame, verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("data: {\"x\":1}\n\n", (try renderForward("", arena.allocator(), "{\"x\":1}")).?);
}

test "push: a frame is on the connection the moment push returns, not left in a buffer" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var reader: std.Io.Reader = .fixed("GET /s HTTP/1.1\r\nHost: x\r\n\r\n");
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    var hbuf: [4096]u8 = undefined;
    var body = try respond(&req, &hbuf);
    try push(&body, "data: one\n\n");
    try testing.expect(std.mem.endsWith(u8, out.written(), "data: one\n\n"));
    try push(&body, "data: two\n\n");
    try testing.expect(std.mem.endsWith(u8, out.written(), "data: one\n\ndata: two\n\n"));
}
