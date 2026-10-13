//! traffic: what the requests since boot were, counted where every host's
//! requests pass (site.route), for /admin/host and /admin/log (metal-vmm
//! QUEUE 189.5). Part of the `webbox` library: std and one another only.
//!
//! Since boot: requests by status class and by route family (the
//! application's own, `App.family`), the slowest few with their time, path
//! and duration, and every answer 500 or over, the last `errors_kept` of them
//! with their line. **A PATH IS KEPT AS THE LOG KEEPS IT**: without its
//! query, and an `/uploads/` segment (an upload's name) taken out.
//!
//! Each host routes one request at a time (the kernel's one loop; Linux's
//! turn lock), so these are plain counters.

const std = @import("std");

pub const slowest_kept = 5;
pub const errors_kept = 20;
pub const families_most = 12;

pub const Seen = struct {
    /// Unix milliseconds, if the host said.
    at_unix_ms: ?i64 = null,
    took_ns: u64 = 0,
    status: u16 = 0,
    path: Text = .{},
    /// How the route ended, when it failed: the error's name.
    err: Text = .{},
};

pub const Text = struct {
    pub const capacity = 120;
    buf: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn slice(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

/// One request, as the route saw it.
pub const Note = struct {
    family: []const u8,
    status: u16,
    took_ns: u64,
    target: []const u8,
    at_unix_ms: ?i64 = null,
    err: ?[]const u8 = null,
};

pub const Traffic = struct {
    total: u64 = 0,
    /// 0: no status line went out; 1..5: 1xx..5xx.
    by_class: [6]u64 = @splat(0),
    families: [families_most][]const u8 = undefined,
    by_family: [families_most]u64 = @splat(0),
    n_families: usize = 0,
    slowest: [slowest_kept]Seen = undefined,
    n_slowest: usize = 0,
    errors: [errors_kept]Seen = undefined,
    n_errors: u64 = 0,

    pub fn note(t: *Traffic, n: Note) void {
        t.total += 1;
        t.by_class[if (n.status >= 100 and n.status < 600) n.status / 100 else 0] += 1;
        t.countFamily(n.family);
        var seen: Seen = .{ .at_unix_ms = n.at_unix_ms, .took_ns = n.took_ns, .status = n.status, .path = keptPath(n.target) };
        if (n.err) |e| {
            seen.err.len = @min(e.len, seen.err.buf.len);
            @memcpy(seen.err.buf[0..seen.err.len], e[0..seen.err.len]);
        }
        t.keepSlow(seen);
        if (n.status >= 500 or (n.status == 0 and n.err != null)) {
            t.errors[@intCast(t.n_errors % errors_kept)] = seen;
            t.n_errors += 1;
        }
    }

    fn countFamily(t: *Traffic, family: []const u8) void {
        for (t.families[0..t.n_families], 0..) |f, i| if (std.mem.eql(u8, f, family)) {
            t.by_family[i] += 1;
            return;
        };
        // Past the most: counted under the last one there is room for.
        if (t.n_families == families_most) {
            t.by_family[families_most - 1] += 1;
            return;
        }
        t.families[t.n_families] = family;
        t.by_family[t.n_families] = 1;
        t.n_families += 1;
    }

    /// Kept slowest first; a request no slower than the slowest kept is not.
    fn keepSlow(t: *Traffic, seen: Seen) void {
        var at = t.n_slowest;
        while (at > 0 and t.slowest[at - 1].took_ns < seen.took_ns) at -= 1;
        if (at == slowest_kept) return;
        const last = @min(t.n_slowest, slowest_kept - 1);
        var k = last;
        while (k > at) : (k -= 1) t.slowest[k] = t.slowest[k - 1];
        t.slowest[at] = seen;
        t.n_slowest = @min(t.n_slowest + 1, slowest_kept);
    }

    /// The `i`th newest 5xx kept, 0 the newest.
    pub fn newestError(t: *const Traffic, i: usize) ?*const Seen {
        if (i >= @min(t.n_errors, errors_kept)) return null;
        return &t.errors[@intCast((t.n_errors - 1 - i) % errors_kept)];
    }

    /// `12 requests: 9 2xx, 1 3xx, 1 4xx, 1 5xx`, and `, 0 unanswered` only
    /// when some were; a class with none is left out.
    pub fn writeClasses(t: *const Traffic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} requests", .{t.total});
        var first = true;
        for (1..6) |c| if (t.by_class[c] > 0) {
            try w.print("{s} {d} {d}xx", .{ if (first) ":" else ",", t.by_class[c], c });
            first = false;
        };
        if (t.by_class[0] > 0) try w.print("{s} {d} unanswered", .{ if (first) ":" else ",", t.by_class[0] });
    }

    /// `chat 7, games 3, admin 2`, in the order first seen.
    pub fn writeFamilies(t: *const Traffic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.families[0..t.n_families], t.by_family[0..t.n_families], 0..) |f, n, i|
            try w.print("{s}{s} {d}", .{ if (i == 0) "" else ", ", f, n });
    }
};

/// One request seen: `2026-10-13T14:02:07.123Z GET-less /path 503 in 4.0 ms (ReadOnlyFileSystem)`.
pub fn writeSeen(s: *const Seen, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (s.at_unix_ms) |ms| {
        try writeTime(w, ms);
        try w.writeByte(' ');
    }
    const tenths = s.took_ns / (std.time.ns_per_ms / 10);
    try w.print("{s} {d} in {d}.{d} ms", .{ s.path.slice(), s.status, tenths / 10, tenths % 10 });
    if (s.err.len > 0) try w.print(" ({s})", .{s.err.slice()});
}

/// `2026-10-13T14:02:07.123Z`, as the kernel's request lines spell it.
pub fn writeTime(w: *std.Io.Writer, ms: i64) std.Io.Writer.Error!void {
    if (ms < 0) return w.writeAll("before-1970");
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(ms, std.time.ms_per_s)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const d = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,                                        md.month.numeric(),     md.day_index + 1,
        d.getHoursIntoDay(),                             d.getMinutesIntoHour(), d.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, std.time.ms_per_s))),
    });
}

/// The path, as the log keeps one: no query, an `/uploads/` segment taken out.
fn keptPath(target: []const u8) Text {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q];
    var t: Text = .{};
    var w: std.Io.Writer = .fixed(&t.buf);
    const key = "/uploads/";
    if (std.mem.indexOf(u8, path, key)) |at| {
        const from = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, path, from, '/') orelse path.len;
        w.writeAll(path[0..from]) catch {};
        w.writeAll("[redacted]") catch {};
        w.writeAll(path[end..]) catch {};
    } else w.writeAll(path) catch {};
    t.len = w.end;
    return t;
}

/// The one this process counts into.
pub var global: Traffic = .{};

const testing = std.testing;

fn text(comptime f: anytype, t: *const Traffic) ![]const u8 {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f(t, &w);
    return testing.allocator.dupe(u8, w.buffered());
}

test "traffic: counted by status class and by family, the families in the order first seen" {
    var t: Traffic = .{};
    for ([_]struct { []const u8, u16 }{ .{ "chat", 200 }, .{ "chat", 200 }, .{ "games", 404 }, .{ "admin", 302 }, .{ "chat", 503 }, .{ "uploads", 0 } }) |r|
        t.note(.{ .family = r[0], .status = r[1], .took_ns = 1, .target = "/x" });
    const classes = try text(Traffic.writeClasses, &t);
    defer testing.allocator.free(classes);
    try testing.expectEqualStrings("6 requests: 2 2xx, 1 3xx, 1 4xx, 1 5xx, 1 unanswered", classes);
    const fams = try text(Traffic.writeFamilies, &t);
    defer testing.allocator.free(fams);
    try testing.expectEqualStrings("chat 3, games 1, admin 1, uploads 1", fams);
    const none: Traffic = .{};
    const nothing = try text(Traffic.writeClasses, &none);
    defer testing.allocator.free(nothing);
    try testing.expectEqualStrings("0 requests", nothing);
}

test "traffic: the slowest five kept, slowest first, and every 5xx with its time, path and error, the newest first" {
    var t: Traffic = .{};
    for (0..30) |i| t.note(.{
        .family = "chat",
        .status = if (i % 3 == 0) 500 else 200,
        .took_ns = (i * 7 % 30) * std.time.ns_per_ms,
        .target = "/chat/c/1_2/T?since=9",
        .at_unix_ms = @intCast(1_791_900_127_000 + i),
        .err = if (i % 3 == 0) "OutOfMemory" else null,
    });
    try testing.expectEqual(@as(usize, 5), t.n_slowest);
    try testing.expectEqual(@as(u64, 29 * std.time.ns_per_ms), t.slowest[0].took_ns);
    for (1..5) |k| try testing.expect(t.slowest[k - 1].took_ns >= t.slowest[k].took_ns);
    try testing.expectEqual(@as(u64, 10), t.n_errors);
    const newest = t.newestError(0).?;
    try testing.expectEqual(@as(i64, 1_791_900_127_027), newest.at_unix_ms.?);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSeen(newest, &w);
    try testing.expectEqualStrings("2026-10-13T14:02:07.027Z /chat/c/1_2/T 500 in 9.0 ms (OutOfMemory)", w.buffered());
    try testing.expect(t.newestError(10) == null);
}

test "traffic: a path is kept as the log keeps it: no query, no upload's name" {
    var t: Traffic = .{};
    t.note(.{ .family = "uploads", .status = 500, .took_ns = 0, .target = "/chat/c/1_2/T/uploads/0123456789abcdef.png?x=1" });
    try testing.expectEqualStrings("/chat/c/1_2/T/uploads/[redacted]", t.newestError(0).?.path.slice());
    t.note(.{ .family = "uploads", .status = 500, .took_ns = 0, .target = "/chat/c/1_2/T/uploads/abc/more" });
    try testing.expectEqualStrings("/chat/c/1_2/T/uploads/[redacted]/more", t.newestError(0).?.path.slice());
}
