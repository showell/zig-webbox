//! **THE CONTRACT, TESTED** (metal-vmm QUEUE 211, Steve's model): a run as
//! a host sees it, through `process.zig` alone.

const std = @import("std");
const script = @import("script.zig");
const process = script.process;
const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.threaded = std.Io.Threaded.init(testing.allocator, .{});
        const io = f.threaded.io();
        try f.tmp.dir.createDirPath(io, "data/notes");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "data/notes/a.txt", .data = "alpha\nbeta\n" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "data/notes/b.txt", .data = "gamma\n" });
        f.root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &f.tmp.sub_path, "data" });
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.root);
        f.threaded.deinit();
        f.tmp.cleanup();
    }

    fn start(f: *Fixture, a: std.mem.Allocator, src: []const u8, mode: process.Mode) !*process.Process {
        return process.Process.start(f.threaded.io(), a, f.root, src, mode, .{}, 100, 64 * 1024);
    }
};

/// Steps `p` to its end in slices of `steps`; how many it took.
fn finish(p: *process.Process, steps: u64) u64 {
    var n: u64 = 0;
    while (true) {
        n += 1;
        switch (p.step(.{ .steps = steps })) {
            .paused => {},
            .finished, .stopped => return n,
        }
    }
}

test "process: a background run that changes the store is refused, naming atomic, and changes nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "replace(\"notes/a.txt\", \"x\")", "append(\"notes/c.txt\", \"x\")", "mkdir(\"new\")", "remove(\"notes/a.txt\")", "remove_tree(\"notes\")" }) |src| {
        const p = try f.start(testing.allocator, src, .background);
        defer p.kill();
        try testing.expectEqual(process.Outcome.stopped, p.step(.{}));
        const s = p.status().stop.?;
        try testing.expectEqual(script.diag.Class.argument, s.class);
        try testing.expect(std.mem.indexOf(u8, s.message, "atomic") != null);
        try testing.expectEqual(@as(usize, 0), p.status().effects);
    }
    // The store as it was.
    const a = try f.tmp.dir.readFileAlloc(f.threaded.io(), "data/notes/a.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("alpha\nbeta\n", a);
    // The same script, atomic, changes it.
    const p = try f.start(testing.allocator, "replace(\"notes/c.txt\", \"made\")", .atomic);
    defer p.kill();
    // A slice to the store call, and one after it.
    try testing.expectEqual(process.Outcome.paused, p.step(.{}));
    try testing.expectEqual(process.Outcome.finished, p.step(.{}));
    try testing.expectEqual(@as(usize, 1), p.status().effects);
}

const scan =
    \\local n = 0
    \\for name in ls("notes") do
    \\  local text = read("notes/" .. name)
    \\  for line in lines(text) do
    \\    n = n + 1
    \\    print(name, n, upper(line))
    \\  end
    \\end
    \\print("lines", n, now())
;

test "process: a background run's output is the atomic run's, in slices of any size" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const whole = try f.start(testing.allocator, scan, .atomic);
    defer whole.kill();
    // Unlimited steps: a slice to each store call (an `ls`, two `read`s),
    // and one after the last.
    try testing.expectEqual(@as(u64, 4), finish(whole, std.math.maxInt(u64)));
    try testing.expectEqual(process.State.finished, whole.status().state);
    for ([_]u64{ 1, 2, 3, 7, 50 }) |n| {
        const p = try f.start(testing.allocator, scan, .background);
        defer p.kill();
        const slices = finish(p, n);
        try testing.expect(slices > 1);
        try testing.expectEqualStrings(whole.output(), p.output());
        try testing.expectEqual(whole.status().steps, p.status().steps);
        try testing.expectEqual(slices, p.status().slices);
    }
}

test "process: now() is the slice's, not frozen at the start" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const p = try f.start(testing.allocator, "local a = now() for i = 1, 50 do end print(a, now())", .background);
    defer p.kill();
    try testing.expectEqual(process.Outcome.paused, p.step(.{ .steps = 5, .now = 1000 }));
    while (p.step(.{ .steps = 5, .now = 2000 }) == .paused) {}
    try testing.expectEqualStrings("1000\t2000\n", p.output());
}

test "process: kill gives back everything it holds, whenever it is killed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cases = [_]struct { src: []const u8, slices: u64 }{
        .{ .src = scan, .slices = 3 }, // mid-run
        .{ .src = scan, .slices = 1000 }, // finished
        .{ .src = "local x = ", .slices = 1 }, // stopped before it ran
        .{ .src = "local l = {} for i = 1, 100000 do push(l, \"item \" .. i) end", .slices = 40 }, // holding megabytes
    };
    for (cases) |c| {
        var peak: script.value.Peak = .{ .child = testing.allocator };
        const p = try f.start(peak.allocator(), c.src, .background);
        for (0..c.slices) |_| _ = p.step(.{ .steps = 20_000 });
        try testing.expect(peak.now > 0);
        p.kill();
        try testing.expectEqual(@as(usize, 0), peak.now);
    }
}

test "process: an ended run says so again and runs nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const p = try f.start(testing.allocator, "print(1)", .background);
    defer p.kill();
    try testing.expectEqual(process.Outcome.finished, p.step(.{}));
    const steps = p.status().steps;
    try testing.expectEqual(process.Outcome.finished, p.step(.{}));
    try testing.expectEqual(steps, p.status().steps);
    try testing.expectEqualStrings("1\n", p.output());
    const bad = try f.start(testing.allocator, "print(", .background);
    defer bad.kill();
    try testing.expectEqual(process.Outcome.stopped, bad.step(.{}));
    try testing.expectEqual(script.diag.Class.syntax, bad.status().stop.?.class);
}

test "process: every source within the source budget compiles, in at most half the default machine budget, and runs (the box's re-review, FEEDBACK 1599c8f, item 3)" {
    // The shapes that take the most of the machine a byte of source: short
    // statements, a list literal of ints or strings, calls, `if`s. At 4 MiB
    // and with the parse's and the code's growth left in their arenas,
    // `x = x + 1` and a list literal stopped `budget machine` at 1:1.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const Shape = struct { head: []const u8, part: []const u8, tail: []const u8 };
    for ([_]Shape{
        .{ .head = "local x = 0\n", .part = "x=x+1\n", .tail = "" },
        .{ .head = "local x = 0\n", .part = "x = x + 1\n", .tail = "" },
        .{ .head = "local x = 0\n", .part = "x=1\n", .tail = "" },
        .{ .head = "local l = {", .part = "1,", .tail = "1}" },
        .{ .head = "local l = {", .part = "\"\",", .tail = "1}" },
        .{ .head = "local l = {", .part = "{},", .tail = "1}" },
        .{ .head = "function f() end\n", .part = "f()\n", .tail = "" },
        .{ .head = "function f(a) end\n", .part = "f(1)\n", .tail = "" },
        .{ .head = "", .part = "print(1)\n", .tail = "" },
        .{ .head = "local x = 1\n", .part = "if x then end\n", .tail = "" },
    }) |shape| {
        const room = script.Budgets.default_source_bytes - shape.head.len - shape.tail.len;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, shape.head);
        for (0..room / shape.part.len) |_| try src.appendSlice(testing.allocator, shape.part);
        try src.appendSlice(testing.allocator, shape.tail);
        const budgets: script.Budgets = .{ .steps = 100_000_000, .output_bytes = 1024 * 1024 };
        const p = try process.Process.start(threaded.io(), testing.allocator, ".zig-cache/no-root", src.items, .atomic, budgets, 0, 16);
        const compiled = p.machine.budget.held;
        const stop = p.status().stop;
        p.kill();
        if (stop != null or compiled > budgets.machine_bytes / 2) {
            std.debug.print("{s}...: {d} bytes compiled to {d} of the machine's {d}, stop {?s}\n", .{ shape.part, src.items.len, compiled, budgets.machine_bytes, if (stop) |s| s.message else null });
            return error.TestUnexpectedResult;
        }
        // And it runs, the walker beside it (the gate).
        var r = script.run(threaded.io(), testing.allocator, ".zig-cache/no-root", src.items, budgets, 0, &big_out);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}...: stopped {d}:{d} {?t}: {s}\n", .{ shape.part, s.line, s.column, s.budget, s.message });
            return error.TestUnexpectedResult;
        }
    }
}

var big_out: [1024 * 1024]u8 = undefined;

test "process: a slice ends after any store call, however many steps it has left (metal-vmm QUEUE 211, Steve's model: swap on I/O)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // Three store calls, then pure work: four slices, each with steps to spare.
    const p = try f.start(testing.allocator, "print(exists(\"notes/a.txt\")) print(count_lines(\"notes/a.txt\")) local n = 0 for i = 1, 100 do n = n + i end print(is_dir(\"notes\"), n)", .atomic);
    defer p.kill();
    var outcomes: [8]process.Outcome = undefined;
    var n: usize = 0;
    while (n < outcomes.len) {
        outcomes[n] = p.step(.{});
        n += 1;
        if (outcomes[n - 1] != .paused) break;
    }
    try testing.expectEqualSlices(process.Outcome, &.{ .paused, .paused, .paused, .finished }, outcomes[0..n]);
    try testing.expectEqualStrings("true\n2\ntrue\t5050\n", p.output());
    try testing.expectEqual(@as(u64, 4), p.status().slices);
    // A failed store call is I/O too: caught by `attempt`, it still ends the slice.
    const q = try f.start(testing.allocator, "function r() return read(\"nope\") end print(attempt(r).ok)", .atomic);
    defer q.kill();
    try testing.expectEqual(process.Outcome.paused, q.step(.{}));
    try testing.expectEqual(process.Outcome.finished, q.step(.{}));
    // No store call, one slice.
    const w = try f.start(testing.allocator, "local n = 0 for i = 1, 1000 do n = n + i end print(n)", .atomic);
    defer w.kill();
    try testing.expectEqual(process.Outcome.finished, w.step(.{}));
}

test "process: it keeps its own source: the caller's freed after start, the run goes on (a crash on Dog Park's host, metal-vmm QUEUE 214)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // From the page allocator: freed is unmapped, so a read of it faults.
    const text = "local m = {a = \"one\"}\nlocal n = 0\nfor name in ls(\"notes\") do n = n + 1 end\nprint(m.a, n, m[\"a\"])\n";
    const source = try std.heap.page_allocator.dupe(u8, text);
    const p = try f.start(testing.allocator, source, .background);
    defer p.kill();
    std.heap.page_allocator.free(source);
    while (p.step(.{}) == .paused) {}
    try testing.expectEqualStrings("one\t2\tone\n", p.output());
}

/// The functions a source's tree holds, the prelude's and its own, by name.
fn functionNames(src: []const u8, buf: *[16][]const u8) ![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stop: ?script.diag.Stop = null;
    const program = try script.parse.parse(arena.allocator(), src, 64, &stop);
    var n: usize = 0;
    for (program.functions) |f| {
        buf[n] = try std.fmt.bufPrint(&name_bufs[n], "{s}", .{f.name});
        n += 1;
    }
    std.mem.sort([]const u8, buf[0..n], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return buf[0..n];
}
var name_bufs: [16][64]u8 = undefined;

test "process: only the prelude a script calls is parsed and compiled, through the prelude's own calls (metal-vmm QUEUE 230)" {
    const Case = struct { src: []const u8, holds: []const []const u8 };
    for ([_]Case{
        .{ .src = "", .holds = &.{} },
        .{ .src = "print(1)", .holds = &.{} },
        .{ .src = "local r = walk_upto(\"\", {}, 2)", .holds = &.{"the prelude's walk_upto"} },
        // glob calls walk_all: what the prelude calls is reached too.
        .{ .src = "local g = glob(\"*\")", .holds = &.{ "the prelude's glob", "the prelude's walk_all" } },
        // Called twice, from the script and from a function: parsed once.
        .{ .src = "function f() return glob(\"*\") end local a = walk_all(\"\", {}) local b = f()", .holds = &.{ "f", "the prelude's glob", "the prelude's walk_all" } },
        // A script's own function of a prelude name is its own: the
        // prelude's is never reached.
        .{ .src = "function glob(p) return {} end local g = glob(\"*\")", .holds = &.{"glob"} },
    }) |c| {
        var buf: [16][]const u8 = undefined;
        const got = try functionNames(c.src, &buf);
        errdefer for (got) |g| std.debug.print("{s}: holds {s}\n", .{ c.src, g });
        try testing.expectEqual(c.holds.len, got.len);
        for (c.holds, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "process: a script that calls no prelude function holds the machine it did before the prelude grew (QUEUE 230: 48 KiB, where 229 left 112 KiB)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    for ([_]struct { []const u8, usize }{
        .{ "", 48 * 1024 },
        .{ "print(1)", 48 * 1024 },
        .{ "local r = walk_upto(\"\", {}, 2)", 64 * 1024 },
    }) |c| {
        const p = try process.Process.start(threaded.io(), testing.allocator, ".zig-cache/no-root", c[0], .atomic, .{}, 0, 16);
        defer p.kill();
        errdefer std.debug.print("{s}: the machine holds {d} after the compile\n", .{ c[0], p.machine.budget.held });
        try testing.expect(p.machine.budget.held <= c[1]);
    }
}
