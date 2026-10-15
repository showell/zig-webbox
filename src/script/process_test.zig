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
    try testing.expectEqual(@as(u64, 1), finish(whole, std.math.maxInt(u64)));
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
