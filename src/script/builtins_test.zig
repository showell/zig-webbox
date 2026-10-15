//! The builtins against a real store in a temporary folder.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;
const Io = std.Io;

var out_buf: [64 * 1024]u8 = undefined;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,
    base: []const u8,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.base = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
        self.root = try std.fs.path.join(testing.allocator, &.{ self.base, "data" });
        const io = self.threaded.io();
        try self.tmp.dir.createDir(io, "data", .default_dir);
        // What lies beside the root, which no script may reach.
        try self.tmp.dir.createDir(io, "auth", .default_dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = "auth/secret", .data = "s3cret" });
        try self.tmp.dir.createDir(io, "data/chat", .default_dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/a.md", .data = "hello" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/b.md", .data = "world!" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "data/top.txt", .data = "top" });
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, src: []const u8, budgets: script.Budgets) script.Result {
        return script.run(self.threaded.io(), testing.allocator, self.root, src, budgets, 0, &out_buf);
    }

    fn expectOutput(self: *Fixture, src: []const u8, want: []const u8) !void {
        var r = self.run(src, .{});
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(want, r.output);
    }

    fn expectStop(self: *Fixture, src: []const u8, class: script.diag.Class) !void {
        var r = self.run(src, .{});
        defer r.deinit();
        const s = r.stop orelse {
            std.debug.print("finished, and should have stopped: {s}\n", .{src});
            return error.TestUnexpectedResult;
        };
        if (s.class != class) {
            std.debug.print("{s}\n  stopped {s}: {s}\n", .{ src, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
    }

    fn file(self: *Fixture, sub: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.threaded.io(), sub, testing.allocator, .unlimited);
    }
};

test "builtins: the store's reads: ls sorted, stat, exists, is_dir, read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(join(ls(\"\"), \",\"), join(ls(\"chat\"), \",\"))", "chat,top.txt\ta.md,b.md\n");
    try f.expectOutput("local s = stat(\"chat/b.md\") print(s.size, s.kind, stat(\"chat\").kind)", "6\tfile\tdirectory\n");
    try f.expectOutput("print(exists(\"chat/a.md\"), exists(\"chat/nope\"), exists(\"\"), is_dir(\"chat\"), is_dir(\"top.txt\"), is_dir(\"none\"))", "true\tfalse\ttrue\ttrue\tfalse\tfalse\n");
    try f.expectOutput("print(read(\"chat/a.md\") .. \" \" .. read(\"chat/b.md\"))", "hello world!\n");
}

test "builtins: the store's changes, each in the effects log with its outcome, and a stopped run keeps what it did" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    {
        var r = f.run("replace(\"new/x.txt\", \"one\") append(\"new/x.txt\", \"two\") mkdir(\"d/e\") remove(\"top.txt\") remove_tree(\"chat\")", .{});
        defer r.deinit();
        try testing.expect(r.finished());
        try testing.expectEqual(@as(usize, 5), r.effects.len);
        const want = [_][2][]const u8{ .{ "replace", "new/x.txt" }, .{ "append", "new/x.txt" }, .{ "mkdir", "d/e" }, .{ "remove", "top.txt" }, .{ "remove_tree", "chat" } };
        for (r.effects, want) |e, w| {
            try testing.expectEqualStrings(w[0], e.op);
            try testing.expectEqualStrings(w[1], e.path);
            try testing.expectEqualStrings("ok", e.outcome);
        }
    }
    const x = try f.file("data/new/x.txt");
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("onetwo", x);
    try f.expectOutput("print(exists(\"top.txt\"), exists(\"chat\"), is_dir(\"d/e\"))", "false\tfalse\ttrue\n");
    // A change that fails stops the run: logged with its error, and what
    // came before it stays done.
    var r = f.run("replace(\"kept.txt\", \"k\") remove(\"no/such/file\") replace(\"never.txt\", \"n\")", .{});
    defer r.deinit();
    try testing.expectEqual(script.diag.Class.store, r.stop.?.class);
    try testing.expectEqual(@as(usize, 2), r.effects.len);
    try testing.expectEqualStrings("ok", r.effects[0].outcome);
    try testing.expect(!std.mem.eql(u8, "ok", r.effects[1].outcome));
    try f.expectOutput("print(exists(\"kept.txt\"), exists(\"never.txt\"))", "true\tfalse\n");
}

test "builtins: every way out of the root is refused before the store is asked (each planted escape)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const escapes = [_][]const u8{
        "print(read(\"../auth/secret\"))",
        "print(read(\"chat/../../auth/secret\"))",
        "print(read(\"/etc/passwd\"))",
        "print(read(\"./top.txt\"))",
        "print(read(\"chat//a.md\"))",
        "print(read(\"chat/\"))",
        "print(ls(\"..\"))",
        "remove_tree(\"\")",
        "remove(\"\")",
        "replace(\"\", \"x\")",
        "mkdir(\"\")",
        "append(\"../auth/secret\", \"x\")",
        "remove_tree(\"..\")",
        "remove(\"../auth/secret\")",
        "print(read(\"\"))",
        "print(is_dir(\"\"))",
        "print(read(\"a\\\\b\"))",
        "print(read(\"chat/a.md:x\"))",
    };
    for (escapes) |src| {
        var r = f.run(src, .{});
        defer r.deinit();
        const s = r.stop orelse {
            std.debug.print("ran, and should have been refused: {s}\n", .{src});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(script.diag.Class.argument, s.class);
        try testing.expectEqual(@as(usize, 0), r.effects.len);
    }
    const secret = try f.file("auth/secret");
    defer testing.allocator.free(secret);
    try testing.expectEqualStrings("s3cret", secret);
    try f.expectOutput("print(exists(\"top.txt\"), exists(\"chat/a.md\"))", "true\ttrue\n");
}

test "builtins: store errors stop the script naming the path; the read and change budgets" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectStop("print(read(\"nope.txt\"))", .store);
    try f.expectStop("print(ls(\"nope\"))", .store);
    try f.expectStop("print(stat(\"nope\"))", .store);
    {
        var r = f.run("print(read(\"chat/a.md\")) print(read(\"chat/b.md\"))", .{ .read_bytes = 8 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.read_bytes, r.stop.?.budget.?);
        try testing.expectEqualStrings("hello\n", r.output);
    }
    {
        var r = f.run("for i = 1, 10 do print(exists(\"top.txt\")) end", .{ .reads = 3 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.reads, r.stop.?.budget.?);
    }
    {
        var r = f.run("for i = 1, 10 do replace(\"n\" .. i, \"x\") end", .{ .changes = 4 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.changes, r.stop.?.budget.?);
        try testing.expectEqual(@as(usize, 4), r.effects.len);
    }
    {
        var r = f.run("replace(\"a\", \"0123456789\") replace(\"b\", \"0123456789\")", .{ .change_bytes = 15 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.change_bytes, r.stop.?.budget.?);
        try testing.expectEqual(@as(usize, 1), r.effects.len);
    }
}

test "builtins: strings" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(join(split(\"a,b,,c\", \",\"), \"|\"), #split(\"\", \",\"), join(split(\"a--b\", \"--\"), \"+\"))", "a|b||c\t1\ta+b\n");
    try f.expectOutput("print(join({\"a\", 1, \"b\"}, \"-\"), join({}, \",\") == \"\")", "a-1-b\ttrue\n");
    try f.expectOutput("print(starts_with(\"hello\", \"he\"), ends_with(\"hello\", \"lo\"), contains(\"hello\", \"ll\"), contains(\"hello\", \"x\"))", "true\ttrue\ttrue\tfalse\n");
    try f.expectOutput("print(find(\"hello\", \"l\"), find(\"hello\", \"z\"), find(\"a.b\", \".\"))", "3\tnil\t2\n");
    try f.expectOutput("print(sub(\"hello\", 2, 4), sub(\"hello\", -3), sub(\"hello\", 2), sub(\"hello\", 0), sub(\"hello\", 4, 2), sub(\"hello\", -100, 100))", "ell\tllo\tello\thello\t\thello\n");
    try f.expectOutput("print(\"[\" .. trim(\" \\t a b \\n\") .. \"]\", upper(\"aBc1\"), lower(\"AbC\"))", "[a b]\tABC1\tabc\n");
    try f.expectOutput("print(tonumber(\"42\") + 1, tonumber(\"-7\"), tostring(5) .. \"x\")", "43\t-7\t5x\n");
    const bad = [_][]const u8{ "tonumber(\"\")", "tonumber(\"1.5\")", "tonumber(\" 1\")", "tonumber(\"+1\")", "tonumber(\"0x1\")", "tonumber(\"99999999999999999999\")", "tonumber(\"-\")" };
    for (bad) |src| try f.expectStop(src, .argument);
    try f.expectStop("split(\"a\", \"\")", .argument);
    try f.expectStop("join({{}}, \",\")", .type);
    try f.expectStop("upper(1)", .type);
    try f.expectStop("sub(\"a\")", .argument);
}

test "builtins: lists and maps: push, sort, keys, has_key, count" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("local l = {3, 1, 2} sort(l) print(join(l, \",\")) local s = {\"b\", \"a\", \"c\"} sort(s) print(join(s, \",\"))", "1,2,3\na,b,c\n");
    try f.expectOutput("local m = {} m.x = 1 m.y = 2 print(count(m), has_key(m, \"x\"), has_key(m, \"z\"), join(keys(m), \",\"))", "2\ttrue\tfalse\tx,y\n");
    try f.expectOutput("local e = {} print(count(e), #keys(e)) sort(e)", "0\t0\n");
    try f.expectStop("sort({1, \"a\"})", .type);
    try f.expectStop("sort({true})", .type);
    try f.expectStop("count(\"s\")", .type);
    try f.expectStop("push({a = 1}, 2)", .type);
    try f.expectStop("push({}, nil)", .type);
    try f.expectStop("has_key({a = 1}, 1)", .type);
}

test "builtins: every builtin's work is charged, so one call cannot hide a million bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A string of a million bytes built in twenty doublings, then searched:
    // the steps the search takes are counted. The build alone, measured,
    // then the build and the search with half a million steps to spare.
    var built = f.run("local s = \"x\" for i = 1, 20 do s = s .. s end", .{});
    defer built.deinit();
    try testing.expect(built.finished());
    var r = f.run("local s = \"x\" for i = 1, 20 do s = s .. s end print(contains(s, \"y\"))", .{ .steps = built.steps + 500_000 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
}

test "builtins: a change on the disk is in the effects log, however little arena is left (every limit swept)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    var finished: usize = 0;
    var stopped_by_arena: usize = 0;
    var limit: usize = 0;
    while (limit <= 32 * 1024) : (limit += 8) {
        var r = f.run("replace(\"x.txt\", \"v\")", .{ .arena_bytes = limit });
        defer r.deinit();
        if (r.finished()) finished += 1;
        if (r.stop) |s| if (s.budget == .arena) {
            stopped_by_arena += 1;
        };
        const on_disk = (f.tmp.dir.statFile(io, "data/x.txt", .{}) catch null) != null;
        if (on_disk) {
            try testing.expectEqual(@as(usize, 1), r.effects.len);
            try testing.expectEqualStrings("x.txt", r.effects[0].path);
            try f.tmp.dir.deleteFile(io, "data/x.txt");
        }
    }
    // Not vacuous: the sweep crossed from too little to enough.
    try testing.expect(finished > 0 and stopped_by_arena > 0);
}

// ── v31's builtins (metal-vmm QUEUE 206) ──────────────────────────────────

test "builtins: walk lists every entry under a folder, depth first and sorted, for one read a folder" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("for e in walk(\"\") do print(e.path, e.size, e.kind) end", "chat\t0\tdirectory\nchat/a.md\t5\tfile\nchat/b.md\t6\tfile\ntop.txt\t3\tfile\n");
    try f.expectOutput("for e in walk(\"chat\") do print(e.path) end", "chat/a.md\nchat/b.md\n");
    try f.expectOutput("local w = walk(\"\") print(w[2].modified > 1000000000)", "true\n");
    // Two folders, two reads: the root and chat.
    {
        var r = f.run("print(#walk(\"\"))", .{ .reads = 2 });
        defer r.deinit();
        try testing.expect(r.finished());
    }
    {
        var r = f.run("print(#walk(\"\"))", .{ .reads = 1 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.reads, r.stop.?.budget.?);
    }
    try f.expectStop("walk(\"nope\")", .store);
    // A symlink is listed as other and never entered: one to / doesn't walk
    // the host, and one to its own folder doesn't loop.
    try f.tmp.dir.symLink(f.threaded.io(), "/", "data/chat/host", .{});
    try f.tmp.dir.symLink(f.threaded.io(), ".", "data/chat/loop", .{});
    try f.expectOutput("for e in walk(\"chat\") do print(e.path, e.size, e.kind) end", "chat/a.md\t5\tfile\nchat/b.md\t6\tfile\nchat/host\t0\tother\nchat/loop\t0\tother\n");
    try f.expectStop("walk(\"top.txt\")", .store);
    try f.expectStop("walk(\"../auth\")", .argument);
}

test "builtins: budget says what is left of each budget" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("local b = budget() print(b.reads, b.read_bytes, b.changes, b.change_bytes)", "10000\t67108864\t1000\t16777216\n");
    try f.expectOutput("print(exists(\"top.txt\")) print(budget().reads) read(\"top.txt\") print(budget().read_bytes)", "true\n9999\n67108861\n");
    try f.expectOutput("local a = budget().steps local c = budget().steps print(a > c, a <= 5000000)", "true\ttrue\n");
    try f.expectOutput("print(\"ab\") print(budget().output)", "ab\n65533\n");
}

test "builtins: lines without a last empty piece, words, and count on a list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(#lines(\"a\\nb\\nc\\n\"), #lines(\"a\\nb\\nc\"), #lines(\"\"), #lines(\"\\n\"), join(lines(\"x\\n\\ny\\n\"), \"|\"))", "3\t3\t0\t1\tx||y\n");
    try f.expectOutput("print(#words(\"  the quick\\tbrown\\n\\nfox  \"), join(words(\"a b\"), \",\"), #words(\"\"), #words(\" \\n\"))", "4\ta,b\t0\t0\n");
    try f.expectOutput("print(count({1, 2, 3}), count({}), count({a = 1}))", "3\t0\t1\n");
    try f.expectStop("lines(1)", .type);
    try f.expectStop("words({})", .type);
}

test "builtins: sort by a key keeps equal keys in order; reverse" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rows = "local rows = {{n = \"b\", v = 2}, {n = \"a\", v = 2}, {n = \"c\", v = 1}} ";
    const names = " local o = {} for r in rows do push(o, r.n) end print(join(o, \",\"))";
    try f.expectOutput(rows ++ "sort(rows, \"v\")" ++ names, "c,b,a\n");
    try f.expectOutput(rows ++ "sort(rows, \"n\")" ++ names, "a,b,c\n");
    try f.expectOutput(rows ++ "sort(rows, \"v\") reverse(rows)" ++ names, "a,b,c\n");
    try f.expectOutput("local l = {1, 2, 3} reverse(l) print(join(l, \",\")) local e = {} reverse(e) sort(e, \"k\") print(#e)", "3,2,1\n0\n");
    try f.expectStop("sort({{v = 1}, {w = 2}}, \"v\")", .index);
    try f.expectStop("sort({{v = 1}, {v = \"x\"}}, \"v\")", .type);
    try f.expectStop("sort({1, 2}, \"v\")", .type);
    try f.expectStop("sort({{v = 1}}, 1)", .type);
    try f.expectStop("reverse({a = 1})", .type);
}

test "builtins: date and seconds, each the other's inverse, in UTC" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(date(0), date(1700000000), date(951782400), date(253402300799))", "1970-01-01T00:00:00Z\t2023-11-14T22:13:20Z\t2000-02-29T00:00:00Z\t9999-12-31T23:59:59Z\n");
    try f.expectOutput("print(seconds(\"2023-11-14T22:13:20Z\"), seconds(\"2000-02-29\"), seconds(\"2026-10-14T03:00:00+02:00\"), seconds(\"2026-10-14T03:00:00.123Z\"), seconds(\"2026-10-14T01:00:00-02:00\"))", "1700000000\t951782400\t1791939600\t1791946800\t1791946800\n");
    try f.expectOutput("local ok = true for s = 0, 4000000000, 37777777 do if seconds(date(s)) ~= s then ok = false end end print(ok)", "true\n");
    const bad = [_][]const u8{ "seconds(\"2023-02-29\")", "seconds(\"2026-10-14T03:00:00\")", "seconds(\"x\")", "seconds(\"2026-13-01\")", "seconds(\"2026-10-14T24:00:00Z\")", "seconds(\"2026-10-14 03:00:00Z\")", "seconds(\"2026-10-14T03:00:00+2:00\")", "date(-1)", "date(253402300800)" };
    for (bad) |src| try f.expectStop(src, .argument);
    try f.expectStop("seconds(1)", .type);
}

test "builtins: human sizes, pad either way, and a table of rows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(human(0), human(1023), human(1024), human(1536), human(5000), human(1048575), human(-2048), human(9223372036854775807))", "0 B\t1023 B\t1.0 KiB\t1.5 KiB\t4.9 KiB\t1.0 MiB\t-2.0 KiB\t8.0 EiB\n");
    try f.expectOutput("print(\"[\" .. pad(\"ab\", 5) .. \"]\", \"[\" .. pad(42, -5) .. \"]\", \"[\" .. pad(\"toolong\", 3) .. \"]\", \"[\" .. pad(\"\", 0) .. \"]\")", "[ab   ]\t[   42]\t[toolong]\t[]\n");
    try f.expectOutput(
        "local rows = {{name = \"chat\", files = 12, bytes = \"1.2 KiB\"}, {name = \"games\", files = 3, bytes = \"5 B\"}} print(table(rows, {\"name\", \"files\", \"bytes\"}))",
        "name   files  bytes\nchat      12  1.2 KiB\ngames      3  5 B\n",
    );
    try f.expectOutput("print(table({}, {\"a\", \"b\"}))", "a  b\n");
    // Every cell costs a step, empty or not, before the grid is made.
    {
        const src = "local m = {[\"\"] = \"\"} local rows = {} local cols = {} for i = 1, 3000 do push(rows, m) push(cols, \"\") end print(#table(rows, cols))";
        var r = f.run(src, .{ .steps = 1_000_000 });
        defer r.deinit();
        try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
    }
    try f.expectStop("table({{a = 1}}, {\"a\", \"b\"})", .index);
    try f.expectStop("table({{a = {}}}, {\"a\"})", .type);
    try f.expectStop("table({1}, {\"a\"})", .type);
    try f.expectStop("pad({}, 3)", .type);
    try f.expectStop("human(\"1\")", .type);
}

test "builtins: like, with * and ? only, the whole string" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(like(\"a.md\", \"*.md\"), like(\"a.md\", \"*.txt\"), like(\"abc\", \"a?c\"), like(\"ac\", \"a?c\"), like(\"\", \"*\"), like(\"x\", \"\"), like(\"aaa\", \"a*a*a\"), like(\"ab\", \"a*b*\"), like(\"a.md.bak\", \"*.md\"), like(\"[x]\", \"[x]\"))", "true\tfalse\ttrue\tfalse\ttrue\tfalse\ttrue\ttrue\tfalse\ttrue\n");
    // Its work is charged: a long string against a pattern that backtracks.
    var r = f.run("local s = \"a\" for i = 1, 16 do s = s .. s end print(like(s, \"*" ++ "a" ** 39 ++ "b\"))", .{ .steps = 400_000 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
}

// ── 208(b): reading part of a file, scanning one, walking with options ───

test "builtins: read(p, offset, n) reads only the part, 0-based, clamped at the end, and counts only those bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(read(\"chat/a.md\", 1, 3), read(\"chat/a.md\", 3), \"[\" .. read(\"chat/a.md\", 5, 2) .. read(\"chat/a.md\", 99) .. \"]\", read(\"chat/a.md\", 0, 0) == \"\")", "ell\tlo\t[]\ttrue\n");
    try f.expectStop("print(read(\"chat/a.md\", -1, 2))", .argument);
    try f.expectStop("print(read(\"chat/a.md\", 0, -2))", .argument);
    try f.expectStop("print(read(\"chat\", 0, 2))", .store);
    try f.expectStop("print(read(\"chat/none.md\", 0, 2))", .store);
    // Three bytes of budget: a part of three reads, of four stops; the
    // whole file (five) would have too.
    var ok = f.run("print(read(\"chat/a.md\", 1, 3))", .{ .read_bytes = 3 });
    defer ok.deinit();
    try testing.expect(ok.finished());
    var over = f.run("print(read(\"chat/a.md\", 0, 4))", .{ .read_bytes = 3 });
    defer over.deinit();
    try testing.expectEqual(script.diag.Budget.read_bytes, over.stop.?.budget.?);
}

/// A file of `n` pseudo-random bytes from a small alphabet, so short
/// needles match often, on every seam of the scan's chunks too.
fn plantedFile(f: *Fixture, sub: []const u8, n: usize, seed: u64) ![]u8 {
    const data = try testing.allocator.alloc(u8, n);
    var prng: std.Random.DefaultPrng = .init(seed);
    for (data) |*c| c.* = "ab\n"[prng.random().uintLessThan(u8, 3)];
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = sub, .data = data });
    return data;
}

test "builtins: count_in, find_in and count_lines agree with the whole file's own counts, across every chunk's seam, in a fraction of its size in arena" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // Three and a bit chunks of 64 KiB, so matches straddle seams.
    const data = try plantedFile(&f, "data/big.txt", 3 * 65536 + 1234, 7);
    defer testing.allocator.free(data);
    for ([_][]const u8{ "a", "ab", "aab", "\nb\n", "abba", "bbbbbbbb" }) |needle| {
        var src: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&src, "print(count_in(\"big.txt\", \"{s}\"), find_in(\"big.txt\", \"{s}\"))", .{ needle, needle });
        const esc = try std.mem.replaceOwned(u8, testing.allocator, s, "\n", "\\n");
        defer testing.allocator.free(esc);
        var r = f.run(esc, .{});
        defer r.deinit();
        try testing.expect(r.finished());
        var want: [64]u8 = undefined;
        const first = std.mem.indexOf(u8, data, needle);
        const w = if (first) |i| try std.fmt.bufPrint(&want, "{d}\t{d}\n", .{ std.mem.count(u8, data, needle), i }) else try std.fmt.bufPrint(&want, "0\tnil\n", .{});
        testing.expectEqualStrings(w, r.output) catch |e| {
            std.debug.print("needle {s}\n", .{needle});
            return e;
        };
        try testing.expect(r.arena_bytes < 160 * 1024);
    }
    // Long runs of `a`: every seam falls inside a run, so a count of
    // `aaa` (none overlapping) depends on each seam carried right.
    const runs = try testing.allocator.alloc(u8, 3 * 65536 + 777);
    defer testing.allocator.free(runs);
    var prng: std.Random.DefaultPrng = .init(11);
    var i: usize = 0;
    while (i < runs.len) : (i += 1) runs[i] = if (prng.random().uintLessThan(u16, 300) == 0) 'b' else 'a';
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/runs.txt", .data = runs });
    // And one run of `a` from end to end: the first window (64 KiB and two)
    // ends on a match of `aaa` exactly, which must not be counted again.
    const solid = try testing.allocator.alloc(u8, 2 * 65536 + 5);
    defer testing.allocator.free(solid);
    @memset(solid, 'a');
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/solid.txt", .data = solid });
    try f.expectOutput("print(count_in(\"solid.txt\", \"aaa\"), count_in(\"solid.txt\", \"aa\"), find_in(\"solid.txt\", \"aaaa\"))", "43692\t65538\t0\n");
    for ([_][]const u8{ "aaa", "aaaaaaa", "ab", "ba", "aba" }) |needle| {
        var src: [256]u8 = undefined;
        var r = f.run(try std.fmt.bufPrint(&src, "print(count_in(\"runs.txt\", \"{s}\"))", .{needle}), .{});
        defer r.deinit();
        var want: [32]u8 = undefined;
        testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}\n", .{std.mem.count(u8, runs, needle)}), r.output) catch |e| {
            std.debug.print("needle {s}\n", .{needle});
            return e;
        };
    }
    var lines = f.run("print(count_lines(\"big.txt\"), #lines(read(\"big.txt\")))", .{});
    defer lines.deinit();
    const nl = std.mem.count(u8, data, "\n") + @intFromBool(data[data.len - 1] != '\n');
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}\t{d}\n", .{ nl, nl }), lines.output);
    // Empty files and needles.
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/empty", .data = "" });
    try f.expectOutput("print(count_lines(\"empty\"), count_in(\"empty\", \"x\"), find_in(\"empty\", \"x\"), count_lines(\"top.txt\"))", "0\t0\tnil\t1\n");
    try f.expectStop("print(count_in(\"top.txt\", \"\"))", .argument);
}

test "builtins: a scan is one store read, every byte counted against the read budget and charged a step" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const data = try plantedFile(&f, "data/big.txt", 200_000, 9);
    defer testing.allocator.free(data);
    var r = f.run("print(count_lines(\"big.txt\")) print(budget().reads, budget().read_bytes)", .{ .reads = 10, .read_bytes = 1_000_000 });
    defer r.deinit();
    try testing.expect(std.mem.endsWith(u8, r.output, "\t800000\n") and std.mem.indexOf(u8, r.output, "\n9\t") != null);
    try testing.expect(r.steps > 200_000);
    var over = f.run("print(count_lines(\"big.txt\"))", .{ .read_bytes = 150_000 });
    defer over.deinit();
    try testing.expectEqual(script.diag.Budget.read_bytes, over.stop.?.budget.?);
}

test "builtins: walk's options: depth stops it and reads fewer folders, like and kind keep the entries that match, unknown options are refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    try f.tmp.dir.createDirPath(io, "data/chat/deep/deeper");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/deep/deeper/c.md", .data = "x" });
    try f.expectOutput("for e in walk(\"\", {depth = 1}) do print(e.path, e.kind, e.size) end", "chat\tdirectory\t0\ntop.txt\tfile\t3\n");
    try f.expectOutput("for e in walk(\"chat\", {like = \"*.md\"}) do print(e.path) end", "chat/a.md\nchat/b.md\nchat/deep/deeper/c.md\n");
    try f.expectOutput("for e in walk(\"\", {kind = \"directory\", depth = 2}) do print(e.path) end", "chat\nchat/deep\n");
    // depth 1 is one folder read; the whole walk is four.
    var shallow = f.run("local w = walk(\"\", {depth = 1}) print(10 - budget().reads)", .{ .reads = 10 });
    defer shallow.deinit();
    try testing.expectEqualStrings("1\n", shallow.output);
    var whole = f.run("local w = walk(\"\") print(10 - budget().reads)", .{ .reads = 10 });
    defer whole.deinit();
    try testing.expectEqualStrings("4\n", whole.output);
    try f.expectStop("local w = walk(\"\", {deep = 1})", .argument);
    try f.expectStop("local w = walk(\"\", {depth = 0})", .argument);
    try f.expectStop("local w = walk(\"\", {kind = \"link\"})", .argument);
    try f.expectStop("local w = walk(\"\", {1, 2})", .type);
}
