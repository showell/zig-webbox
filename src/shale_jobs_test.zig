//! **JOBS, TESTED** (metal-vmm QUEUE 233, chunk 4): programs that outlive
//! the run that started them, reaped by a detached `shale --reap` (the
//! build's own `shale`), found again by their record's path. A job's start
//! happens once, so these run the VM once (`T.runOnce`); the mistakes a
//! job's call can make go through the gate.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");
const jobs = @import("shale_jobs.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{ host_linux.linux_prelude, host_linux.git_prelude };
}

fn once(t: *T, src: []const u8) ![]const u8 {
    var r = t.runOnce(src, .atomic);
    defer r.deinit();
    if (r.stop) |s| {
        std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
        return error.TestUnexpectedResult;
    }
    return t.arena.allocator().dupe(u8, r.output);
}

fn onceStop(t: *T, src: []const u8, class: @import("webbox").script.diag.Class, says: []const u8) !void {
    var r = t.runOnce(src, .atomic);
    defer r.deinit();
    const s = r.stop orelse return error.TestUnexpectedResult;
    errdefer std.debug.print("{s}: {s}: {s}\n", .{ src, @tagName(s.class), s.message });
    try testing.expectEqual(class, s.class);
    try testing.expect(std.mem.indexOf(u8, s.message, says) != null);
}

test "jobs: a job runs to its end, its output in its log, and job_wait says how it ended" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try testing.expectEqualStrings("exited\t0\tline 1\nline 2\nline 3\n\n", try once(&t, "local j = job_start({\"shale-fixture\", \"lines\", \"3\"}, {log = \"j.log\"}) local w = job_wait(j, {timeout_ms = 10000}) print(w.ended, w.code, read(\"j.log\"))"));
    try testing.expectEqualStrings("exited\t3\tfalse\n", try once(&t, "local j = job_start({\"shale-fixture\", \"exit\", \"3\"}, {log = \"e.log\"}) local w = job_wait(j, {timeout_ms = 10000}) print(w.ended, w.code, job_alive(j))"));
    // Its record, beside its log.
    const rec = try t.file("j.log.job");
    try testing.expect(std.mem.indexOf(u8, rec, "\nexit=0\n") != null);
    try testing.expect(std.mem.startsWith(u8, rec, "pid="));
}

test "jobs: a job outlives its run; a later run finds it by its record, waits for a line, and stops it" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try testing.expectEqualStrings("true\n", try once(&t, "local j = job_start({\"shale-fixture\", \"ignore-term\", \"20000\"}, {log = \"slow.log\"}) print(j.record == \"slow.log.job\")"));
    // A second run, as a later Bash call would be.
    try testing.expectEqualStrings("found\ttrue\n", try once(&t, "local w = job_wait(\"slow.log.job\", {timeout_ms = 10000, contains = \"ignoring\"}) print(w.ended, job_alive(\"slow.log.job\"))"));
    try testing.expectEqualStrings("timeout\n", try once(&t, "print(job_wait(\"slow.log.job\", {timeout_ms = 300}).ended)"));
    // It ignores TERM: the grace, then KILL.
    try testing.expectEqualStrings("true\tfalse\tfalse\n", try once(&t, "local was = job_stop(\"slow.log.job\") print(was, job_alive(\"slow.log.job\"), job_stop(\"slow.log.job\"))"));
    try testing.expectEqualStrings("exited\tfalse\t9\n", try once(&t, "local w = job_wait(\"slow.log.job\", {timeout_ms = 5000}) print(w.ended, has_key(w, \"code\"), w.signal)"));
    try testing.expect(std.mem.indexOf(u8, try t.file("slow.log.job"), "\nsignal=9\n") != null);
}

test "jobs: a job gone while its reaper lives is still ending; gone with its reaper and no end written, it is lost" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    // No process has this id; this test's own process stands in for a
    // reaper between its wait and its last write.
    const none = 0x7ffffff0;
    var buf: [1024]u8 = undefined;
    const me = std.os.linux.getpid();
    const my_start = jobs.startOf(&buf, me).?;
    try t.put("ending.log.job", try std.fmt.allocPrint(a, "pid={d}\npgid={d}\nstart=1\nstarted=0\nargv=x\nreaper={d}\nreaper_start={s}\n", .{ none, none, me, my_start }));
    try testing.expectEqualStrings("timeout\n", try once(&t, "print(job_wait(\"ending.log.job\", {timeout_ms = 300}).ended)"));
    try t.put("lost.log.job", try std.fmt.allocPrint(a, "pid={d}\npgid={d}\nstart=1\nstarted=0\nargv=x\nreaper={d}\nreaper_start=1\n", .{ none, none, none }));
    try testing.expectEqualStrings("lost\tfalse\tfalse\n", try once(&t, "local w = job_wait(\"lost.log.job\", {timeout_ms = 5000}) print(w.ended, has_key(w, \"code\"), has_key(w, \"signal\"))"));
}

test "jobs: a job started on a log whose job or reaper still lives is refused, its record kept" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    const none = 0x7ffffff0;
    var buf: [1024]u8 = undefined;
    const me = std.os.linux.getpid();
    const my_group: i32 = @intCast(std.os.linux.syscall1(.getpgid, 0));
    const my_start = jobs.startOf(&buf, me).?;
    // Its job lives (this test's own group stands in), its reaper gone.
    const busy = try std.fmt.allocPrint(a, "pid={d}\npgid={d}\nstart={s}\nstarted=0\nargv=x\nreaper={d}\nreaper_start=1\n", .{ me, my_group, my_start, none });
    try t.put("busy.log.job", busy);
    try onceStop(&t, "job_start({\"shale-fixture\", \"exit\", \"0\"}, {log = \"busy.log\"})", .host, "a job still runs on busy.log");
    try testing.expectEqualStrings(busy, try t.file("busy.log.job"));
    // Its job gone, its reaper living: its end is still to be written.
    const ending = try std.fmt.allocPrint(a, "pid={d}\npgid={d}\nstart=1\nstarted=0\nargv=x\nreaper={d}\nreaper_start={s}\n", .{ none, none, me, my_start });
    try t.put("ending.log.job", ending);
    try onceStop(&t, "job_start({\"shale-fixture\", \"exit\", \"0\"}, {log = \"ending.log\"})", .host, "a job still runs on ending.log");
    try testing.expectEqualStrings(ending, try t.file("ending.log.job"));
}

test "jobs: a log whose job's end is written takes a new job, though its reaper is still exiting" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    const none = 0x7ffffff0;
    var buf: [1024]u8 = undefined;
    const me = std.os.linux.getpid();
    const my_start = jobs.startOf(&buf, me).?;
    // Its end written, its reaper (this test's process stands in) between
    // that last write and its exit.
    try t.put("done.log.job", try std.fmt.allocPrint(a, "pid={d}\npgid={d}\nstart=1\nstarted=0\nargv=x\nreaper={d}\nreaper_start={s}\nexit=0\n", .{ none, none, me, my_start }));
    try testing.expectEqualStrings("exited\t0\n", try once(&t, "local j = job_start({\"shale-fixture\", \"exit\", \"0\"}, {log = \"done.log\"}) local w = job_wait(j, {timeout_ms = 10000}) print(w.ended, w.code)"));
    // As a script does it: wait, then start again on the same log at once.
    try testing.expectEqualStrings("exited\nexited\nexited\n", try once(&t,
        \\for i = 1, 3 do
        \\  local j = job_start({"shale-fixture", "exit", "0"}, {log = "again.log"})
        \\  print(job_wait(j, {timeout_ms = 10000}).ended)
        \\end
    ));
}

test "jobs: waiting for a line reads only what the log gained since it last looked, so a long wait on a large log keeps to its budgets" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    // A 7 MB log: read whole each second, its reads piled up in the run's
    // arena until one failed, taken for "not there yet": `exited`.
    try testing.expectEqualStrings("found\n", try once(&t, "local j = job_start({\"shale-fixture\", \"lines\", \"300000\", \"a line of the log\"}, {log = \"big.log\"}) print(job_wait(j, {timeout_ms = 10000, contains = \"log 300000\"}).ended)"));
    // Across pieces: a line that the poll's read cuts in two is found.
    try testing.expectEqualStrings("found\n", try once(&t, "print(job_wait(\"big.log.job\", {timeout_ms = 1000, contains = \"log 150000\\na line\"}).ended)"));
    // 4 MB growing over about 4 seconds: read whole at each look, the
    // looks cost more than this budget; read as it grows, about 262,000.
    t.budgets.steps = 400_000;
    try testing.expectEqualStrings("exited\n", try once(&t, "local j = job_start({\"shale-fixture\", \"chunks\", \"4000000\", \"1000\"}, {log = \"slow.log\"}) print(job_wait(j, {timeout_ms = 60000, contains = \"never printed\"}).ended)"));
}

test "jobs: the mistakes a job's call can make, each named" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectStop("job_start({\"shale-fixture\", \"lines\", \"1\"}, {})", .atomic, .argument, "`job_start` needs a `log`");
    try t.expectStop("job_start({\"shale-fixture\", \"lines\", \"1\"}, {log = \"x.log\", secrets = {K = \"k\"}})", .atomic, .argument, "no `secrets` on a job");
    try t.expectStop("job_start({\"shale-fixture\", \"lines\", \"1\"}, {log = \"x.log\", tail = 3})", .atomic, .argument, "`job_start` takes log, cwd, env and want, not `tail`");
    try t.expectStop("job_start({\"bash\", \"-c\", \"x\"}, {log = \"x.log\"})", .atomic, .refused, "`job_start` of `bash`");
    try t.expectStop("job_start({\"no-such-program-anywhere\"}, {log = \"x.log\"})", .atomic, .host, "`job_start`: `no-such-program-anywhere` is not found along PATH");
    try t.expectStop("job_alive(\"none.log.job\")", .atomic, .store, "`job_alive`: no job's record at none.log.job");
    try t.expectStop("job_wait(\"none.log.job\", {})", .atomic, .argument, "`job_wait` needs `timeout_ms`");
    try t.expectStop("job_wait(\"none.log.job\", {timeout_ms = 10, file = \"a\"})", .atomic, .argument, "`file` without `contains`");
}
