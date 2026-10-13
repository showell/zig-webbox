//! log_view: the host's log as plain text, for an agent to fetch and grep
//! (metal-vmm QUEUE 189.3). Part of the `webbox` library: pure, given the
//! log's text and a filter; admin_log.zig serves it.
//!
//! **PLAIN TEXT, NOT JSON.** The log is text already, and the question an
//! agent asks of it is a grep ("what happened at 14:02", "every 503"): plain
//! text is `curl | grep` with nothing to undo, where JSON would quote every
//! line and add nothing a line does not already say. What the text is comes
//! first, in header lines that each begin `# `, so `grep -v '^#'` is the log
//! alone.
//!
//! **THE FILTERS**, each optional, all of them together:
//!
//!   since=2026-10-13T14:02    lines from then on: an ISO UTC time, or any
//!                             leading part of one (`2026-10-13T14`). A
//!                             request's line carries its time (189.2); a
//!                             line without one is taken as of the last time
//!                             before it, and a line before any is left out.
//!   until=2026-10-13T14:03    lines before then (the same spelling).
//!   request=12                request 12's line and the lines under it (its
//!                             body's, its upload's: indented four spaces).
//!   path=/gopher/chat         the requests whose path begins so, and the
//!                             lines under them.
//!   boot=this|before|both     this boot's log, the one before it (kept
//!                             across a restart), or both (the default).

const std = @import("std");
const http = @import("http.zig");

pub const Boot = enum { both, this, before };

pub const Filter = struct {
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    request: ?u64 = null,
    path: ?[]const u8 = null,
    boot: Boot = .both,

    fn any(f: Filter) bool {
        return f.since != null or f.until != null or f.request != null or f.path != null;
    }
};

/// The filter a request's query asks for. A value spelled wrong is
/// `error.BadFilter`, which the page answers 400 with what is allowed; a bad
/// `%` escape is `error.MalformedForm`, also the client's.
pub fn parseFilter(alloc: std.mem.Allocator, target: []const u8) !Filter {
    const q = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
    var f: Filter = .{};
    errdefer if (f.since) |v| alloc.free(v);
    errdefer if (f.until) |v| alloc.free(v);
    errdefer if (f.path) |v| alloc.free(v);
    if (try http.formField(alloc, q, "since")) |v| f.since = try timeOf(alloc, v);
    if (try http.formField(alloc, q, "until")) |v| f.until = try timeOf(alloc, v);
    if (try http.formField(alloc, q, "request")) |v| {
        defer alloc.free(v);
        // Digits only: no sign, no space, no `_` (std's parseInt takes `+5`).
        if (v.len == 0) return error.BadFilter;
        for (v) |c| if (!std.ascii.isDigit(c)) return error.BadFilter;
        f.request = std.fmt.parseInt(u64, v, 10) catch return error.BadFilter;
    }
    if (try http.formField(alloc, q, "path")) |v| {
        if (v.len == 0 or v[0] != '/') {
            alloc.free(v);
            return error.BadFilter;
        }
        f.path = v;
    }
    if (try http.formField(alloc, q, "boot")) |v| {
        defer alloc.free(v);
        f.boot = std.meta.stringToEnum(Boot, v) orelse return error.BadFilter;
    }
    return f;
}

/// The spelling a time is given in: `2026-10-13T14:02:07.123Z`, or any
/// leading part of it, a year at least. `0` is a digit; the rest is itself.
const time_shape = "0000-00-00T00:00:00.000Z";

fn timeOf(alloc: std.mem.Allocator, v: []const u8) ![]const u8 {
    if (v.len < 4 or v.len > time_shape.len or !shaped(v)) {
        alloc.free(v);
        return error.BadFilter;
    }
    return v;
}

fn shaped(v: []const u8) bool {
    for (v, time_shape[0..v.len]) |c, want| {
        if (want == '0') {
            if (!std.ascii.isDigit(c)) return false;
        } else if (c != want) return false;
    }
    return true;
}

/// The time a line leads with (after its indent), whole, or null.
fn timeAt(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len < time_shape.len or !shaped(t[0..time_shape.len])) return null;
    return t[0..time_shape.len];
}

const RequestLine = struct { number: u64, path: []const u8 };

/// A request's line: `request N: METHOD PATH -> ...`, after its time.
fn requestAt(line: []const u8) ?RequestLine {
    var t = std.mem.trimStart(u8, line, " ");
    if (timeAt(t) != null) t = t[time_shape.len..];
    t = std.mem.trimStart(u8, t, " ");
    if (!std.mem.startsWith(u8, t, "request ")) return null;
    t = t["request ".len..];
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    // The server's own number, written just now: not a request's to spell.
    const number = std.fmt.parseInt(u64, t[0..colon], 10) catch return null;
    var words = std.mem.tokenizeScalar(u8, t[colon + 1 ..], ' ');
    _ = words.next() orelse return null; // the method
    const path = words.next() orelse return null;
    return .{ .number = number, .path = path };
}

/// What one boot's text gave: how many lines it held and how many were kept,
/// and the time its oldest timed line carries.
pub const Counted = struct { lines: usize = 0, kept: usize = 0, oldest: ?[]const u8 = null };

/// Writes the lines of `text` that `f` keeps, each with its newline.
pub fn writeLines(w: *std.Io.Writer, text: []const u8, f: Filter) std.Io.Writer.Error!Counted {
    var c: Counted = .{};
    var time: ?[]const u8 = null;
    var block: ?RequestLine = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.index == null) break; // the text's last newline
        c.lines += 1;
        if (timeAt(line)) |t| {
            time = t;
            if (c.oldest == null) c.oldest = t;
        }
        if (requestAt(line)) |r| {
            block = r;
        } else if (!std.mem.startsWith(u8, line, "    ")) block = null;
        if (!keeps(f, time, block)) continue;
        c.kept += 1;
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    return c;
}

fn keeps(f: Filter, time: ?[]const u8, block: ?RequestLine) bool {
    if (f.since) |since| {
        const t = time orelse return false;
        if (std.mem.order(u8, t, since) == .lt) return false;
    }
    if (f.until) |until| {
        const t = time orelse return false;
        if (std.mem.order(u8, t, until) != .lt) return false;
    }
    if (f.request) |n| {
        const b = block orelse return false;
        if (b.number != n) return false;
    }
    if (f.path) |p| {
        const b = block orelse return false;
        if (!std.mem.startsWith(u8, b.path, p)) return false;
    }
    return true;
}

const testing = std.testing;

const sample =
    "  boot: ram 1 GiB\n" ++
    "  2026-10-13T14:01:59.900Z request 11: GET /gopher/chat -> ok, 200 in 3.0 ms (base: 1)\n" ++
    "  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)\n" ++
    "    upload: 9000 bytes, arrived in 40 ms\n" ++
    "  stream ended: displaced\n" ++
    "  2026-10-13T14:03:00.000Z request 13: GET /admin/host -> ok, 200 in 9.1 ms (base: 3)\n";

fn kept(f: Filter) ![]const u8 {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try writeLines(&w, sample, f);
    return testing.allocator.dupe(u8, w.buffered());
}

fn expectKept(f: Filter, want: []const u8) !void {
    const got = try kept(f);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "log view: no filter keeps every line, and counts them, the oldest time among them" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const c = try writeLines(&w, sample, .{});
    try testing.expectEqualStrings(sample, w.buffered());
    try testing.expectEqual(@as(usize, 6), c.lines);
    try testing.expectEqual(@as(usize, 6), c.kept);
    try testing.expectEqualStrings("2026-10-13T14:01:59.900Z", c.oldest.?);
}

test "log view: since and until by any leading part of a time, a line without one as of the time before it" {
    try expectKept(.{ .since = "2026-10-13T14:02" },
        \\  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)
        \\    upload: 9000 bytes, arrived in 40 ms
        \\  stream ended: displaced
        \\  2026-10-13T14:03:00.000Z request 13: GET /admin/host -> ok, 200 in 9.1 ms (base: 3)
        \\
    );
    try expectKept(.{ .since = "2026-10-13T14:02", .until = "2026-10-13T14:03" },
        \\  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)
        \\    upload: 9000 bytes, arrived in 40 ms
        \\  stream ended: displaced
        \\
    );
    // Before any time: the boot's own lines are left out once a time is asked.
    try expectKept(.{ .until = "2026-10-13T14:02" },
        \\  2026-10-13T14:01:59.900Z request 11: GET /gopher/chat -> ok, 200 in 3.0 ms (base: 1)
        \\
    );
}

test "log view: a request by its number, and requests by their path, with the lines under them" {
    try expectKept(.{ .request = 12 },
        \\  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)
        \\    upload: 9000 bytes, arrived in 40 ms
        \\
    );
    try expectKept(.{ .request = 1 }, ""); // 1 is not 11, 12 or 13
    try expectKept(.{ .path = "/gopher/chat" },
        \\  2026-10-13T14:01:59.900Z request 11: GET /gopher/chat -> ok, 200 in 3.0 ms (base: 1)
        \\  2026-10-13T14:02:07.123Z request 12: POST /gopher/chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)
        \\    upload: 9000 bytes, arrived in 40 ms
        \\
    );
    try expectKept(.{ .path = "/admin", .since = "2026-10-13T14:02:30" },
        \\  2026-10-13T14:03:00.000Z request 13: GET /admin/host -> ok, 200 in 9.1 ms (base: 3)
        \\
    );
}

test "log view: the query's filters, and a value spelled wrong is the client's" {
    const a = testing.allocator;
    const f = try parseFilter(a, "/admin/log?since=2026-10-13T14%3A02&request=12&path=%2Fgopher&boot=before");
    defer if (f.since) |s| a.free(s);
    defer if (f.path) |p| a.free(p);
    try testing.expectEqualStrings("2026-10-13T14:02", f.since.?);
    try testing.expectEqual(@as(?u64, 12), f.request);
    try testing.expectEqualStrings("/gopher", f.path.?);
    try testing.expectEqual(Boot.before, f.boot);
    const none = try parseFilter(a, "/admin/log");
    try testing.expect(!none.any());
    try testing.expectEqual(Boot.both, none.boot);
    for ([_][]const u8{ "?since=yesterday", "?since=2026-1x", "?until=", "?request=", "?request=-1", "?request=+5", "?request=18446744073709551616", "?boot=all", "?path=gopher", "?since=2026-10-13T14:02:07.1234567890Z" }) |q| {
        const t = try std.fmt.allocPrint(a, "/admin/log{s}", .{q});
        defer a.free(t);
        try testing.expectError(error.BadFilter, parseFilter(a, t));
    }
    try testing.expectError(error.MalformedForm, parseFilter(a, "/admin/log?path=%zz"));
}

test "log view: a request refused at its head is found by its path, its upload line with it (metal-vmm QUEUE 194.5)" {
    // The kernel's refusal line carries METHOD PATH, as the route's does
    // (zig-metal-unikernel request_line.what).
    const text =
        \\  2026-10-13T14:02:07.123Z request 20: POST /chat/c/1_2/T/upload (refused at its head) -> every upload slot is held, 503 (base: 2)
        \\    upload: 2026-10-13T14:02:07.123Z request 20: /chat/c/1_2/T/upload, 0 bytes, not whole after 0 ms, 0 disk requests: busy (503)
        \\  2026-10-13T14:02:08.000Z request 21: POST /chat/c/1_2/T/upload -> ok, 200 in 41.3 ms (base: 2)
        \\
    ;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try writeLines(&w, text, .{ .path = "/chat/c/1_2/T/upload" });
    try testing.expectEqualStrings(text, w.buffered());
}
