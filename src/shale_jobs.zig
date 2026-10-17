//! **LONG JOBS** (metal-vmm QUEUE 233, chunk 4; the dogfood design's "Long
//! jobs"): a program that outlives the `shale` that started it.
//!
//! `launch` double-forks a reaper out of every task's process tree (so
//! stopping the `shale` that waits on a job never kills the job): the
//! first child makes its own session and forks the reaper, then exits, and
//! the reaper, re-parented to init, execs `shale --reap`. The reaper
//! (`reapMain`) starts the job in a session of its own, stdin `/dev/null`,
//! stdout and stderr its log, no death signal; writes its record; waits
//! for it; and writes how it ended. **The record, `<log>.job`**, is a few
//! `key=value` lines: `pid`, `pgid`, `start` (the leader's start time, raw
//! from `/proc/<pid>/stat`), `started`, `argv`, and at its end `exit` or
//! `signal`, and `ended`. Each write is whole: a new file renamed over it.

const std = @import("std");
const linux = std.os.linux;

pub const Record = struct {
    pid: i32 = 0,
    pgid: i32 = 0,
    start: []const u8 = "",
    started: i64 = 0,
    argv: []const u8 = "",
    exit: ?u8 = null,
    signal: ?u32 = null,
    ended: ?i64 = null,

    pub fn done(r: Record) bool {
        return r.exit != null or r.signal != null;
    }
};

/// A record's text, or null for one that is not a record.
pub fn parseRecord(text: []const u8) ?Record {
    var r: Record = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "pid")) r.pid = std.fmt.parseInt(i32, v, 10) catch return null;
        if (std.mem.eql(u8, k, "pgid")) r.pgid = std.fmt.parseInt(i32, v, 10) catch return null;
        if (std.mem.eql(u8, k, "start")) r.start = v;
        if (std.mem.eql(u8, k, "started")) r.started = std.fmt.parseInt(i64, v, 10) catch return null;
        if (std.mem.eql(u8, k, "argv")) r.argv = v;
        if (std.mem.eql(u8, k, "exit")) r.exit = std.fmt.parseInt(u8, v, 10) catch return null;
        if (std.mem.eql(u8, k, "signal")) r.signal = std.fmt.parseInt(u32, v, 10) catch return null;
        if (std.mem.eql(u8, k, "ended")) r.ended = std.fmt.parseInt(i64, v, 10) catch return null;
    }
    if (r.pid <= 0 or r.pgid <= 0) return null;
    return r;
}

fn formatRecord(buf: []u8, r: Record) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("pid={d}\npgid={d}\nstart={s}\nstarted={d}\nargv={s}\n", .{ r.pid, r.pgid, r.start, r.started, r.argv }) catch {};
    if (r.exit) |c| w.print("exit={d}\n", .{c}) catch {};
    if (r.signal) |s| w.print("signal={d}\n", .{s}) catch {};
    if (r.ended) |e| w.print("ended={d}\n", .{e}) catch {};
    return w.buffered();
}

/// **A PROCESS'S START TIME**, raw: `/proc/<pid>/stat`'s 22nd field, read
/// after the last `)` (a program's name may hold one). Null when there is
/// no such process.
pub fn startOf(buf: []u8, pid: i32) ?[]const u8 {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const text = buf[0..n];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    // Field 3 (the state) is the first after `)`; the start time is 22.
    var i: usize = 3;
    while (it.next()) |f| : (i += 1) if (i == 22) return f;
    return null;
}

fn signalGroup(pgid: i32, sig: u32) bool {
    const rc = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, -pgid))), sig);
    return linux.errno(rc) == .SUCCESS;
}

/// **WHETHER A JOB LIVES**: its group has a process, and its leader, if
/// still there, is the one the record names (its start time). A leader
/// that exited, its group living on, is alive.
pub fn alive(r: Record) bool {
    var buf: [1024]u8 = undefined;
    if (startOf(&buf, r.pid)) |s| if (!std.mem.eql(u8, s, r.start)) return false;
    return signalGroup(r.pgid, 0);
}

fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

/// **A JOB STOPPED**: TERM to its group, `grace_ms`, then KILL; whether it
/// was alive. The start-time check narrows a reused id's race; it does not
/// close it.
pub fn stop(r: Record, grace_ms: u64) bool {
    if (!alive(r)) return false;
    _ = signalGroup(r.pgid, @intFromEnum(linux.SIG.TERM));
    var waited: u64 = 0;
    while (waited < grace_ms) : (waited += 50) {
        if (!signalGroup(r.pgid, 0)) return true;
        sleepMs(50);
    }
    _ = signalGroup(r.pgid, @intFromEnum(linux.SIG.KILL));
    // The reaper reaps the leader; wait a little for the group to go.
    waited = 0;
    while (waited < 2000 and signalGroup(r.pgid, 0)) : (waited += 20) sleepMs(20);
    return true;
}

/// argv[0] as `execve` would find it: a path (against `cwd` when
/// relative), or along PATH. Null when nothing runnable is there.
pub fn find(a: std.mem.Allocator, argv0: []const u8, env: []const []const u8, cwd: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        const p = if (std.fs.path.isAbsolute(argv0)) argv0 else try std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, argv0 });
        return if (runnable(a, p)) p else null;
    }
    var path: []const u8 = "/usr/local/bin:/usr/bin:/bin";
    for (env) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
        path = e["PATH=".len..];
    };
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, argv0 });
        if (runnable(a, p)) return p;
    }
    return null;
}

fn runnable(a: std.mem.Allocator, p: []const u8) bool {
    const z = a.dupeZ(u8, p) catch return false;
    return linux.errno(linux.access(z, 1)) == .SUCCESS;
}

fn zList(a: std.mem.Allocator, items: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const out = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, out) |s, *o| o.* = (try a.dupeZ(u8, s)).ptr;
    return out.ptr;
}

pub const LaunchError = error{ OutOfMemory, Spawn, NoRecord };

/// **A JOB LAUNCHED**: `reaper --reap <record> <log> <cwd> <program> --
/// argv...` double-forked out of this process's tree, with `env`; then
/// its record, once the reaper has written it (at most 5 seconds).
pub fn launch(a: std.mem.Allocator, io: std.Io, reaper: []const u8, record: []const u8, log: []const u8, cwd: []const u8, program: []const u8, argv: []const []const u8, env: []const []const u8) LaunchError!Record {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ reaper, "--reap", record, log, cwd, program, "--" });
    try args.appendSlice(a, argv);
    const zargv = try zList(a, args.items);
    const zenv = try zList(a, env);
    const zexe = try a.dupeZ(u8, reaper);
    // An old record would be read as the new one's.
    std.Io.Dir.cwd().deleteFile(io, record) catch {};
    const first = linux.fork();
    if (linux.errno(first) != .SUCCESS) return error.Spawn;
    if (first == 0) {
        // The first child: a session of its own, the reaper, and gone.
        _ = linux.setsid();
        const second = linux.fork();
        if (second == 0) {
            _ = linux.close_range(3, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false });
            const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
            _ = linux.dup2(devnull, 0);
            _ = linux.dup2(devnull, 1);
            _ = linux.dup2(devnull, 2);
            var none = linux.sigemptyset();
            _ = linux.sigprocmask(linux.SIG.SETMASK, &none, null);
            _ = linux.execve(zexe, zargv, zenv);
            linux.exit_group(127);
        }
        linux.exit_group(0);
    }
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(first), &status, 0);
        if (linux.errno(rc) != .INTR) break;
    }
    var waited: u64 = 0;
    while (waited < 5000) : (waited += 10) {
        if (std.Io.Dir.cwd().readFileAlloc(io, record, a, .limited(64 * 1024))) |text| {
            if (parseRecord(text)) |r| return r;
        } else |_| {}
        sleepMs(10);
    }
    return error.NoRecord;
}

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn writeRecord(record: [*:0]const u8, tmp: [*:0]const u8, r: Record) void {
    var buf: [8192]u8 = undefined;
    const text = formatRecord(&buf, r);
    const fd = linux.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), text.ptr, text.len);
    _ = linux.close(@intCast(fd));
    _ = linux.rename(tmp, record);
}

/// **THE REAPER** (`shale --reap <record> <log> <cwd> <program> -- argv...`,
/// its own environment the job's): the job started, its record written,
/// its end waited for and written. Its exit says only whether it could.
pub fn reapMain(a: std.mem.Allocator, args: []const []const u8, env: []const []const u8) u8 {
    if (args.len < 6 or !std.mem.eql(u8, args[4], "--")) return 2;
    const record = a.dupeZ(u8, args[0]) catch return 2;
    const tmp = std.fmt.allocPrintSentinel(a, "{s}.tmp", .{args[0]}, 0) catch return 2;
    const log = a.dupeZ(u8, args[1]) catch return 2;
    const cwd = a.dupeZ(u8, args[2]) catch return 2;
    const program = a.dupeZ(u8, args[3]) catch return 2;
    const argv = args[5..];
    const zargv = zList(a, argv) catch return 2;
    const zenv = zList(a, env) catch return 2;
    const shown = std.mem.join(a, " ", argv) catch return 2;
    const log_fd = linux.open(log, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(log_fd) != .SUCCESS) return 2;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return 2;
    if (pid == 0) {
        // The job: a session (and so a group) of its own, its log for both
        // streams, `/dev/null` for stdin.
        _ = linux.setsid();
        const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0));
        _ = linux.dup2(devnull, 0);
        _ = linux.dup2(@intCast(log_fd), 1);
        _ = linux.dup2(@intCast(log_fd), 2);
        if (linux.errno(linux.chdir(cwd)) != .SUCCESS) linux.exit_group(126);
        _ = linux.execve(program, zargv, zenv);
        linux.exit_group(127);
    }
    _ = linux.close(@intCast(log_fd));
    var r: Record = .{ .pid = @intCast(pid), .pgid = @intCast(pid), .started = nowSeconds(), .argv = shown };
    var stat_buf: [1024]u8 = undefined;
    // The child's start time, once it is the session leader (a moment).
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (startOf(&stat_buf, r.pid)) |s| {
            r.start = s;
            break;
        }
        sleepMs(1);
    }
    writeRecord(record, tmp, r);
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(pid), &status, 0);
        if (linux.errno(rc) != .INTR) break;
    }
    if (linux.W.IFEXITED(status)) r.exit = linux.W.EXITSTATUS(status) else r.signal = @intFromEnum(linux.W.TERMSIG(status));
    r.ended = nowSeconds();
    writeRecord(record, tmp, r);
    return 0;
}

test "jobs: a record reads back as it was written, and a broken one is none" {
    var buf: [512]u8 = undefined;
    const text = formatRecord(&buf, .{ .pid = 42, .pgid = 42, .start = "123", .started = 9, .argv = "zig build", .exit = 3, .ended = 11 });
    const r = parseRecord(text).?;
    try std.testing.expectEqual(@as(i32, 42), r.pid);
    try std.testing.expectEqualStrings("123", r.start);
    try std.testing.expectEqual(@as(?u8, 3), r.exit);
    try std.testing.expect(r.done());
    try std.testing.expect(parseRecord("pid=x\n") == null);
    try std.testing.expect(parseRecord("") == null);
}

test "jobs: a process's start time is its stat's 22nd field; none for a process not there" {
    var buf: [1024]u8 = undefined;
    try std.testing.expect(startOf(&buf, linux.getpid()) != null);
    try std.testing.expect(startOf(&buf, 0x7ffffff0) == null);
}
