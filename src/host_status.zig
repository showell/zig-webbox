//! host_status: what the HOST says about itself, for /admin/host.
//!
//! The route table knows the application: its version, its commit, its memory
//! meter. It does not know the machine it runs on, and must not reach for it
//! (router.zig's rule). But the facts an operator needs most are the host's —
//! when it started, what disk the data is on and how full, what memory it has
//! used. Linux has them from /proc and the environment; gopher-metal has them
//! from its own volumes, clocks and counters. So each host HANDS them over, as
//! labelled strings, and the page renders whatever it was given. A host that
//! gives nothing still gets the application's half.
//!
//! The report runs per request, on that request's allocator, so a host can
//! compute its facts fresh (uptime, free space) without keeping anything.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

pub const Fact = struct { label: []const u8, value: []const u8 };

/// A host's facts, in the order it wants them shown.
pub const Report = *const fn (io: Io, alloc: Alloc) anyerror![]const Fact;

var report: ?Report = null;

/// The host calls this once, before serving. Optional: see the host contract
/// in router.zig.
pub fn provide(r: Report) void {
    report = r;
}

/// The host's facts, or none when the host provided no report. An error from
/// the report becomes one fact saying so, rather than a failed page: the
/// application's half is still worth showing.
pub fn facts(io: Io, alloc: Alloc) ![]const Fact {
    const r = report orelse return &.{};
    return r(io, alloc) catch |e| {
        const one = try alloc.alloc(Fact, 1);
        one[0] = .{ .label = "the host's report", .value = @errorName(e) };
        return one;
    };
}

// ── formatting, shared so both hosts read alike ─────────────────────────────

/// `2026-10-02 14:03:09 UTC`.
pub fn utc(alloc: Alloc, unix: i64) ![]const u8 {
    if (unix < 0) return "before 1970";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const t = es.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        day.year,            md.month.numeric(),     md.day_index + 1,
        t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute(),
    });
}

/// `3d 4h 05m`, `4h 05m 09s`, `9s`: as precise as is worth reading.
pub fn duration(alloc: Alloc, seconds: i64) ![]const u8 {
    const s: u64 = @intCast(@max(seconds, 0));
    const d = s / 86400;
    const h = s % 86400 / 3600;
    const m = s % 3600 / 60;
    const sec = s % 60;
    if (d > 0) return std.fmt.allocPrint(alloc, "{d}d {d}h {d:0>2}m", .{ d, h, m });
    if (h > 0) return std.fmt.allocPrint(alloc, "{d}h {d:0>2}m {d:0>2}s", .{ h, m, sec });
    if (m > 0) return std.fmt.allocPrint(alloc, "{d}m {d:0>2}s", .{ m, sec });
    return std.fmt.allocPrint(alloc, "{d}s", .{sec});
}

test "times and durations read as an operator wants them" {
    const a = std.testing.allocator;
    const t = try utc(a, 1790085789);
    defer a.free(t);
    try std.testing.expectEqualStrings("2026-09-22 14:03:09 UTC", t);
    const d = try duration(a, 3 * 86400 + 4 * 3600 + 5 * 60 + 9);
    defer a.free(d);
    try std.testing.expectEqualStrings("3d 4h 05m", d);
    const short = try duration(a, 9);
    defer a.free(short);
    try std.testing.expectEqualStrings("9s", short);
}

test "no report is no facts, and a failing one says why" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const saved = report;
    defer report = saved;

    report = null;
    try std.testing.expectEqual(@as(usize, 0), (try facts(io, alloc)).len);

    report = struct {
        fn f(_: Io, _: Alloc) anyerror![]const Fact {
            return error.DiskGone;
        }
    }.f;
    const got = try facts(io, alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("DiskGone", got[0].value);
}
