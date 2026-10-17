//! **THE LINUX PRELUDE, TESTED** (metal-vmm QUEUE 233, chunk 2): every
//! function of `shale_prelude_linux.shale`, through the gate, against a
//! temporary root and the fixture program the build makes.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");
const linux_prelude = host_linux.linux_prelude;

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{linux_prelude};
}

test "linux prelude: run and real are the host's, by the names a script types" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput("local r = run({\"shale-fixture\", \"lines\", \"2\"}, {timeout_ms = 10000, tail = 5}) print(r.out, r.code, r.ended)", "line 1\nline 2\n\t0\texit\n");
    try t.expectOutput("print(sub(real(\"\"), -1) ~= \"/\", sub(real(\"a/b.txt\"), -8))", "true\t/a/b.txt\n");
    // A slip in run's options is the host's stop, at the script's call.
    try t.expectStop("run({\"shale-fixture\", \"lines\", \"2\"}, {tail = 5})", .atomic, .argument, "timeout_ms");
}

test "linux prelude: must gives a run that exited 0, and fails on one that did not, its output printed first" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput("print(must(run({\"shale-fixture\", \"lines\", \"1\"}, {timeout_ms = 10000, tail = 5})).kept_lines)", "1\n");
    try t.expectStop("must(run({\"shale-fixture\", \"exit\", \"3\"}, {timeout_ms = 10000, tail = 5}))", .atomic, .fail, "`shale-fixture exit 3` exited 3");
    try t.expectStop("must(run({\"shale-fixture\", \"sleep\", \"5000\"}, {timeout_ms = 100, tail = 5}))", .atomic, .fail, "`shale-fixture sleep 5000` timed out");
    try t.expectStop("must(run({\"shale-fixture\", \"kill-self\"}, {timeout_ms = 10000, tail = 5}))", .atomic, .fail, "`shale-fixture kill-self` was ended by a signal");
    // A failing run's output is printed before the stop, its last newline
    // the print's; a run that printed nothing prints nothing.
    // Once, not through the gate: each engine would wait out the grace.
    var r = t.runOnce("must(run({\"shale-fixture\", \"ignore-term\", \"5000\"}, {timeout_ms = 100, tail = 5}))", .atomic);
    defer r.deinit();
    try testing.expect(r.stop != null);
    try testing.expectEqualStrings("ignoring\n", r.output);
    var q = t.run("must(run({\"shale-fixture\", \"exit\", \"1\"}, {timeout_ms = 10000, tail = 5}))", .atomic);
    defer q.deinit();
    try testing.expectEqualStrings("", q.output);
}

test "linux prelude: re_lines, its lines numbered, inverted or folded if asked" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const show = "for m in got do print(m.line, m.text) end";
    try t.expectOutput("local got = re_lines(\"a1\\nb\\nA2\\n\", \"a[0-9]\") " ++ show, "1\ta1\n");
    try t.expectOutput("local got = re_lines(\"a1\\nb\\nA2\\n\", \"a[0-9]\", {nocase = true}) " ++ show, "1\ta1\n3\tA2\n");
    try t.expectOutput("local got = re_lines(\"a1\\nb\\nA2\\n\", \"a[0-9]\", {invert = true}) " ++ show, "2\tb\n3\tA2\n");
    try t.expectStop("re_lines(\"a\", \"a\", {inverse = true})", .atomic, .fail, "`re_lines` takes `invert` and `nocase`, not `inverse`");
}

test "linux prelude: head_lines and tail_lines, of any size; a missing file is nil" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("ten.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try t.put("open.txt", "a\nb\nc");
    try t.put("empty.txt", "");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (1..20_001) |i| try big.print(testing.allocator, "line number {d} of the big file\n", .{i});
    try t.put("big.txt", big.items);
    try t.expectOutput("print(join(head_lines(\"ten.txt\", 3), \",\"), join(tail_lines(\"ten.txt\", 3), \",\"), #head_lines(\"ten.txt\", 99), #tail_lines(\"ten.txt\", 99))", "1,2,3\t8,9,10\t10\t10\n");
    try t.expectOutput("print(join(tail_lines(\"open.txt\", 2), \",\"), #tail_lines(\"empty.txt\", 2), #head_lines(\"empty.txt\", 2), #tail_lines(\"ten.txt\", 0))", "b,c\t0\t0\t0\n");
    try t.expectOutput("print(head_lines(\"none.txt\", 2) == nil, tail_lines(\"none.txt\", 2) == nil)", "true\ttrue\n");
    // Past one part: the tail reads back in doubling parts until it fits.
    try t.expectOutput("print(join(tail_lines(\"big.txt\", 2), \"|\"), #tail_lines(\"big.txt\", 5000), tail_lines(\"big.txt\", 5000)[1])", "line number 19999 of the big file|line number 20000 of the big file\t5000\tline number 15001 of the big file\n");
    try t.expectOutput("print(head_lines(\"big.txt\", 3000)[3000])", "line number 3000 of the big file\n");
    try t.expectStop("head_lines(\"ten.txt\", -1)", .atomic, .fail, "`head_lines`: -1 lines");
    try t.expectStop("tail_lines(\"ten.txt\", -1)", .atomic, .fail, "`tail_lines`: -1 lines");
}

test "linux prelude: unique keeps the first of each, in order" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput("print(join(unique({\"b\", \"a\", \"b\", \"c\", \"a\"}), \",\"), #unique({}))", "b,a,c\t0\n");
}

test "linux prelude: grep_all numbers the lines holding a literal across a file's parts" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (1..10_001) |i| try big.print(testing.allocator, "{s} line {d} of the big file\n", .{ if (i % 2500 == 0) "HIT" else "the", i });
    try t.put("big.txt", big.items);
    try t.expectOutput("for m in grep_all(\"big.txt\", \"HIT\") do print(m.line, m.text) end", "2500\tHIT line 2500 of the big file\n5000\tHIT line 5000 of the big file\n7500\tHIT line 7500 of the big file\n10000\tHIT line 10000 of the big file\n");
    try t.expectStop("grep_all(\"big.txt\", \"\")", .atomic, .fail, "`grep_all` of \"\"");
}

fn touch(t: *T, name: []const u8, seconds: i64) !void {
    const path = try std.fmt.allocPrintSentinel(t.arena.allocator(), "{s}/{s}", .{ t.root, name }, 0);
    const ts: [2]std.os.linux.timespec = .{ .{ .sec = seconds, .nsec = 0 }, .{ .sec = seconds, .nsec = 0 } };
    try testing.expectEqual(@as(usize, 0), std.os.linux.utimensat(std.os.linux.AT.FDCWD, path, &ts, 0));
}

test "linux prelude: newest, a folder's names by when they changed, newest first" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.tmp.dir.createDirPath(t.threaded.io(), "logs");
    for ([_]struct { []const u8, i64 }{ .{ "logs/a", 300 }, .{ "logs/b", 100 }, .{ "logs/c", 200 }, .{ "logs/d", 300 } }) |f| {
        try t.put(f[0], "x");
        try touch(&t, f[0], f[1]);
    }
    try t.expectOutput("print(join(newest(\"logs\", 3), \",\"), #newest(\"logs\", 9))", "a,d,c\t4\n");
}

test "linux prelude: create refuses a file already there" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("old.txt", "old");
    try t.expectOutput("create(\"new.txt\", \"made\") print(read(\"new.txt\"))", "made\n");
    try t.expectStop("create(\"old.txt\", \"x\")", .atomic, .fail, "`create`: old.txt is there already");
    try testing.expectEqualStrings("old", try t.file("old.txt"));
}

test "linux prelude: edits_all checks every file's edits before it writes any" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("a.txt", "one two\n");
    try t.put("b.txt", "three\n");
    // The second file's edit fails: neither is written.
    try t.expectStop("edits_all({{\"a.txt\", {{old = \"one\", new = \"1\"}}}, {\"b.txt\", {{old = \"four\", new = \"4\"}}}})", .atomic, .fail, "`edits_all`: b.txt's edit 1: `old` is not there; nothing written");
    try testing.expectEqualStrings("one two\n", try t.file("a.txt"));
    try t.expectStop("edits_all({{\"a.txt\", {{old = \"o\", new = \"0\"}}}})", .atomic, .fail, "`edits_all`: a.txt's edit 1: `old` is there 2 times, and the edit does not say `all`; nothing written");
    // In sequence within a file, as edit's list form.
    var r = t.run("print(edits_all({{\"a.txt\", {{old = \"one\", new = \"1\"}, {old = \"1 two\", new = \"12\"}}}, {\"b.txt\", {{old = \"e\", new = \"E\", all = true}}}}))", .atomic);
    defer r.deinit();
    try testing.expect(r.stop == null);
    try testing.expect(std.mem.endsWith(u8, r.output, "\n4\n"));
    try testing.expectEqualStrings("12\n", try t.file("a.txt"));
    try testing.expectEqualStrings("thrEE\n", try t.file("b.txt"));
}

test "linux prelude: the repo's and the user's preludes come after it, SHALE_PRELUDE pinning the user's" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    const io = t.threaded.io();
    var why: []const u8 = "";
    // Neither there: the Linux prelude and the git prelude alone.
    const alone = try host_linux.loadPreludes(a, io, t.root, null, "/no/such/home", &why);
    try testing.expectEqual(@as(usize, 2), alone.len);
    try testing.expectEqualStrings("the Linux prelude", alone[0].name);
    try testing.expectEqualStrings("the git prelude", alone[1].name);
    try t.tmp.dir.createDirPath(io, ".shale");
    try t.put(".shale/prelude.shale", "function twice(x)\n  return x * 2\nend\n");
    try t.put("mine.shale", "function shout(s)\n  return upper(s) .. \"!\" .. twice(1)\nend\nfunction boom()\n  return 1 + {}\nend\n");
    const mine = try std.fmt.allocPrint(a, "{s}/mine.shale", .{t.root});
    const all = try host_linux.loadPreludes(a, io, t.root, mine, "/no/such/home", &why);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings(".shale/prelude.shale", all[2].name);
    try testing.expectEqualStrings(mine, all[3].name);
    t.preludes = all;
    try t.expectOutput("print(twice(3), shout(\"hi\"), #unique({\"a\", \"a\"}))", "6\tHI!2\t1\n");
    var r = t.run("boom()", .atomic);
    defer r.deinit();
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}'s boom", .{mine}), r.stop.?.function);
    // SHALE_PRELUDE="" is no user prelude; one named and missing is a mistake.
    try testing.expectEqual(@as(usize, 3), (try host_linux.loadPreludes(a, io, t.root, "", "/no/such/home", &why)).len);
    try testing.expectError(error.Malformed, host_linux.loadPreludes(a, io, t.root, "/no/such/prelude.shale", "/h", &why));
    try testing.expectEqualStrings("SHALE_PRELUDE=/no/such/prelude.shale: FileNotFound", why);
    // The default user prelude, from home.
    try t.tmp.dir.createDirPath(io, "home/.config/shale");
    try t.put("home/.config/shale/prelude.shale", "function hello()\n  return 1\nend\n");
    const home = try std.fmt.allocPrint(a, "{s}/home", .{t.root});
    const from_home = try host_linux.loadPreludes(a, io, t.root, null, home, &why);
    try testing.expectEqualStrings("~/.config/shale/prelude.shale", from_home[3].name);
    // A later prelude may not take an earlier one's name.
    try t.put(".shale/prelude.shale", "function unique(x)\n  return x\nend\n");
    t.preludes = try host_linux.loadPreludes(a, io, t.root, "", "/h", &why);
    try t.expectStop("print(1)", .atomic, .name, ".shale/prelude.shale's `unique` is the Linux prelude's already");
}
