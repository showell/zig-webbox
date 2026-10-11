//! body: **WHEN A REQUEST'S BODY IS READ, AND HOW LONG IT MAY TAKE** (metal-vmm
//! QUEUE 166 and 167). Part of the `webbox` library. One rule for every host,
//! said here once: Linux's (linux_host.zig) and the bare-metal kernel's
//! (gopher-metal's probe/gopher.zig) both read it.
//!
//! The application handles one request at a time (the turn), so a body read
//! inside the turn holds every other request up while it arrives. The rule:
//!
//!   1. **The route says its cap, from the head** (a site's `bodyLimit`). A
//!      Content-Length past it is refused before a byte is read; a chunked
//!      body past it, when it passes. Both framings at once is a 400 (RFC
//!      9112 §6.1: a sender must not, and a server may refuse).
//!   2. **A body that fits the host's room is read before the turn, whole**,
//!      holding only its own connection, for at most `beforeTurnMs`. The
//!      room is what the host can hold for a body it has not started: a
//!      connection's buffer on metal, `before_turn_most` on Linux.
//!   3. **One that does not is read in the turn, under one deadline for the
//!      whole body** (`inTurnMs`, from the turn's start), never one a read.
//!      Past it the read fails, the handler's `http.readLimitedBody` answers
//!      408 (it asks `lateInTurn`), and the connection closes.
//!   4. **Both deadlines are sized from the body**: a base, and its bytes at
//!      `floor_bytes_per_s`. A sender slower than the floor fails; that is the
//!      line. What a slow sender costs others is its in-turn deadline, at most.
//!   5. The host answers `100-continue` only for a body this plan reads (a
//!      refused one gets its refusal instead), then waits as for any other.
//!   6. A deadline the host cannot arm is a 503, never a read without one.

const std = @import("std");
const Head = std.http.Server.Request.Head;

/// The slowest a body may arrive, in bytes a second: about 8 Mbit/s. 40 MB
/// at 20 Mbit/s takes 16 s and is allowed 40 s.
pub const floor_bytes_per_s: u64 = 1 << 20;

/// What a body read before the turn is allowed besides its bytes at the floor.
/// Long, because it holds up nobody but its own connection.
pub const before_turn_base_ms: u64 = 10_000;

/// What a body read in the turn is allowed besides its bytes at the floor.
/// Short, because it holds up every other request.
pub const in_turn_base_ms: u64 = 2_000;

/// The most a Linux host holds for a body before the turn: the largest cap of
/// any ordinary route (angry-gopher's doc). A route with a larger cap (the
/// upload) is read in the turn.
pub const before_turn_most: u64 = 1 << 20;

/// The longest a body read before the turn may take, sized from `bytes`, the
/// most it can be.
pub fn beforeTurnMs(bytes: u64) u64 {
    return before_turn_base_ms + atFloorMs(bytes);
}

/// The longest a body read in the turn may take from the turn's start, sized
/// from `bytes`, the most it can be.
pub fn inTurnMs(bytes: u64) u64 {
    return in_turn_base_ms + atFloorMs(bytes);
}

/// `bytes` at the floor, in milliseconds rounded up; held well below u64's
/// largest, so a base added to it cannot overflow.
fn atFloorMs(bytes: u64) u64 {
    const ms = (@as(u128, bytes) * 1000 + floor_bytes_per_s - 1) / floor_bytes_per_s;
    return @intCast(@min(ms, std.math.maxInt(u64) / 2));
}

/// How a request's head says its body is framed.
pub const Framing = union(enum) {
    /// No body: a method that takes none, or neither header.
    none,
    length: u64,
    chunked,
};

pub const Refusal = enum {
    /// Its Content-Length is past the route's cap: 413.
    too_large,
    /// Both Content-Length and Transfer-Encoding: 400.
    framed_twice,
};

pub const Framed = union(enum) { framing: Framing, refused: Refusal };

/// The head's framing, as std's reader will read it: a method that takes no
/// body is read as having none, whatever its headers say.
pub fn framing(head: *const Head) Framed {
    if (!head.method.requestHasBody()) return .{ .framing = .none };
    if (head.transfer_encoding != .none and head.content_length != null) return .{ .refused = .framed_twice };
    if (head.transfer_encoding == .chunked) return .{ .framing = .chunked };
    if (head.content_length) |n| return .{ .framing = .{ .length = n } };
    return .{ .framing = .none };
}

/// When a body is read.
pub const Plan = union(enum) {
    none,
    refused: Refusal,
    /// Whole, before the turn, within `deadline_ms` of its head.
    before_turn: Read,
    /// In the turn, within `deadline_ms` of the turn's start.
    in_turn: Read,
    /// A chunked body whose cap is past the room: waited for before the turn
    /// while it can still end in the room (`before`), and read in the turn
    /// (`in_turn`) once it cannot. A host that keeps no partial body before
    /// the turn (Linux) reads it in the turn.
    chunked_as_far_as_room: struct { before: Read, in_turn: Read },
};

pub const Read = struct {
    /// The most the body can be: its Content-Length, or the route's cap.
    bytes: u64,
    deadline_ms: u64,
};

/// The plan for a body under `head`, given its route's cap and the host's
/// room for a body before the turn.
pub fn plan(head: *const Head, cap: u64, room: u64) Plan {
    const f = switch (framing(head)) {
        .refused => |r| return .{ .refused = r },
        .framing => |f| f,
    };
    switch (f) {
        .none => return .none,
        .length => |n| {
            if (n > cap) return .{ .refused = .too_large };
            if (n <= room) return .{ .before_turn = .{ .bytes = n, .deadline_ms = beforeTurnMs(n) } };
            return .{ .in_turn = .{ .bytes = n, .deadline_ms = inTurnMs(n) } };
        },
        .chunked => {
            if (cap <= room) return .{ .before_turn = .{ .bytes = cap, .deadline_ms = beforeTurnMs(cap) } };
            return .{ .chunked_as_far_as_room = .{
                .before = .{ .bytes = room, .deadline_ms = beforeTurnMs(room) },
                .in_turn = .{ .bytes = cap, .deadline_ms = inTurnMs(cap) },
            } };
        },
    }
}

/// How far a chunked body in `bytes` (from its first chunk's size) has come,
/// read as std's reader reads it.
pub const ChunkedEnd = union(enum) {
    /// It ends `n` bytes in, its last chunk and trailers included.
    whole: usize,
    /// It has not ended yet.
    partial,
    /// It never will: std's reader will refuse it (the handler answers 400).
    malformed,
};

pub fn chunkedEnd(bytes: []const u8) ChunkedEnd {
    var at: usize = 0;
    while (true) {
        var cp: std.http.ChunkParser = .init;
        at += cp.feed(bytes[at..]);
        switch (cp.state) {
            .invalid => return .malformed,
            .data => {},
            else => return .partial,
        }
        if (cp.chunk_len == 0) return trailersEnd(bytes, at);
        // The chunk, then exactly "\r\n" (std's `.rn`).
        const after = std.math.add(u64, at, cp.chunk_len) catch return .malformed;
        if (after + 2 > bytes.len) return .partial;
        const n: usize = @intCast(after);
        if (bytes[n] != '\r' or bytes[n + 1] != '\n') return .malformed;
        at = n + 2;
    }
}

/// After the last chunk: "\r\n", or trailer lines ended by an empty one.
fn trailersEnd(bytes: []const u8, at: usize) ChunkedEnd {
    if (bytes.len < at + 2) return .partial;
    if (bytes[at] == '\r' and bytes[at + 1] == '\n') return .{ .whole = at + 2 };
    var hp: std.http.HeadParser = .{ .state = .seen_rn };
    const n = hp.feed(bytes[at + 2 ..]);
    if (hp.state != .finished) return .partial;
    return .{ .whole = at + 2 + n };
}

/// **THE TURN'S BODY RAN PAST ITS DEADLINE.** Set by the host when the
/// in-turn deadline passes (its read is ended then), read by
/// `http.readLimitedBody` to answer 408 rather than 400, and cleared by the
/// host as each turn starts. One for the process: only one turn runs at once.
pub var late_in_turn: std.atomic.Value(bool) = .init(false);

pub fn lateInTurn() bool {
    return late_in_turn.load(.acquire);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn headOf(raw: []const u8) !Head {
    return Head.parse(raw);
}

test "framing: a method without a body has none; both framings are refused" {
    var h = try headOf("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n");
    try testing.expectEqual(Framing.none, framing(&h).framing);
    h = try headOf("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectEqual(Refusal.framed_twice, framing(&h).refused);
    h = try headOf("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectEqual(Framing.chunked, framing(&h).framing);
    h = try headOf("POST / HTTP/1.1\r\n\r\n");
    try testing.expectEqual(Framing.none, framing(&h).framing);
}

test "plan: past the cap is refused, unread; the cap itself is read" {
    var h = try headOf("POST / HTTP/1.1\r\nContent-Length: 101\r\n\r\n");
    try testing.expectEqual(Refusal.too_large, plan(&h, 100, 1000).refused);
    h = try headOf("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n");
    try testing.expectEqual(@as(u64, 100), plan(&h, 100, 1000).before_turn.bytes);
}

test "plan: a body that fits the room is read before the turn, one past it in the turn" {
    var h = try headOf("POST / HTTP/1.1\r\nContent-Length: 1000\r\n\r\n");
    try testing.expect(plan(&h, 1 << 20, 1000) == .before_turn);
    h = try headOf("POST / HTTP/1.1\r\nContent-Length: 1001\r\n\r\n");
    const p = plan(&h, 1 << 20, 1000).in_turn;
    try testing.expectEqual(@as(u64, 1001), p.bytes);
    try testing.expectEqual(in_turn_base_ms + 1, p.deadline_ms);
}

test "plan: chunked is sized by the cap; past the room it is waited for as far as the room" {
    var h = try headOf("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectEqual(@as(u64, 500), plan(&h, 500, 1000).before_turn.bytes);
    const p = plan(&h, 4000, 1000).chunked_as_far_as_room;
    try testing.expectEqual(@as(u64, 1000), p.before.bytes);
    try testing.expectEqual(@as(u64, 4000), p.in_turn.bytes);
}

test "deadlines: a base and the bytes at the floor, rounded up" {
    try testing.expectEqual(@as(u64, 10_000), beforeTurnMs(0));
    try testing.expectEqual(@as(u64, 2_001), inTurnMs(1));
    try testing.expectEqual(@as(u64, 3_000), inTurnMs(1 << 20));
    // The largest upload angry-gopher takes (101 MiB): about 103 s.
    try testing.expectEqual(@as(u64, 103_000), inTurnMs(101 << 20));
    // No overflow at the largest Content-Length.
    _ = inTurnMs(std.math.maxInt(u64));
}

test "chunkedEnd: whole, partial at every cut, trailers, and malformed" {
    const body = "3\r\nhel\r\n2;x=y\r\nlo\r\n0\r\n\r\nNEXT";
    const whole = body.len - 4;
    try testing.expectEqual(ChunkedEnd{ .whole = whole }, chunkedEnd(body));
    for (0..whole) |n| try testing.expectEqual(ChunkedEnd.partial, chunkedEnd(body[0..n]));
    try testing.expectEqual(ChunkedEnd{ .whole = 21 }, chunkedEnd("0\r\nX-T: 1\r\nX-U: 2\r\n\r\n"));
    try testing.expectEqual(ChunkedEnd.partial, chunkedEnd("0\r\nX-T: 1\r\n"));
    try testing.expectEqual(ChunkedEnd.malformed, chunkedEnd("3\r\nhelXX"));
    try testing.expectEqual(ChunkedEnd.malformed, chunkedEnd("3\rX"));
    // A chunk size near u64's largest neither overflows nor reads past the
    // end: no cap is that large, so it is refused.
    try testing.expectEqual(ChunkedEnd.malformed, chunkedEnd("ffffffffffffffff\r\nab"));
    try testing.expectEqual(ChunkedEnd.partial, chunkedEnd("fffffff\r\nab"));
}

test "chunkedEnd agrees with std's reader on what it reads whole" {
    for ([_][]const u8{
        "3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n",
        "0\r\n\r\n",
        "1\r\na\r\n0\r\nX: y\r\n\r\n",
        "0\r\nX-T: 1\r\nX-U: 2\r\n\r\n",
        "A\r\n0123456789\r\n0\r\n\r\n",
    }) |b| {
        const n = chunkedEnd(b).whole;
        try testing.expectEqual(b.len, n);
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(testing.allocator);
        try raw.appendSlice(testing.allocator, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
        try raw.appendSlice(testing.allocator, b);
        var in: std.Io.Reader = .fixed(raw.items);
        var out: std.Io.Writer.Discarding = .init(&.{});
        var server = std.http.Server.init(&in, &out.writer);
        var req = try server.receiveHead();
        var buf: [64]u8 = undefined;
        const r = req.readerExpectNone(&buf);
        const got = try r.allocRemaining(testing.allocator, .unlimited);
        testing.allocator.free(got);
        // std consumed exactly what chunkedEnd says ends the body.
        try testing.expectEqual(@as(usize, 0), in.bufferedLen());
    }
}
