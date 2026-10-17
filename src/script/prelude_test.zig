//! The prelude (src/script/prelude.shale, metal-vmm QUEUE 220): functions
//! every script has, written in Shale, each part of their work one builtin
//! call under its cap. Every run here is the gate's (script.run in tests):
//! the VM held to the tree-walker, cut into slices and as a background run.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;
const Fixture = @import("builtins_test.zig").Fixture;

test "prelude: walk_all gives the whole walk across its parts, keeps the caller's options, and costs what the parts cost" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    try f.tmp.dir.createDirPath(io, "data/chat/deep/deeper");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/deep/deeper/c.md", .data = "x" });
    const all = "local o = {kind = \"file\"} local got = {} for e in walk_all(\"\", o) do push(got, e.path) end print(join(got, \",\")) print(count(o))";
    const want = "chat/a.md,chat/b.md,chat/deep/deeper/c.md,top.txt\n1\n";
    try f.expectOutput(all, want);
    // In parts of two entries: the same.
    var cut = f.run(all, .{ .call_entries = 2 });
    defer cut.deinit();
    if (cut.stop) |s| std.debug.print("{s}\n", .{s.message});
    try testing.expectEqualStrings(want, cut.output);
    // An empty map of options, and the folder's own entries.
    try f.expectOutput("print(#walk_all(\"chat\", {}))", "5\n");
}

test "prelude: count_all and find_next scan a file past the call-bytes cap, part by part, as the whole file's counts would" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    // 3 MiB less a little: a part's seam inside a needle, more than once.
    const n = 3 * 1024 * 1024 - 7;
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    @memset(big, '.');
    var want: usize = 0;
    var first_after: ?usize = null;
    var at: usize = 1000;
    while (at + 5 <= n) : (at += 262_139) {
        @memcpy(big[at..][0..5], "NEEDL");
        want += 1;
        if (first_after == null and at >= 1024 * 1024 + 3) first_after = at;
    }
    // One across the first part's seam.
    @memcpy(big[1024 * 1024 - 2 ..][0..5], "NEEDL");
    want += 1;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/big.log", .data = big });
    const counted = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{want});
    defer testing.allocator.free(counted);
    try f.expectOutput("print(count_all(\"big.log\", \"NEEDL\"))", counted);
    try f.expectOutput("print(find_next(\"big.log\", \"NEEDL\", 0))", "1000\n");
    try f.expectOutput("print(find_next(\"big.log\", \"NEEDL\", 1001))", "263139\n");
    try f.expectOutput("print(find_next(\"big.log\", \"NEEDL\", 1048574))", "1048574\n");
    const after = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{first_after.?});
    defer testing.allocator.free(after);
    try f.expectOutput("print(find_next(\"big.log\", \"NEEDL\", 1048577))", after);
    try f.expectOutput("print(find_next(\"big.log\", \"absent\", 0))", "nil\n");
    try f.expectOutput("print(count_all(\"top.txt\", \"o\"), find_next(\"top.txt\", \"p\", 3))", "1\tnil\n");
    // Each in every one of its occurrences, as a loop over find_next.
    var each = f.run("local at = 0 local n = 0 while true do local x = find_next(\"big.log\", \"NEEDL\", at) if x == nil then break end n = n + 1 at = x + 1 end print(n)", .{});
    defer each.deinit();
    try testing.expectEqualStrings(counted, each.output);
}

test "prelude: a script's own function of a prelude name is its own, and a call before it is the prelude's" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(#walk_all(\"chat\", {}))\nfunction walk_all(p, o) return {1} end\nprint(#walk_all(\"chat\", {}))", "2\n1\n");
    // Declared twice by the script itself: still refused.
    try f.expectStop("function walk_all(p, o) return 1 end\nfunction walk_all(p, o) return 2 end", .name);
}

test "prelude: an error inside a prelude function says it is the prelude's" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run("print(count_all(\"missing.log\", \"x\"))", .{});
    defer r.deinit();
    const s = r.stop orelse return error.TestUnexpectedResult;
    try testing.expectEqual(script.diag.Class.store, s.class);
    try testing.expectEqualStrings("the prelude's count_all", s.function);
}

test "prelude: walk_upto walks as far as its reads allow, keeps what it is told to, and goes on from `more` to the rest (QUEUE 229)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    try f.tmp.dir.createDirPath(io, "data/chat/deep/deeper");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/deep/deeper/c.md", .data = "x" });
    const whole = "local got = {} for e in walk_all(\"\", {}) do push(got, e.path) end print(join(got, \",\"))";
    var all = f.run(whole, .{});
    defer all.deinit();
    try testing.expectEqual(@as(?script.Stop, null), all.stop);
    // The runs below share the fixture's output buffer.
    const want = try testing.allocator.dupe(u8, all.output[0 .. all.output.len - 1]);
    defer testing.allocator.free(want);
    // Plenty of reads: the whole walk, done.
    try f.expectOutput("local p = walk_upto(\"\", {}, 1) print(#p.entries, p.done, p.more == \"\")", "7\ttrue\ttrue\n");
    // For every budget of reads and every count to keep: the run finishes,
    // keeps at least that many, and the parts it says to go on from add up
    // to the whole walk, each entry once.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (3..14) |reads| for (0..4) |keep| {
        var start: []const u8 = "";
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        var turns: usize = 0;
        var done = false;
        while (true) : (turns += 1) {
            if (turns == 40) return error.NeverEnds;
            var src_buf: [512]u8 = undefined;
            const src = try std.fmt.bufPrint(&src_buf, "local p = walk_upto(\"\", {{after = \"{s}\"}}, {d}) local paths = {{}} for e in p.entries do push(paths, e.path) end print(budget().reads >= {d}, p.done) print(p.more) print(join(paths, \",\"))", .{ start, keep, keep });
            var r = f.run(src, .{ .reads = reads });
            defer r.deinit();
            errdefer std.debug.print("reads {d} keep {d} from \"{s}\":\n{s}\n", .{ reads, keep, start, r.output });
            try testing.expectEqual(@as(?script.Stop, null), r.stop);
            var lines = std.mem.splitScalar(u8, r.output, '\n');
            const head = lines.next().?;
            try testing.expect(std.mem.startsWith(u8, head, "true\t"));
            const more = lines.next().?;
            const paths = lines.next().?;
            if (paths.len > 0) {
                if (got.items.len > 0) try got.append(testing.allocator, ',');
                try got.appendSlice(testing.allocator, paths);
            }
            if (std.mem.endsWith(u8, head, "true")) {
                done = true;
                break;
            }
            // A run with too few reads for any entry takes none: the
            // budget, not the walk, is what ends it, and that is a fixed
            // budget here.
            if (std.mem.eql(u8, more, start)) break;
            start = try arena.allocator().dupe(u8, more);
        }
        if (done) try testing.expectEqualStrings(want, got.items);
        // Room for the walk's head, an entry and what is kept: it ends.
        if (reads >= 4 + 2 + keep + 4) try testing.expect(done);
    };
}

test "prelude: room_for says whether the budgets left hold what is asked, by budget()'s names" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(room_for({reads = 5}), room_for({reads = 10001}), room_for({}))", "true\tfalse\ttrue\n");
    var r = f.run("print(room_for({reads = 5}), room_for({reads = 6}), room_for({}))", .{ .reads = 5 });
    defer r.deinit();
    try testing.expectEqualStrings("true\tfalse\ttrue\n", r.output);
    var bad = f.run("print(room_for({readz = 1}))", .{});
    defer bad.deinit();
    try testing.expectEqual(script.diag.Class.index, bad.stop.?.class);
}

test "prelude: the functions found in prelude.shale are every function a parse of it declares, and it declares nothing else (QUEUE 230)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stop: ?script.diag.Stop = null;
    // The prelude parsed as a script's source: its functions the script's own.
    const whole = try script.parse.parse(arena.allocator(), script.parse.prelude, 64, &stop);
    try testing.expectEqual(whole.functions.len, script.parse.prelude_index.len);
    for (whole.functions, script.parse.prelude_index) |f, at| {
        try testing.expectEqualStrings(f.name, at.name);
        try testing.expectEqual(f.pos.line, at.line);
        try testing.expectEqual(@as(u32, 1), f.pos.column);
    }
    // A declaration is an empty `do` where it stood: nothing else is there.
    for (whole.main.body) |s| try testing.expect(s.kind == .do and s.kind.do.len == 0);
}

test "prelude: every prelude function is reached when a script calls it, one script each, and runs (QUEUE 230)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const calls = [_]struct { []const u8, []const u8 }{
        .{ "walk_all", "print(#walk_all(\"chat\", {}))" },
        .{ "walk_upto", "print(walk_upto(\"chat\", {}, 2).done)" },
        .{ "room_for", "print(room_for({reads = 1}))" },
        .{ "glob", "print(#glob(\"*.txt\"))" },
        .{ "count_all", "print(count_all(\"top.txt\", \"o\"))" },
        .{ "find_next", "print(find_next(\"top.txt\", \"p\", 3))" },
    };
    try testing.expectEqual(script.parse.prelude_index.len, calls.len);
    for (script.parse.prelude_index, calls) |at, c| {
        try testing.expectEqualStrings(at.name, c[0]);
        var r = f.run(c[1], .{});
        defer r.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ c[1], if (r.stop) |s| s.message else "" });
        try testing.expect(r.finished());
        try testing.expect(r.output.len > 0);
    }
}

test "prelude: a prelude function's own calls are the prelude's, though the script declared one of their name (QUEUE 230)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // glob's walk_all is the prelude's, parsed at glob's first call, after
    // the script's own: the script's is called only by the script.
    try f.expectOutput("function walk_all(p, o) return {} end\nprint(#glob(\"*.txt\"), #walk_all(\"\", {}))", "1\t0\n");
    // A prelude function first met inside the script's function: the
    // function's locals and the script's consts are not the prelude's.
    try f.expectOutput("const got = 9\nfunction f(o) local more = 1 return #glob(\"*.txt\") + more + got end\nprint(f(0))", "11\n");
    // A `const` of the name of a function the prelude calls hides nothing
    // of the prelude's.
    try f.expectOutput("const walk_all = 1\nfunction f() return #glob(\"*.txt\") end\nprint(f())", "1\n");
}
