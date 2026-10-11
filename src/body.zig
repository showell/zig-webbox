//! body: **WHEN A REQUEST'S BODY IS READ, AND HOW LONG IT MAY TAKE** (metal-vmm
//! QUEUE 166, 167, and 169, which redid 166). Part of the `webbox` library.
//! One rule for every host, said here once: Linux's (linux_host.zig) and the
//! bare-metal kernel's (gopher-metal's probe/gopher.zig) both read it.
//!
//! The application handles one request at a time (the turn). **THE TURN
//! NEVER WAITS ON THE NETWORK**: every body is in memory before its request
//! takes the turn, so a slow link holds up nobody but itself. The rule:
//!
//!   1. **The route says its cap, from the head** (a site's `bodyLimit`). A
//!      Content-Length past it is refused before a byte is read; a chunked
//!      body past it, when it passes. Both framings at once is a 400 (RFC
//!      9112 §6.1: a sender must not, and a server may refuse).
//!   2. **A small body** (a route whose cap is at most `before_turn_most`)
//!      is read whole before the turn within `smallMs`: ten seconds and its
//!      bytes at the slowest link seen in production, 64 KiB/s.
//!   3. **An upload** (a route whose cap is past it) is read whole into
//!      memory before the turn, within `upload_ms`, five minutes (the page
//!      waits as long). It needs one of `upload_slots` slots, three a host,
//!      at most one a human, so memory holds at most three uploads; and **who
//!      is asking is checked first** (a site's `uploader`, from the head), so
//!      a stranger never holds a slot: their body is never read, and the
//!      route refuses them. An uploader with no slot free waits on its own
//!      connection, holding no one else, for `slot_wait_ms`; then a 503.
//!   4. The host answers `100-continue` only for a body this plan reads (a
//!      refused one gets its refusal instead), then reads it as any other.
//!   5. A deadline the host cannot arm is a 503, never a read without one.
//!   6. A host logs each upload's size and how long it took to arrive.

const std = @import("std");
const Head = std.http.Server.Request.Head;

/// The largest body read before the turn without an upload slot: the largest
/// cap of any ordinary route (angry-gopher's doc). A route with a larger cap
/// is an upload.
pub const before_turn_most: u64 = 1 << 20;

/// A small body's time besides its bytes at the slow link.
pub const small_base_ms: u64 = 10_000;

/// The slowest link a small body is sized for: a 1.8 MB photo from India
/// arrived at ~65 KB/s (metal-vmm QUEUE 169). A 1 MiB doc has 26 s.
pub const slow_link_bytes_per_s: u64 = 64 * 1024;

/// How long an upload may take to arrive, whole, from its slot: five
/// minutes, as long as the page waits (angry-gopher `fd2c7ab`).
pub const upload_ms: u64 = 5 * 60 * 1000;

/// How many uploads a host reads at once, at most one a human: memory holds
/// at most this many upload caps.
pub const upload_slots = 3;

/// How long an uploader waits for a slot, on its own connection, before a
/// 503 that says the uploads are busy.
pub const slot_wait_ms: u64 = 30_000;

/// The longest a small body may take to arrive, sized from `bytes`, the most
/// it can be.
pub fn smallMs(bytes: u64) u64 {
    const at_link = (@as(u128, bytes) * 1000 + slow_link_bytes_per_s - 1) / slow_link_bytes_per_s;
    return small_base_ms + @as(u64, @intCast(@min(at_link, std.math.maxInt(u64) / 2)));
}

/// The most bytes of a chunked body's framing and data a host keeps for a
/// body of at most `cap`: its data, and a quarter again for chunk sizes and
/// line ends (a sender of tiny chunks past that is refused, 413).
pub fn chunkedRawMost(cap: u64) u64 {
    return cap +| cap / 4 +| 4096;
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
    /// An upload without a Content-Length (chunked): 411. An upload's
    /// memory is its length, known before a slot is given, so three slots
    /// are three lengths at most (a browser's upload always says one).
    length_required,
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

/// When a body is read: always before the turn.
pub const Plan = union(enum) {
    none,
    refused: Refusal,
    /// A small body: read whole, within `deadline_ms` of its head.
    small: Read,
    /// An upload: read whole into memory once its uploader is known and has
    /// a slot, within `deadline_ms` of the slot.
    upload: Read,

    /// The read, for either kind.
    pub fn read(self: Plan) ?Read {
        return switch (self) {
            .small, .upload => |r| r,
            .none, .refused => null,
        };
    }
};

pub const Read = struct {
    /// The most the body can be: its Content-Length, or the route's cap.
    bytes: u64,
    deadline_ms: u64,
};

/// The plan for a body under `head`, given its route's cap.
pub fn plan(head: *const Head, cap: u64) Plan {
    const f = switch (framing(head)) {
        .refused => |r| return .{ .refused = r },
        .framing => |f| f,
    };
    const bytes = switch (f) {
        .none => return .none,
        .length => |n| if (n > cap) return .{ .refused = .too_large } else n,
        .chunked => if (cap > before_turn_most) return .{ .refused = .length_required } else cap,
    };
    if (cap <= before_turn_most) return .{ .small = .{ .bytes = bytes, .deadline_ms = smallMs(bytes) } };
    return .{ .upload = .{ .bytes = bytes, .deadline_ms = upload_ms } };
}

/// **THE UPLOAD SLOTS**: three a host, at most one a human. A human is named
/// by a key the host makes of the site's `uploader` (`keyOf`). Pure; a host
/// that takes from more than one thread holds its own lock around it.
pub const Slots = struct {
    held: [upload_slots]?u64 = @splat(null),

    pub const Taken = union(enum) {
        slot: usize,
        /// Every slot is held: wait.
        all_busy,
        /// This human holds one already: wait.
        human_has_one,
    };

    pub fn take(self: *Slots, who: u64) Taken {
        for (self.held) |h| if (h == who) return .human_has_one;
        for (&self.held, 0..) |*h, i| if (h.* == null) {
            h.* = who;
            return .{ .slot = i };
        };
        return .all_busy;
    }

    pub fn giveBack(self: *Slots, slot: usize) void {
        std.debug.assert(self.held[slot] != null);
        self.held[slot] = null;
    }

    pub fn inUse(self: *const Slots) usize {
        var n: usize = 0;
        for (self.held) |h| n += @intFromBool(h != null);
        return n;
    }
};

/// The slot key of an uploader as the site names them.
pub fn keyOf(uploader: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5107, uploader);
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
    var scan: ChunkedScan = .{};
    return scan.end(bytes);
}

/// **A CHUNKED BODY READ ONCE, AS IT COMES** (169's cold review): the offset
/// of the first chunk not yet whole, kept between calls, so a host that asks
/// again as bytes arrive parses each chunk once, not the whole body each
/// time (a body of a million one-byte chunks asked of on every pass stalled
/// the one loop).
pub const ChunkedScan = struct {
    /// Where the next chunk's size line begins.
    at: usize = 0,

    /// How far `bytes` (the body so far, from its first chunk's size, the
    /// same bytes as before and more) has come.
    pub fn end(self: *ChunkedScan, bytes: []const u8) ChunkedEnd {
        while (true) {
            var at = self.at;
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
            self.at = n + 2;
        }
    }
};

/// After the last chunk: "\r\n", or trailer lines ended by an empty one.
fn trailersEnd(bytes: []const u8, at: usize) ChunkedEnd {
    if (bytes.len < at + 2) return .partial;
    if (bytes[at] == '\r' and bytes[at + 1] == '\n') return .{ .whole = at + 2 };
    var hp: std.http.HeadParser = .{ .state = .seen_rn };
    const n = hp.feed(bytes[at + 2 ..]);
    if (hp.state != .finished) return .partial;
    return .{ .whole = at + 2 + n };
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
    try testing.expectEqual(Refusal.too_large, plan(&h, 100).refused);
    h = try headOf("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n");
    try testing.expectEqual(@as(u64, 100), plan(&h, 100).small.bytes);
}

test "plan: a route's cap past before_turn_most makes an upload, of five minutes; one at it, a small body" {
    var h = try headOf("POST / HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n");
    const up = plan(&h, 4 * before_turn_most).upload;
    try testing.expectEqual(@as(u64, 2_000_000), up.bytes);
    try testing.expectEqual(upload_ms, up.deadline_ms);
    h = try headOf("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n");
    // Small even with a small Content-Length on an upload route: it is the
    // route's cap that says.
    try testing.expect(plan(&h, before_turn_most + 1) == .upload);
    try testing.expect(plan(&h, before_turn_most) == .small);
    h = try headOf("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectEqual(@as(u64, 500), plan(&h, 500).small.bytes);
    // A chunked upload says no length: refused, 411.
    try testing.expectEqual(Refusal.length_required, plan(&h, 4 * before_turn_most).refused);
    h = try headOf("GET / HTTP/1.1\r\nContent-Length: 10\r\n\r\n");
    try testing.expect(plan(&h, 500) == .none);
}

test "deadlines: a small body has ten seconds and its bytes at 64 KiB/s; no overflow" {
    try testing.expectEqual(@as(u64, 10_000), smallMs(0));
    try testing.expectEqual(@as(u64, 10_016), smallMs(1024));
    try testing.expectEqual(@as(u64, 26_000), smallMs(1 << 20));
    _ = smallMs(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 300_000), upload_ms);
    try testing.expectEqual(@as(u64, 5000 + 1250 + 4096), chunkedRawMost(5000));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), chunkedRawMost(std.math.maxInt(u64)));
}

test "slots: three a host, one a human, given back" {
    var slots: Slots = .{};
    const ann = keyOf("1");
    try testing.expectEqual(Slots.Taken{ .slot = 0 }, slots.take(ann));
    try testing.expectEqual(Slots.Taken.human_has_one, slots.take(ann));
    try testing.expectEqual(Slots.Taken{ .slot = 1 }, slots.take(keyOf("2")));
    try testing.expectEqual(Slots.Taken{ .slot = 2 }, slots.take(keyOf("3")));
    try testing.expectEqual(Slots.Taken.all_busy, slots.take(keyOf("4")));
    try testing.expectEqual(@as(usize, 3), slots.inUse());
    slots.giveBack(1);
    try testing.expectEqual(Slots.Taken{ .slot = 1 }, slots.take(keyOf("4")));
    slots.giveBack(0);
    try testing.expectEqual(Slots.Taken{ .slot = 0 }, slots.take(ann));
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

test "a chunked scan asked again as bytes come agrees with one asked once, and parses each chunk once" {
    const body = "3\r\nhel\r\n2;x=y\r\nlo\r\n1\r\n!\r\n0\r\nX-T: 1\r\n\r\n";
    var scan: ChunkedScan = .{};
    for (0..body.len + 1) |n| {
        try testing.expectEqual(chunkedEnd(body[0..n]), scan.end(body[0..n]));
    }
    // The scan stopped at the last chunk's size line: the three before it
    // are never parsed again.
    try testing.expectEqual(@as(usize, "3\r\nhel\r\n2;x=y\r\nlo\r\n1\r\n!\r\n".len), scan.at);
}
