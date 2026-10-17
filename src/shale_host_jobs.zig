//! **THE HOST'S JOBS** (metal-vmm QUEUE 233, chunk 4; the dogfood design's
//! "Long jobs"): `host("job_start", argv, opts)` and the calls that find a
//! job again, by the job `job_start` gave or by its record's Shale path
//! (`"runs:x/gates.log.job"`), so a later `shale` carries on where an
//! earlier one started. The processes are `shale_jobs.zig`'s.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const interp = script.interp;
const ast = script.ast;
const Value = script.value.Value;
const Run = interp.Run;
const Error = interp.Error;
const hl = @import("shale_host_linux.zig");
const jobs = @import("shale_jobs.zig");
const Host = hl.Host;

pub fn call(h: *Host, run: *Run, pos: ast.Pos, name: []const u8, args: []const Value) Error!Value {
    if (std.mem.eql(u8, name, "job_start")) return start(h, run, pos, args);
    if (std.mem.eql(u8, name, "job_alive")) {
        if (args.len != 1) return run.fail(pos, .argument, "`job_alive` takes a job, given {d} arguments", .{args.len});
        const j = try find(h, run, pos, args[0], name);
        try run.charge(pos, 1);
        return .{ .boolean = jobs.alive(j.record) };
    }
    if (std.mem.eql(u8, name, "job_stop")) {
        if (args.len != 1) return run.fail(pos, .argument, "`job_stop` takes a job, given {d} arguments", .{args.len});
        if (run.dry_run) return run.budgetStop(pos, .runs);
        const j = try find(h, run, pos, args[0], name);
        try run.charge(pos, 1);
        const was = jobs.stop(j.record, 2000);
        if (was) h.record("job {s} stopped", .{j.shown});
        return .{ .boolean = was };
    }
    if (std.mem.eql(u8, name, "job_wait")) return wait(h, run, pos, args);
    return run.fail(pos, .host, "`{s}`: not on this host", .{name});
}

/// **A JOB STARTED**: `argv` under the reaper, `log` its output (required),
/// `cwd`, `env` added to the inherited environment, `want` as `run`'s. No
/// `secrets`: a detached job's log has nobody to scrub it. Counted against
/// the run's cap on programs; never in a dry run.
fn start(h: *Host, run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 2) return run.fail(pos, .argument, "`job_start` takes argv and its options, `job_start({{\"zig\", \"build\"}}, {{log = \"runs:build.log\"}})`, given {d} arguments", .{args.len});
    const a = run.alloc;
    const argv_t = switch (args[0]) {
        .table => |t| if (t.kind == .map) return run.fail(pos, .type, "`job_start`'s argv is a list of strings, not a map", .{}) else t,
        else => return run.fail(pos, .type, "`job_start`'s argv is a list of strings, not {s}", .{args[0].typeName()}),
    };
    if (argv_t.kind == .empty or argv_t.list.items.len == 0) return run.fail(pos, .argument, "`job_start` of an empty argv: name the program", .{});
    const argv = a.alloc([]const u8, argv_t.list.items.len) catch return run.oom(pos);
    for (argv_t.list.items, argv, 0..) |v, *s, i| s.* = switch (v) {
        .string => |x| x,
        else => return run.fail(pos, .type, "`job_start`'s argv[{d}] is {s}, not a string", .{ i + 1, v.typeName() }),
    };
    const m = switch (args[1]) {
        .table => |t| if (t.kind == .list) return run.fail(pos, .type, "`job_start`'s options are a map, not a list", .{}) else t,
        else => return run.fail(pos, .type, "`job_start`'s options are a map, not {s}", .{args[1].typeName()}),
    };
    var log: ?Value = null;
    var cwd_v: ?Value = null;
    var env_t: ?*script.value.Table = null;
    var want: ?[]const u8 = null;
    for (m.map.keys(), m.map.values()) |k, x| {
        if (std.mem.eql(u8, k, "log")) log = x else if (std.mem.eql(u8, k, "cwd")) cwd_v = x else if (std.mem.eql(u8, k, "env")) env_t = try hl.mapOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "want")) want = try hl.strOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "secrets"))
            return run.fail(pos, .argument, "`job_start`: no `secrets` on a job: a detached job's log has nobody to scrub it", .{})
        else
            return run.fail(pos, .argument, "`job_start` takes log, cwd, env and want, not `{s}`", .{k});
    }
    const log_v = log orelse return run.fail(pos, .argument, "`job_start` needs a `log`: a job's output goes there, and its record beside it", .{});
    const log_shown = try hl.strOpt(run, pos, "log", log_v);
    try run.charge(pos, argv.len);

    if (run.dry_run) return run.budgetStop(pos, .runs);
    if (run.host_runs >= hl.runs_most) {
        run.stop = .{ .line = pos.line, .column = pos.column, .class = .budget, .budget = .runs, .function = run.function, .trail = run.calls.items, .message = std.fmt.allocPrint(a, "{d} programs a run, the most: run the rest in another", .{hl.runs_most}) catch "too many programs in one run" };
        return error.Stop;
    }
    const cwd = if (cwd_v) |c| try hl.osPath(h, run, pos, c, true) else try hl.rootOf(h, run, pos);
    try hl.refuse(h, run, pos, "job_start", argv[0], cwd, want);
    const reaper = h.reaper orelse return run.fail(pos, .host, "`job_start`: this host has no reaper to start a job under", .{});

    var env: std.ArrayList([]const u8) = .empty;
    const extra = if (env_t) |t| t.map.keys() else &.{};
    for (h.env) |e| {
        const k = e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
        const over = for (extra) |x| {
            if (std.mem.eql(u8, x, k)) break true;
        } else false;
        if (!over) env.append(a, e) catch return run.oom(pos);
    }
    if (env_t) |t| for (t.map.keys(), t.map.values()) |k, x| {
        env.append(a, std.fmt.allocPrint(a, "{s}={s}", .{ k, try hl.strOpt(run, pos, "env", x) }) catch return run.oom(pos)) catch return run.oom(pos);
    };
    const program = (jobs.find(a, argv[0], env.items, cwd) catch return run.oom(pos)) orelse
        return run.fail(pos, .host, "`job_start`: `{s}` is not found{s}", .{ argv[0], if (std.mem.indexOfScalar(u8, argv[0], '/') == null) " along PATH" else "" });
    const log_os = try hl.osPath(h, run, pos, log_v, false);
    const record_os = std.fmt.allocPrint(a, "{s}.job", .{log_os}) catch return run.oom(pos);
    // A job still running on this log: its record is its one handle, and
    // the old job's end would be written over the new one's record.
    if (std.Io.Dir.cwd().readFileAlloc(run.io, record_os, a, .limited(64 * 1024))) |text| {
        try chargeRead(run, pos, text.len);
        if (jobs.parseRecord(text)) |old| if (jobs.alive(old) or jobs.reaperAlive(old))
            return run.fail(pos, .host, "`job_start`: a job still runs on {s} (pid {d}, its record {s}.job): `job_stop` or `job_wait` it, or give another log", .{ log_shown, old.pid, log_shown });
    } else |_| {}
    run.host_runs += 1;
    const r = jobs.launch(a, run.io, reaper, record_os, log_os, cwd, program, argv, env.items) catch |e| switch (e) {
        error.OutOfMemory => return run.oom(pos),
        error.Spawn => return run.fail(pos, .host, "`job_start`: the reaper could not be forked", .{}),
        error.NoRecord => return run.fail(pos, .host, "`job_start`: the reaper ended without writing a record at {s}.job", .{log_shown}),
    };
    const joined = std.mem.join(a, " ", argv) catch return run.oom(pos);
    h.record("job {s}{s}{s} started (pid {d}), log {s}", .{ joined, if (want != null) " (want: " else "", if (want) |w| std.fmt.allocPrint(a, "{s})", .{w}) catch w else "", r.pid, log_shown });

    const t = try run.newTable(pos);
    t.kind = .map;
    t.map.put(a, "log", .{ .string = log_shown }) catch return run.oom(pos);
    t.map.put(a, "record", .{ .string = std.fmt.allocPrint(a, "{s}.job", .{log_shown}) catch return run.oom(pos) }) catch return run.oom(pos);
    t.map.put(a, "pid", .{ .int = r.pid }) catch return run.oom(pos);
    t.map.put(a, "pgid", .{ .int = r.pgid }) catch return run.oom(pos);
    return .{ .table = t };
}

const Found = struct { record: jobs.Record, shown: []const u8, log: Value };

/// A job by the map `job_start` gave or its record's Shale path; its
/// record read now.
fn find(h: *Host, run: *Run, pos: ast.Pos, v: Value, name: []const u8) Error!Found {
    const shown: []const u8 = switch (v) {
        .string => |s| s,
        .table => |t| blk: {
            if (t.kind == .map) if (t.map.get("record")) |r| if (r == .string) break :blk r.string;
            return run.fail(pos, .type, "`{s}` takes a job (what `job_start` gave) or its record's path, not that table", .{name});
        },
        else => return run.fail(pos, .type, "`{s}` takes a job or its record's path, not {s}", .{ name, v.typeName() }),
    };
    if (!std.mem.endsWith(u8, shown, ".job")) return run.fail(pos, .argument, "`{s}`: {s} is not a job's record (`<log>.job`)", .{ name, shown });
    const os = try hl.osPath(h, run, pos, .{ .string = shown }, false);
    const text = std.Io.Dir.cwd().readFileAlloc(run.io, os, run.alloc, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return run.fail(pos, .store, "`{s}`: no job's record at {s}", .{ name, shown }),
        else => return run.fail(pos, .store, "`{s}`: its record {s} cannot be read: {s}", .{ name, shown, @errorName(e) }),
    };
    try chargeRead(run, pos, text.len);
    const r = jobs.parseRecord(text) orelse return run.fail(pos, .store, "`{s}`: {s} is not a job's record", .{ name, shown });
    return .{ .record = r, .shown = shown, .log = .{ .string = shown[0 .. shown.len - ".job".len] } };
}

/// **WAITING ON A JOB**: until it ends (`exited`, and its `code` if it
/// exited or the `signal` that ended it), a `file` (the log unless named) holds `contains` (`found`), or
/// `timeout_ms` passes (`timeout`). It looks at once, then every second. A
/// job gone while its reaper lives is still ending: the reaper writes its
/// end after it reaps it. Gone with its reaper and no end written, it is
/// `lost`.
fn wait(h: *Host, run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 2) return run.fail(pos, .argument, "`job_wait` takes a job and its options, `{{timeout_ms = ...}}`, given {d} arguments", .{args.len});
    const m = switch (args[1]) {
        .table => |t| if (t.kind == .list) return run.fail(pos, .type, "`job_wait`'s options are a map, not a list", .{}) else t,
        else => return run.fail(pos, .type, "`job_wait`'s options are a map, not {s}", .{args[1].typeName()}),
    };
    var timeout_ms: ?u64 = null;
    var file: ?Value = null;
    var contains: ?[]const u8 = null;
    for (m.map.keys(), m.map.values()) |k, x| {
        if (std.mem.eql(u8, k, "timeout_ms")) timeout_ms = try hl.intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "file")) file = x else if (std.mem.eql(u8, k, "contains")) contains = try hl.strOpt(run, pos, k, x) else return run.fail(pos, .argument, "`job_wait` takes timeout_ms, file and contains, not `{s}`", .{k});
    }
    const limit = timeout_ms orelse return run.fail(pos, .argument, "`job_wait` needs `timeout_ms`, under the Bash call's own timeout", .{});
    if (file != null and contains == null) return run.fail(pos, .argument, "`job_wait`: `file` without `contains`: what to wait for in it", .{});
    if (contains) |c| if (c.len == 0) return run.fail(pos, .argument, "`job_wait`'s `contains` is \"\": every file holds it", .{});
    const a = run.alloc;
    const began = monoMs();
    while (true) {
        const j = try find(h, run, pos, args[0], "job_wait");
        if (contains) |c| {
            const os = try hl.osPath(h, run, pos, file orelse j.log, false);
            if (std.Io.Dir.cwd().readFileAlloc(run.io, os, a, .limited(64 * 1024 * 1024))) |text| {
                try chargeRead(run, pos, text.len);
                if (std.mem.indexOf(u8, text, c) != null) return result(run, pos, "found", null, null);
            } else |_| {}
        }
        if (j.record.done()) return result(run, pos, "exited", j.record.exit, j.record.signal);
        const gone = !jobs.alive(j.record);
        if (gone and !jobs.reaperAlive(j.record)) {
            // The reaper's last write, if it made one, is there now.
            const again = try find(h, run, pos, args[0], "job_wait");
            if (again.record.done()) return result(run, pos, "exited", again.record.exit, again.record.signal);
            return result(run, pos, "lost", null, null);
        }
        const spent = monoMs() - began;
        if (spent >= limit) return result(run, pos, "timeout", null, null);
        sleepMs(@min(if (gone) @as(u64, 10) else 1000, limit - spent));
    }
}

fn result(run: *Run, pos: ast.Pos, ended: []const u8, code: ?u8, signal: ?u32) Error!Value {
    const t = try run.newTable(pos);
    t.kind = .map;
    t.map.put(run.alloc, "ended", .{ .string = ended }) catch return run.oom(pos);
    if (code) |c| t.map.put(run.alloc, "code", .{ .int = c }) catch return run.oom(pos);
    if (signal) |n| t.map.put(run.alloc, "signal", .{ .int = n }) catch return run.oom(pos);
    return .{ .table = t };
}

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn sleepMs(ms: u64) void {
    const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// A file the host read for the script: its bytes as a read's.
fn chargeRead(run: *Run, pos: ast.Pos, n: usize) Error!void {
    try script.builtins.chargeBytes(run, pos, n);
    run.read_bytes += n;
}
