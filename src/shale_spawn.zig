//! **ONE PROGRAM, RUN AND ENDED** (metal-vmm QUEUE 233, chunk 1; the
//! dogfood design's "Running a program", "How it is built"): what `run`
//! does under its options, the raw spawn and one poll loop.
//!
//! zig 0.16's `process.spawn` has no hook before exec, and its `kill`
//! signals the leader alone and then waits without bound, so this forks
//! itself: in the child a death signal (and a check that the parent is
//! still the one that forked it), a process group of its own, signals
//! unblocked, stdin from the bytes given or /dev/null, stdout and stderr
//! one pipe, `chdir`, and `execve` along PATH. An exec that fails says why
//! through a close-on-exec pipe, so "not found" is an answer, not a hang.
//!
//! The parent's loop polls the output, the stdin it is still writing, a
//! pidfd for the exit and a signalfd for TERM and HUP. **On the deadline,
//! or a TERM or HUP to `shale` itself: TERM to the whole group, a grace,
//! then KILL.** After the leader exits, the output is read for at most
//! `drain_ms` more (a grandchild holding the pipe open never holds `run`).

const std = @import("std");
const linux = std.os.linux;

pub const Spec = struct {
    /// argv[0] is found along PATH unless it has a `/` (then it is a path,
    /// a relative one against `cwd`).
    argv: []const []const u8,
    /// The OS folder it starts in; null for `shale`'s own.
    cwd: ?[]const u8 = null,
    /// The whole environment, each `K=V`.
    env: []const []const u8,
    /// Its stdin's bytes, or null for /dev/null.
    stdin: ?[]const u8 = null,
    timeout_ms: u64,
    /// Between TERM and KILL.
    grace_ms: u64 = 2000,
    /// How long the output is read after the program ends.
    drain_ms: u64 = 200,
};

pub const Ended = enum {
    /// It exited: `code`.
    exit,
    /// Its time ran out and it was ended.
    timeout,
    /// A signal ended it that `run` did not send: `signal`.
    signal,
    /// `shale` itself was told to stop (TERM or HUP) and ended it.
    interrupted,
};

pub const Outcome = struct {
    ended: Ended,
    code: ?u8 = null,
    signal: ?u32 = null,
    ms: u64,
};

pub const Error = error{
    OutOfMemory,
    /// No such program, along PATH or at its path.
    NotFound,
    /// Found, but not to be run (no permission, not a program).
    NotRunnable,
    /// `cwd` is not a folder that can be entered.
    NoCwd,
    /// The kernel refused a pipe, a fork or a pidfd.
    Spawn,
};

/// What `sink.write` may fail with: the sink's own `Error`.
fn SinkError(comptime T: type) type {
    return @typeInfo(T).pointer.child.Error;
}

fn monoMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn zString(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    return (try a.dupeZ(u8, s)).ptr;
}

fn zList(a: std.mem.Allocator, items: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const out = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, out) |s, *o| o.* = try zString(a, s);
    return out.ptr;
}

/// The candidates `execve` tries, in order: argv[0] itself when it has a
/// `/`, else each folder of PATH (the environment's, or the usual one).
fn candidates(a: std.mem.Allocator, argv0: []const u8, env: []const []const u8) ![]const [*:0]const u8 {
    var out: std.ArrayList([*:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        try out.append(a, try zString(a, argv0));
        return out.items;
    }
    var path: []const u8 = "/usr/local/bin:/usr/bin:/bin";
    for (env) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
        path = e["PATH=".len..];
    };
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = if (dir.len == 0) try std.fmt.allocPrint(a, "{s}", .{argv0}) else try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, argv0 });
        try out.append(a, try zString(a, full));
    }
    return out.items;
}

fn closeFd(fd: *i32) void {
    if (fd.* >= 0) _ = linux.close(fd.*);
    fd.* = -1;
}

fn setNonblocking(fd: i32) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, flags | (1 << 11));
}

/// **THE CHILD, BETWEEN FORK AND EXEC**: raw system calls only, nothing
/// allocated; any failure is its errno on `err_w`, then exit 127.
fn child(parent: linux.pid_t, spec_cwd: ?[*:0]const u8, stdin_r: i32, out_w: i32, err_w: i32, paths: []const [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
    if (linux.getppid() != parent) linux.exit_group(127);
    _ = linux.setpgid(0, 0);
    var none = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &none, null);
    const in_fd: i32 = if (stdin_r >= 0) stdin_r else @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0));
    _ = linux.dup2(in_fd, 0);
    _ = linux.dup2(out_w, 1);
    _ = linux.dup2(out_w, 2);
    if (spec_cwd) |c| {
        const rc = linux.chdir(c);
        if (linux.errno(rc) != .SUCCESS) fail(err_w, 1000 + @as(u32, @intFromEnum(linux.errno(rc))));
    }
    var last: linux.E = .NOENT;
    for (paths) |p| {
        const rc = linux.execve(p, argv, envp);
        const e = linux.errno(rc);
        switch (e) {
            .NOENT, .NOTDIR => {},
            else => last = e,
        }
    }
    fail(err_w, @intFromEnum(last));
}

fn fail(err_w: i32, code: u32) noreturn {
    const bytes = std.mem.asBytes(&code);
    _ = linux.write(err_w, bytes.ptr, bytes.len);
    linux.exit_group(127);
}

/// **A PROGRAM, RUN TO ITS END OR ITS DEADLINE**, its output (stdout and
/// stderr, one stream) given to `sink.write(bytes)` as it comes.
pub fn run(alloc: std.mem.Allocator, spec: Spec, sink: anytype) (Error || SinkError(@TypeOf(sink)))!Outcome {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try zList(a, spec.argv);
    const envp = try zList(a, spec.env);
    const paths = try candidates(a, spec.argv[0], spec.env);
    const cwd: ?[*:0]const u8 = if (spec.cwd) |c| try zString(a, c) else null;

    var out_pipe: [2]i32 = .{ -1, -1 };
    var err_pipe: [2]i32 = .{ -1, -1 };
    var in_pipe: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&out_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Spawn;
    defer closeFd(&out_pipe[0]);
    defer closeFd(&out_pipe[1]);
    if (linux.errno(linux.pipe2(&err_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Spawn;
    defer closeFd(&err_pipe[0]);
    defer closeFd(&err_pipe[1]);
    if (spec.stdin != null and linux.errno(linux.pipe2(&in_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Spawn;
    defer closeFd(&in_pipe[0]);
    defer closeFd(&in_pipe[1]);

    // TERM and HUP to `shale` come to the loop, not the default action,
    // while a program runs; the child unblocks them before exec.
    var stop_set = linux.sigemptyset();
    linux.sigaddset(&stop_set, .TERM);
    linux.sigaddset(&stop_set, .HUP);
    var old_mask: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &stop_set, &old_mask);
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
    const sig_rc = linux.signalfd(-1, &stop_set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    if (linux.errno(sig_rc) != .SUCCESS) return error.Spawn;
    var sig_fd: i32 = @intCast(sig_rc);
    defer closeFd(&sig_fd);

    const start = monoMs();
    const parent = linux.getpid();
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.Spawn;
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) child(parent, cwd, in_pipe[0], out_pipe[1], err_pipe[1], paths, argv, envp);

    // The parent: the child's ends closed, then did the exec happen?
    closeFd(&out_pipe[1]);
    closeFd(&err_pipe[1]);
    closeFd(&in_pipe[0]);
    var why: u32 = 0;
    const n = linux.read(err_pipe[0], std.mem.asBytes(&why).ptr, @sizeOf(u32));
    if (linux.errno(n) == .SUCCESS and n == @sizeOf(u32)) {
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        if (why >= 1000) return error.NoCwd;
        return switch (@as(linux.E, @enumFromInt(why))) {
            .NOENT => error.NotFound,
            else => error.NotRunnable,
        };
    }

    const pidfd_rc = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd_rc) != .SUCCESS) {
        _ = linux.kill(-pid, .KILL);
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        return error.Spawn;
    }
    var pid_fd: i32 = @intCast(pidfd_rc);
    defer closeFd(&pid_fd);
    setNonblocking(out_pipe[0]);
    if (in_pipe[1] >= 0) setNonblocking(in_pipe[1]);

    var stdin_left: []const u8 = spec.stdin orelse "";
    if (spec.stdin != null and stdin_left.len == 0) closeFd(&in_pipe[1]);
    var buf: [64 * 1024]u8 = undefined;
    var exited = false;
    var status: u32 = 0;
    var termed_at: ?u64 = null;
    var killed = false;
    var why_ended: ?Ended = null;
    var drain_until: u64 = 0;
    const deadline = start + spec.timeout_ms;
    while (true) {
        const now = monoMs();
        if (exited and (out_pipe[0] < 0 or now >= drain_until)) break;
        if (!exited and termed_at == null and now >= deadline) {
            why_ended = .timeout;
            _ = linux.kill(-pid, .TERM);
            termed_at = now;
        }
        if (!exited and !killed and termed_at != null and now >= termed_at.? + spec.grace_ms) {
            _ = linux.kill(-pid, .KILL);
            killed = true;
        }
        // The nearest of the deadline, the grace's end and the drain's.
        var wait_ms: u64 = 1000;
        if (!exited and termed_at == null) wait_ms = @min(wait_ms, deadline -| now);
        if (!exited and termed_at != null and !killed) wait_ms = @min(wait_ms, (termed_at.? + spec.grace_ms) -| now);
        if (exited) wait_ms = @min(wait_ms, drain_until -| now);

        var fds: [4]linux.pollfd = undefined;
        var nfds: usize = 0;
        var out_at: ?usize = null;
        var in_at: ?usize = null;
        var pid_at: ?usize = null;
        if (out_pipe[0] >= 0) {
            fds[nfds] = .{ .fd = out_pipe[0], .events = linux.POLL.IN, .revents = 0 };
            out_at = nfds;
            nfds += 1;
        }
        if (in_pipe[1] >= 0) {
            fds[nfds] = .{ .fd = in_pipe[1], .events = linux.POLL.OUT, .revents = 0 };
            in_at = nfds;
            nfds += 1;
        }
        if (!exited) {
            fds[nfds] = .{ .fd = pid_fd, .events = linux.POLL.IN, .revents = 0 };
            pid_at = nfds;
            nfds += 1;
        }
        fds[nfds] = .{ .fd = sig_fd, .events = linux.POLL.IN, .revents = 0 };
        const sig_at = nfds;
        nfds += 1;
        const prc = linux.poll(&fds, @intCast(nfds), @intCast(@min(wait_ms, 60_000)));
        if (linux.errno(prc) == .INTR) continue;

        if (out_at) |i| if (fds[i].revents != 0) try readAvailable(&out_pipe[0], &buf, sink);
        if (in_at) |i| if (fds[i].revents != 0) {
            const w = linux.write(in_pipe[1], stdin_left.ptr, @min(stdin_left.len, 64 * 1024));
            const e = linux.errno(w);
            if (e == .SUCCESS) stdin_left = stdin_left[w..] else if (e != .AGAIN and e != .INTR) stdin_left = "";
            if (stdin_left.len == 0) closeFd(&in_pipe[1]);
        };
        if (pid_at) |i| if (fds[i].revents != 0) {
            if (linux.wait4(pid, &status, linux.W.NOHANG, null) == pid) {
                exited = true;
                // All it wrote is in the pipe now, though this poll may
                // have seen the pipe before it: read it before any drain's
                // end can come, which bounds only what outlives it.
                if (out_pipe[0] >= 0) try readAvailable(&out_pipe[0], &buf, sink);
                drain_until = monoMs() + spec.drain_ms;
                closeFd(&in_pipe[1]);
            }
        };
        if (fds[sig_at].revents != 0) {
            var info: linux.signalfd_siginfo = undefined;
            _ = linux.read(sig_fd, std.mem.asBytes(&info).ptr, @sizeOf(linux.signalfd_siginfo));
            if (!exited and termed_at == null) {
                why_ended = .interrupted;
                _ = linux.kill(-pid, .TERM);
                termed_at = monoMs();
            }
        }
    }
    const ms = monoMs() - start;
    if (why_ended) |w| return .{ .ended = w, .ms = ms, .signal = if (linux.W.IFSIGNALED(status)) @intFromEnum(linux.W.TERMSIG(status)) else null, .code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null };
    if (linux.W.IFEXITED(status)) return .{ .ended = .exit, .code = linux.W.EXITSTATUS(status), .ms = ms };
    return .{ .ended = .signal, .signal = @intFromEnum(linux.W.TERMSIG(status)), .ms = ms };
}

/// What the pipe holds now, to the sink: until it would block, or at its
/// end, closed.
fn readAvailable(fd: *i32, buf: []u8, sink: anytype) !void {
    while (true) {
        const r = linux.read(fd.*, buf.ptr, buf.len);
        const e = linux.errno(r);
        if (e == .AGAIN) return;
        if (e == .INTR) continue;
        if (e != .SUCCESS or r == 0) {
            closeFd(fd);
            return;
        }
        try sink.write(buf[0..r]);
    }
}

// ── tests: the fixture program the build makes, never /bin/sh ────────

const testing = std.testing;
const fixture = @import("shale_test_options").fixture;

const Collect = struct {
    out: std.ArrayList(u8) = .empty,
    pub const Error = error{OutOfMemory};
    fn write(c: *Collect, bytes: []const u8) Collect.Error!void {
        try c.out.appendSlice(testing.allocator, bytes);
    }
};

/// The fixture's absolute path: a relative argv[0] is taken against `cwd`.
fn fixturePath(buf: []u8) []const u8 {
    if (std.fs.path.isAbsolute(fixture)) return fixture;
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const n = linux.getcwd(&cwd, cwd.len);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.sliceTo(cwd[0..n], 0), fixture }) catch unreachable;
}

fn spawn(argv: []const []const u8, spec: Spec, c: *Collect) !Outcome {
    var s = spec;
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(testing.allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try full.append(testing.allocator, fixturePath(&buf));
    try full.appendSlice(testing.allocator, argv);
    s.argv = full.items;
    return run(testing.allocator, s, c);
}

test "spawn: the fixture's output, its exit code, stdin given, a working folder, the environment as given" {
    var c: Collect = .{};
    defer c.out.deinit(testing.allocator);
    const env = [_][]const u8{ "SHALE_FIXTURE=present", "PATH=/usr/bin:/bin" };
    var o = try spawn(&.{ "lines", "3" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqual(Ended.exit, o.ended);
    try testing.expectEqual(@as(?u8, 0), o.code);
    try testing.expectEqualStrings("line 1\nline 2\nline 3\n", c.out.items);
    c.out.clearRetainingCapacity();
    o = try spawn(&.{ "exit", "7" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqual(@as(?u8, 7), o.code);
    o = try spawn(&.{"cat"}, .{ .argv = &.{}, .env = &env, .stdin = "fed\nin\n", .timeout_ms = 10_000 }, &c);
    try testing.expectEqualStrings("fed\nin\n", c.out.items);
    c.out.clearRetainingCapacity();
    // stdin unset is /dev/null: `cat` ends at once.
    o = try spawn(&.{"cat"}, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqual(@as(?u8, 0), o.code);
    try testing.expectEqualStrings("", c.out.items);
    o = try spawn(&.{ "env", "SHALE_FIXTURE" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqualStrings("present\n", c.out.items);
    c.out.clearRetainingCapacity();
    o = try spawn(&.{"pwd"}, .{ .argv = &.{}, .env = &env, .cwd = "/", .timeout_ms = 10_000 }, &c);
    try testing.expectEqualStrings("/\n", c.out.items);
    c.out.clearRetainingCapacity();
    // stderr is the same stream.
    o = try spawn(&.{ "stderr", "on two" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqualStrings("on two\n", c.out.items);
}

test "spawn: a deadline ends it (TERM, then KILL for one that ignores TERM); a signal of its own is said; not found is an answer" {
    var c: Collect = .{};
    defer c.out.deinit(testing.allocator);
    const env = [_][]const u8{"PATH=/usr/bin:/bin"};
    var o = try spawn(&.{ "sleep", "20000" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 200 }, &c);
    try testing.expectEqual(Ended.timeout, o.ended);
    try testing.expect(o.ms < 5_000);
    o = try spawn(&.{ "ignore-term", "20000" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 300, .grace_ms = 300 }, &c);
    try testing.expectEqual(Ended.timeout, o.ended);
    try testing.expectEqual(@as(?u32, @intFromEnum(linux.SIG.KILL)), o.signal);
    try testing.expect(o.ms < 5_000);
    o = try spawn(&.{"kill-self"}, .{ .argv = &.{}, .env = &env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqual(Ended.signal, o.ended);
    try testing.expectEqual(@as(?u32, @intFromEnum(linux.SIG.KILL)), o.signal);
    try testing.expectError(error.NotFound, run(testing.allocator, .{ .argv = &.{"shale-no-such-program"}, .env = &env, .timeout_ms = 1000 }, &c));
    try testing.expectError(error.NotFound, run(testing.allocator, .{ .argv = &.{"./not-here"}, .env = &env, .timeout_ms = 1000 }, &c));
    try testing.expectError(error.NoCwd, spawn(&.{"pwd"}, .{ .argv = &.{}, .env = &env, .cwd = "/no/such/folder", .timeout_ms = 1000 }, &c));
    // Found along PATH: a program with no `/` in its name.
    c.out.clearRetainingCapacity();
    const dir = std.fs.path.dirname(fixture).?;
    const path_env = [_][]const u8{try std.fmt.allocPrint(testing.allocator, "PATH=/nonexistent:{s}", .{dir})};
    defer testing.allocator.free(path_env[0]);
    o = try run(testing.allocator, .{ .argv = &.{ "shale-fixture", "lines", "1" }, .env = &path_env, .timeout_ms = 10_000 }, &c);
    try testing.expectEqualStrings("line 1\n", c.out.items);
}

test "spawn: much output, past the pipe's buffer, all of it read" {
    var c: Collect = .{};
    defer c.out.deinit(testing.allocator);
    const env = [_][]const u8{"PATH=/usr/bin:/bin"};
    const o = try spawn(&.{ "spill", "1000000" }, .{ .argv = &.{}, .env = &env, .timeout_ms = 30_000 }, &c);
    try testing.expectEqual(@as(?u8, 0), o.code);
    try testing.expectEqual(@as(usize, 1_000_000), c.out.items.len);
}

/// A sink that sends `shale` (this thread) a TERM at the first output: as
/// a TaskStop, or the session ending, would.
const Interrupting = struct {
    sent: bool = false,
    pub const Error = error{};
    fn write(i: *Interrupting, bytes: []const u8) Interrupting.Error!void {
        _ = bytes;
        // To this thread: the mask the loop sets is the thread's, and a
        // process-directed signal may land on another of the process's.
        if (!i.sent) _ = linux.tgkill(linux.getpid(), linux.gettid(), .TERM);
        i.sent = true;
    }
};

test "spawn: a TERM to shale while a program runs ends the program's group and says so; shale's own mask is put back" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: Interrupting = .{};
    const env = [_][]const u8{"PATH=/usr/bin:/bin"};
    const o = try run(testing.allocator, .{ .argv = &.{ fixturePath(&buf), "ignore-term", "20000" }, .env = &env, .timeout_ms = 30_000, .grace_ms = 300 }, &i);
    try testing.expectEqual(Ended.interrupted, o.ended);
    try testing.expect(o.ms < 5_000);
    // The TERM was taken by the loop, and TERM is unblocked again.
    var now: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, null, &now);
    try testing.expect(!linux.sigismember(&now, .TERM));
}
