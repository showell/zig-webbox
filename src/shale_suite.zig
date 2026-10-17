//! **THE INSTALLED SUITE, ON A SCHEDULE** (metal-vmm QUEUE 229, chunk 6;
//! Steve's first idea: scripts on disk once they are well tested). An
//! application declares its scripts, each `{name, source = @embedFile(...),
//! args, period_s}`, and steps the suite from its `between`. Each runs as a
//! **background run** (it only reads), a slice at a time between requests,
//! every `period_s`, scheduled from when it was due (`wake.periodAfter`),
//! never from when it ran. **A SIGNED BACKGROUND RUN GOES FIRST**: while one
//! is going (`script_route.background`) the suite waits.
//!
//! **WHAT IT KEEPS**, under the auth root, out of a script's reach: each
//! name's last run, `{auth}/shale/suite/<name>.out`, replaced whole, its
//! first line how the run ended and the rest what it printed, bounded by
//! the run's output budget; and a line in `shale/log` as each ends.
//! `writeStatus` is what an application's GET shows.
//!
//! **ONLY ON A SCHEDULE.** Running one by name on request would put a run
//! behind the admin's bearer key and no signature: that is the auth path's,
//! proposed in metal-vmm's FEEDBACK, not built.

const std = @import("std");
const Io = @import("host_io").Io;
const store = @import("store.zig");
const script = @import("script/script.zig");
const script_route = @import("script_route.zig");
const wake = @import("wake.zig");

/// One installed script.
pub const Entry = struct {
    /// `a-z`, `0-9`, `_` and `-`: its kept file's name.
    name: []const u8,
    source: []const u8,
    /// Its `arg` values.
    args: []const script.Arg = &.{},
    /// How often it runs, in seconds; at least one.
    period_s: u64,
};

/// The most scripts a suite holds.
pub const most_entries = 16;

/// The most a kept run's output is: its output budget, at most this.
pub const kept_most: usize = 64 * 1024;

pub const Suite = struct {
    entries: []const Entry = &.{},
    /// When each next runs, on the awake clock; null until the first step,
    /// which runs every entry once.
    due: [most_entries]?i96 = @splat(null),
    /// Each one's last run's line (`finished (N steps)` or its stop), for
    /// `writeStatus`, and when it was, in Unix seconds.
    last: [most_entries]Last = @splat(.{}),
    /// The run going, and whose.
    process: ?*script.process.Process = null,
    running: usize = 0,
    backing: std.mem.Allocator = undefined,
    budgets: script.Budgets = .{},
    data_root: []const u8 = "",
    paths: script_route.Paths = undefined,

    const Last = struct { at_s: i64 = 0, runs: u64 = 0, line_buf: [160]u8 = undefined, line_len: usize = 0 };

    pub const InstallError = error{ TooMany, BadName, NoPeriod };

    /// **THE SUITE, INSTALLED**: its entries checked, nothing run yet. The
    /// entries, the roots and the paths are the caller's, kept as long as the
    /// suite; `backing` is the host's long-lived allocator, never a
    /// request's.
    pub fn install(self: *Suite, entries: []const Entry, backing: std.mem.Allocator, budgets: script.Budgets, data_root: []const u8, paths: script_route.Paths) InstallError!void {
        if (entries.len > most_entries) return error.TooMany;
        for (entries) |e| {
            if (!validName(e.name)) return error.BadName;
            if (e.period_s == 0) return error.NoPeriod;
        }
        self.* = .{ .entries = entries, .backing = backing, .budgets = budgets, .data_root = data_root, .paths = paths };
        self.budgets.output_bytes = @min(budgets.output_bytes, kept_most);
    }

    /// **ONE TURN**, from the application's `between`: a slice of the run
    /// going, or the next one due started; what the suite needs next.
    pub fn step(self: *Suite, io: Io, now: wake.Now) wake.Wake {
        if (self.entries.len == 0) return .idle;
        // A signed background run goes first.
        if (script_route.background.process != null) return .more;
        if (self.process) |p| {
            const outcome = p.step(.{ .steps = script_route.slice_steps, .now = now.unix_s });
            if (outcome == .paused) return .more;
            self.end(io, now);
        }
        for (self.entries, 0..) |e, i| {
            const due = self.due[i] orelse now.awake_ns;
            if (due > now.awake_ns) continue;
            self.due[i] = wake.periodAfter(due, @as(i96, e.period_s) * std.time.ns_per_s, now.awake_ns);
            self.start(io, i, now) catch |err| {
                self.said(i, now.unix_s, "not started: {s}", .{@errorName(err)});
                continue;
            };
            return .more;
        }
        return .{ .at = self.nextDue() };
    }

    fn nextDue(self: *const Suite) i96 {
        var soonest: i96 = std.math.maxInt(i96);
        for (self.entries, 0..) |_, i| soonest = @min(soonest, self.due[i].?);
        return soonest;
    }

    fn start(self: *Suite, io: Io, i: usize, now: wake.Now) !void {
        const e = self.entries[i];
        self.process = try script.process.Process.startWith(io, self.backing, self.data_root, e.source, .{ .mode = .background, .args = e.args }, self.budgets, now.unix_s, self.budgets.output_bytes);
        self.running = i;
    }

    /// The run's end: kept, logged, and given back.
    fn end(self: *Suite, io: Io, now: wake.Now) void {
        const p = self.process.?;
        defer {
            p.kill();
            self.process = null;
        }
        const i = self.running;
        const e = self.entries[i];
        const st = p.status();
        var line_buf: [512]u8 = undefined;
        const line = endingLine(&line_buf, st.stop, st.steps);
        self.said(i, now.unix_s, "{s}", .{line});
        var arena = std.heap.ArenaAllocator.init(self.backing);
        defer arena.deinit();
        const a = arena.allocator();
        const kept = std.fmt.allocPrint(a, "{d} {s}\n{s}", .{ now.unix_s, line, p.output() }) catch return;
        const path = keptPath(a, self.paths, e.name) catch return;
        store.replace(io, a, path, kept, .{}) catch |err| self.said(i, now.unix_s, "{s} (not kept: {s})", .{ line, @errorName(err) });
        _ = store.append(io, a, self.paths.log, std.fmt.allocPrint(a, "{d} suite {s}: {s}\n", .{ now.unix_s, e.name, line }) catch return) catch {};
    }

    fn said(self: *Suite, i: usize, at_s: i64, comptime fmt: []const u8, args: anytype) void {
        const l = &self.last[i];
        l.at_s = at_s;
        l.runs += 1;
        const line: []const u8 = std.fmt.bufPrint(&l.line_buf, fmt, args) catch &l.line_buf;
        l.line_len = line.len;
    }

    /// **WHAT A GET SHOWS**: each script, its period, how its last run
    /// ended and when, and the one going.
    pub fn writeStatus(self: *const Suite, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.entries.len == 0) return w.writeAll("no installed scripts\n");
        for (self.entries, 0..) |e, i| {
            const l = &self.last[i];
            const going = self.process != null and self.running == i;
            try w.print("suite {s} every {d} s: ", .{ e.name, e.period_s });
            if (going) try w.writeAll("running; ");
            if (l.runs == 0) try w.writeAll("not run yet\n") else try w.print("{d} runs, the last at {d}: {s}\n", .{ l.runs, l.at_s, l.line_buf[0..l.line_len] });
        }
    }

    /// Everything given back, for a test's end.
    pub fn reset(self: *Suite) void {
        if (self.process) |p| p.kill();
        self.* = .{};
    }
};

/// Where a name's last run is kept.
pub fn keptPath(a: std.mem.Allocator, paths: script_route.Paths, name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ paths.root, "shale", "suite", try std.fmt.allocPrint(a, "{s}.out", .{name}) });
}

/// **A NAME'S LAST RUN, AS KEPT**: its first line how it ended, then what it
/// printed; null when it has not run (or its file is gone).
pub fn readKept(io: Io, a: std.mem.Allocator, paths: script_route.Paths, name: []const u8) !?[]u8 {
    if (!validName(name)) return error.BadName;
    // absent-ok: a name not run yet has no file; any other failure is the caller's.
    return store.readOrNull(io, a, try keptPath(a, paths, name), .limited(kept_most + 1024));
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn endingLine(buf: []u8, stop: ?script.Stop, steps: u64) []const u8 {
    const s = stop orelse return std.fmt.bufPrint(buf, "finished ({d} steps)", .{steps}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "stopped at {d}:{d}: {s}{s}{s}: {s} ({d} steps)", .{ s.line, s.column, @tagName(s.class), if (s.budget != null) " " else "", if (s.budget) |b| @tagName(b) else "", s.message, steps }) catch buf[0..0];
}

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

const Rig = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    paths: script_route.Paths,

    fn init(self: *Rig) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        self.data = try std.fs.path.join(a, &.{ base, "data" });
        self.paths = try script_route.Paths.under(a, try std.fs.path.join(a, &.{ base, "auth" }));
        const io = self.threaded.io();
        try self.tmp.dir.createDirPath(io, "data/games");
        try self.tmp.dir.createDirPath(io, "auth/shale");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "data/games/a", .data = "aaa" });
    }

    fn deinit(self: *Rig) void {
        self.arena.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn kept(self: *Rig, name: []const u8) !?[]u8 {
        return readKept(self.threaded.io(), self.arena.allocator(), self.paths, name);
    }
};

const s_ns: i96 = std.time.ns_per_s;

test "suite: each script runs at the first turn, then every period from when it was due, its last run kept under the auth root" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const io = r.threaded.io();
    const given = [_]script.Arg{.{ .name = "dir", .value = "games" }};
    const entries = [_]Entry{
        .{ .name = "files", .source = "print(#ls(arg(\"dir\", \"\")), \"files\")", .args = &given, .period_s = 60 },
        .{ .name = "hello", .source = "print(\"hello at \" .. now())", .period_s = 3600 },
    };
    var suite: Suite = .{};
    defer suite.reset();
    try suite.install(&entries, testing.allocator, .{}, r.data, r.paths);
    try testing.expectEqual(@as(?[]u8, null), try r.kept("files"));
    // The first turn starts `files`; it runs to its end in slices, then
    // `hello` starts, and runs; then nothing until `files` is due again.
    var turns: usize = 0;
    var w: wake.Wake = .more;
    while (w == .more) : (turns += 1) {
        if (turns == 100) return error.NeverRests;
        w = suite.step(io, .{ .awake_ns = 5 * s_ns, .unix_s = 1000 });
    }
    try testing.expectEqual(wake.Wake{ .at = 65 * s_ns }, w);
    try testing.expectEqualStrings("1000 finished (", (try r.kept("files")).?[0..15]);
    try testing.expect(std.mem.endsWith(u8, (try r.kept("files")).?, " steps)\n1\tfiles\n"));
    try testing.expect(std.mem.endsWith(u8, (try r.kept("hello")).?, "hello at 1000\n"));
    // Not yet due: nothing runs.
    try testing.expectEqual(wake.Wake{ .at = 65 * s_ns }, suite.step(io, .{ .awake_ns = 30 * s_ns, .unix_s = 1025 }));
    // Due, and late: it runs, and the next is from when it was due.
    try r.tmp.dir.writeFile(io, .{ .sub_path = "data/games/b", .data = "b" });
    w = .more;
    while (w == .more) w = suite.step(io, .{ .awake_ns = 70 * s_ns, .unix_s = 1065 });
    try testing.expectEqual(wake.Wake{ .at = 125 * s_ns }, w);
    try testing.expect(std.mem.endsWith(u8, (try r.kept("files")).?, "2\tfiles\n"));
    var buf: [1024]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&buf);
    try suite.writeStatus(&sw);
    try testing.expect(std.mem.startsWith(u8, sw.buffered(), "suite files every 60 s: 2 runs, the last at 1065: finished ("));
    try testing.expect(std.mem.indexOf(u8, sw.buffered(), "suite hello every 3600 s: 1 runs, the last at 1000: finished (") != null);
    // And the log says each.
    const log = try store.readOrNull(io, r.arena.allocator(), r.paths.log, .limited(64 * 1024));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, log.?, " suite "));
}

test "suite: a run only reads, a stop is kept as how it ended, and a signed background run goes first" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const io = r.threaded.io();
    const entries = [_]Entry{
        .{ .name = "writer", .source = "print(\"before\") replace(\"games/x\", \"no\")", .period_s = 10 },
    };
    var suite: Suite = .{};
    defer suite.reset();
    try suite.install(&entries, testing.allocator, .{}, r.data, r.paths);
    // A signed background run is going: the suite waits.
    const signed = try script.process.Process.start(io, testing.allocator, r.data, "print(1)", .background, .{}, 0, 64);
    script_route.background.process = signed;
    try testing.expectEqual(wake.Wake.more, suite.step(io, .{ .awake_ns = 0, .unix_s = 7 }));
    try testing.expectEqual(@as(?*script.process.Process, null), suite.process);
    script_route.background.process = null;
    signed.kill();
    var w: wake.Wake = .more;
    while (w == .more) w = suite.step(io, .{ .awake_ns = 0, .unix_s = 7 });
    const kept = (try r.kept("writer")).?;
    try testing.expect(std.mem.startsWith(u8, kept, "7 stopped at 1:17: argument: `replace` changes the store, and a background run only reads"));
    try testing.expect(std.mem.endsWith(u8, kept, "\nbefore\n"));
    try testing.expectError(error.FileNotFound, r.tmp.dir.access(io, "data/games/x", .{}));
}

test "suite: what it refuses to install" {
    var suite: Suite = .{};
    const paths: script_route.Paths = undefined;
    try testing.expectError(error.BadName, suite.install(&.{.{ .name = "../x", .source = "", .period_s = 1 }}, testing.allocator, .{}, "", paths));
    try testing.expectError(error.NoPeriod, suite.install(&.{.{ .name = "x", .source = "", .period_s = 0 }}, testing.allocator, .{}, "", paths));
    const many = [_]Entry{.{ .name = "x", .source = "", .period_s = 1 }} ** (most_entries + 1);
    try testing.expectError(error.TooMany, suite.install(&many, testing.allocator, .{}, "", paths));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try suite.writeStatus(&w);
    try testing.expectEqualStrings("no installed scripts\n", w.buffered());
}
