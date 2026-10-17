//! The builtins against a real store in a temporary folder.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;
const Io = std.Io;

var out_buf: [64 * 1024]u8 = undefined;

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,
    base: []const u8,

    pub fn init(self: *Fixture) !void {
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

    pub fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    pub fn run(self: *Fixture, src: []const u8, budgets: script.Budgets) script.Result {
        return script.run(self.threaded.io(), testing.allocator, self.root, src, budgets, 0, &out_buf);
    }

    pub fn expectOutput(self: *Fixture, src: []const u8, want: []const u8) !void {
        var r = self.run(src, .{});
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(want, r.output);
    }

    pub fn expectStop(self: *Fixture, src: []const u8, class: script.diag.Class) !void {
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

    pub fn file(self: *Fixture, sub: []const u8) ![]u8 {
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
    // the steps the search takes are counted (a step for 16 bytes: 65,536
    // for the million). The build alone, measured, then the build and the
    // search with 30,000 steps to spare.
    var built = f.run("local s = \"x\" for i = 1, 20 do s = s .. s end", .{});
    defer built.deinit();
    try testing.expect(built.finished());
    var r = f.run("local s = \"x\" for i = 1, 20 do s = s .. s end print(contains(s, \"y\"))", .{ .steps = built.steps + 30_000 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
}

test "expensive sweep: builtins: a change on the disk is in the effects log, however little arena is left (every limit swept)" {
    if (!@import("script_test_options").expensive) return error.SkipZigTest;
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

test "builtins: walk lists every entry under a folder, depth first and sorted, for one read a folder and one an entry's stat" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("for e in walk(\"\") do print(e.path, e.size, e.kind) end", "chat\t0\tdirectory\nchat/a.md\t5\tfile\nchat/b.md\t6\tfile\ntop.txt\t3\tfile\n");
    try f.expectOutput("for e in walk(\"chat\") do print(e.path) end", "chat/a.md\nchat/b.md\n");
    try f.expectOutput("local w = walk(\"\") print(w[2].modified > 1000000000)", "true\n");
    // Two folders and four entries, six reads.
    {
        var r = f.run("print(#walk(\"\"))", .{ .reads = 6 });
        defer r.deinit();
        try testing.expect(r.finished());
    }
    {
        var r = f.run("print(#walk(\"\"))", .{ .reads = 5 });
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
    const data = try plantedFile(&f, "data/big.txt", 8 * 65536 + 1234, 7);
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
        // Half a megabyte scanned in the scan buffer (128 KiB) and change.
        testing.expect(r.arena_bytes < 320 * 1024) catch |e| {
            std.debug.print("held {d}\n", .{r.arena_bytes});
            return e;
        };
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

test "builtins: a scan is one store read, every byte counted against the read budget, and charged a step for 16" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const data = try plantedFile(&f, "data/big.txt", 200_000, 9);
    defer testing.allocator.free(data);
    var r = f.run("print(count_lines(\"big.txt\")) print(budget().reads, budget().read_bytes)", .{ .reads = 10, .read_bytes = 1_000_000 });
    defer r.deinit();
    try testing.expect(std.mem.endsWith(u8, r.output, "\t800000\n") and std.mem.indexOf(u8, r.output, "\n9\t") != null);
    // 200,000 bytes at a step for 16.
    try testing.expect(r.steps > 200_000 / 16);
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
    // depth 1 is one folder read and its two entries' stats; the whole
    // walk is four folders and seven stats.
    var shallow = f.run("local w = walk(\"\", {depth = 1}) print(10 - budget().reads)", .{ .reads = 10 });
    defer shallow.deinit();
    try testing.expectEqualStrings("3\n", shallow.output);
    var whole = f.run("local w = walk(\"\") print(20 - budget().reads)", .{ .reads = 20 });
    defer whole.deinit();
    try testing.expectEqualStrings("11\n", whole.output);
    try f.expectStop("local w = walk(\"\", {deep = 1})", .argument);
    try f.expectStop("local w = walk(\"\", {depth = 0})", .argument);
    try f.expectStop("local w = walk(\"\", {kind = \"link\"})", .argument);
    try f.expectStop("local w = walk(\"\", {1, 2})", .type);
}

// ── 208(c): the small gaps a real script hits ────────────────────────────

test "builtins: min, max and abs; rep and substitute, plain text, charged before they make the string" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(min(3, -1), max(3, -1, 7, 2), abs(-5), abs(0))", "-1\t7\t5\t0\n");
    try f.expectStop("print(abs(-9223372036854775807 - 1))", .arithmetic);
    try f.expectStop("print(min(1, \"2\"))", .type);
    try f.expectStop("print(max(1))", .argument);
    try f.expectOutput("print(rep(\"ab\", 3), #rep(\"x\", 0), substitute(\"a.b.c\", \".\", \"::\"), substitute(\"aaa\", \"aa\", \"b\"), substitute(\"abc\", \"z\", \"y\"))", "ababab\t0\ta::b::c\tba\tabc\n");
    try f.expectStop("print(rep(\"x\", -1))", .argument);
    try f.expectStop("print(substitute(\"abc\", \"\", \"y\"))", .argument);
    // A hundred million bytes asked for: the steps run out before the
    // arena is asked.
    var r = f.run("local s = rep(\"0123456789\", 10000000)", .{});
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
    try testing.expect(r.arena_bytes < 1024 * 1024);
}

test "builtins: seconds gives only what date can write: 1970 to 9999" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(seconds(\"1970-01-01\"), date(seconds(\"9999-12-31T23:59:59Z\")))", "0\t9999-12-31T23:59:59Z\n");
    try f.expectStop("print(seconds(\"1969-12-31T23:59:59Z\"))", .argument);
    try f.expectStop("print(seconds(\"1970-01-01T00:30:00+01:00\"))", .argument);
    try f.expectStop("print(seconds(\"0000-01-01\"))", .argument);
}

// ── 208's cold review ────────────────────────────────────────────────────

test "builtins: a search pays for its matches and its compares: dense matches cost at least a step each (209's cold review)" {
    // Before, substitute(s, "a", "") over a megabyte of `a` charged 65,536
    // steps for a million matches, twice searched: 661 ms in the site's
    // 2M. count_lines on a file of newlines, the same.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const nl = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(nl);
    @memset(nl, '\n');
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/nl.txt", .data = nl });
    const cases = [_]struct { setup: []const u8, call: []const u8, matches: u64 }{
        .{ .setup = "local s = rep(\"a\", 100000)", .call = "local x = substitute(s, \"a\", \"\")", .matches = 2 * 100_000 },
        .{ .setup = "local s = rep(\"ab\", 50000)", .call = "local x = #split(s, \"b\")", .matches = 50_000 },
        .{ .setup = "", .call = "local x = count_lines(\"nl.txt\")", .matches = 100_000 },
        .{ .setup = "", .call = "local x = count_in(\"nl.txt\", \"\\n\")", .matches = 100_000 },
        // A near-match at every byte: the compares are paid.
        .{ .setup = "local s = rep(\"a\", 100000)", .call = "local x = find(s, rep(\"a\", 63) .. \"b\")", .matches = 100_000 },
    };
    for (cases) |c| {
        var setup = f.run(c.setup, .{});
        defer setup.deinit();
        var src: [512]u8 = undefined;
        var r = f.run(try std.fmt.bufPrint(&src, "{s}\n{s}", .{ c.setup, c.call }), .{ .steps = 100_000_000 });
        defer r.deinit();
        try testing.expect(r.finished());
        errdefer std.debug.print("{s}: {d} steps\n", .{ c.call, r.steps - setup.steps });
        try testing.expect(r.steps - setup.steps >= c.matches);
    }
}

test "builtins: a long near-match needle pays for its compares: each search stops at the step budget, quickly, instead of running for seconds" {
    // At 208's first cut each of these did haystack x needle work for a
    // step a haystack byte: tens of seconds inside the budget. Now every
    // compare is charged, so the budget ends each one soon. The sizes keep
    // the two apart: the setup takes about 12,000 steps, a search charged
    // per compare about 572,000, one charged per haystack byte (the bug)
    // about 22,000, and the budget is 50,000.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const big = try testing.allocator.alloc(u8, 10_000);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/as.txt", .data = big });
    const calls = [_][]const u8{ "find(hay, needle)", "contains(hay, needle)", "substitute(hay, needle, \"x\")", "split(hay, needle)", "count_in(\"as.txt\", needle)", "find_in(\"as.txt\", needle)" };
    for (calls) |call| {
        var src: [256]u8 = undefined;
        var r = f.run(try std.fmt.bufPrint(&src, "local hay = rep(\"a\", 10000) local needle = rep(\"a\", 1000) .. \"b\" local x = {s}", .{call}), .{ .steps = 50_000 });
        defer r.deinit();
        errdefer std.debug.print("{s}\n", .{call});
        try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
    }
    // Matches found where they are.
    try f.expectOutput("print(count_in(\"as.txt\", rep(\"a\", 1000)), find(rep(\"ab\", 5), \"bab\"))", "10\t2\n");
}

test "builtins: every scan of a run reuses one buffer: five hundred files scanned cost no more arena than one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    try f.tmp.dir.createDirPath(io, "data/many");
    const body = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    for (0..20) |i| {
        var name: [32]u8 = undefined;
        try f.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "data/many/f{d}", .{i}), .data = body });
    }
    var r = f.run("local n = 0 for k = 1, 25 do for e in walk(\"many\") do n = n + count_in(e.path, \"y\") end end print(n)", .{ .steps = 100_000_000 });
    defer r.deinit();
    try testing.expect(r.finished());
    try testing.expect(r.arena_bytes < 2 * 1024 * 1024);
}

test "builtins: a store error is never read as missing: a remove that can't look names the store's own error (209(a))" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    // A link that loops: stat fails with SymLinkLoop, not FileNotFound.
    try f.tmp.dir.symLink(io, "loop", "data/loop", .{});
    var r = f.run("remove(\"loop/x\")", .{});
    defer r.deinit();
    try testing.expectEqual(script.diag.Class.store, r.stop.?.class);
    try testing.expectEqual(@as(usize, 1), r.effects.len);
    try testing.expect(!std.mem.eql(u8, "FileNotFound", r.effects[0].outcome));
    try testing.expect(std.mem.indexOf(u8, r.stop.?.message, r.effects[0].outcome) != null);
    // What isn't there is still missing.
    var m = f.run("remove(\"chat/none.md\")", .{});
    defer m.deinit();
    try testing.expectEqualStrings("FileNotFound", m.effects[0].outcome);
}

test "builtins: one read brings at most its cap, whole or in part; a bigger file is read in parts (metal-vmm QUEUE 211, the caps)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const big = try testing.allocator.alloc(u8, 3000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/big.txt", .data = big });
    const capped: script.Budgets = .{ .call_bytes = 1000 };
    for ([_][]const u8{ "read(\"big.txt\")", "read(\"big.txt\", 100)", "read(\"big.txt\", 0, 1001)" }) |src| {
        var r = f.run(src, capped);
        defer r.deinit();
        errdefer std.debug.print("{s}: {?}\n", .{ src, r.stop });
        try testing.expectEqual(script.diag.Class.argument, r.stop.?.class);
        try testing.expect(std.mem.indexOf(u8, r.stop.?.message, "read(p, offset, n)") != null);
    }
    // In parts, under the cap: the whole of it.
    var r = f.run("local n = 0 local at = 0 while true do local part = read(\"big.txt\", at, 1000) if part == \"\" then break end n = n + #part at = at + #part end print(n)", capped);
    defer r.deinit();
    try testing.expect(r.finished());
    try testing.expectEqualStrings("3000\n", r.output);
}

test "builtins: a scan takes at most its cap too; in parts, by its range, it counts and finds as the whole file does (metal-vmm QUEUE 211, the caps)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const data = try plantedFile(&f, "data/big.txt", 5000, 3);
    defer testing.allocator.free(data);
    const capped: script.Budgets = .{ .call_bytes = 700 };
    // The whole file, or a range past the cap, is refused, naming the range.
    for ([_][]const u8{ "count_lines(\"big.txt\")", "count_in(\"big.txt\", \"ab\")", "find_in(\"big.txt\", \"ab\")", "count_lines(\"big.txt\", 0, 701)", "find_in(\"big.txt\", \"ab\", 100)" }) |call| {
        var src: [128]u8 = undefined;
        var r = f.run(try std.fmt.bufPrint(&src, "print({s})", .{call}), capped);
        defer r.deinit();
        const s = r.stop orelse return error.TestUnexpectedResult;
        try testing.expectEqual(script.diag.Class.argument, s.class);
        try testing.expect(std.mem.indexOf(u8, s.message, "offset, n)") != null);
    }
    // In parts of 700: the counts add up to the whole's, and the first
    // match is found in the part it starts in, read past the part's end.
    var r = f.run(
        \\local size = stat("big.txt").size
        \\local lines = 0
        \\local abs = 0
        \\local first = nil
        \\local at = 0
        \\while at < size do
        \\  lines = lines + count_lines("big.txt", at, 700)
        \\  abs = abs + count_in("big.txt", "ab", at, 700)
        \\  if first == nil then first = find_in("big.txt", "b\na\nb", at, 700) end
        \\  at = at + 700
        \\end
        \\print(lines, abs, first)
    , capped);
    defer r.deinit();
    if (r.stop) |s| std.debug.print("stopped: {s}\n", .{s.message});
    try testing.expect(r.finished());
    var want: [64]u8 = undefined;
    const nl = std.mem.count(u8, data, "\n") + @intFromBool(data[data.len - 1] != '\n');
    const first = std.mem.indexOf(u8, data, "b\na\nb").?;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}\t{d}\t{d}\n", .{ nl, std.mem.count(u8, data, "ab"), first }), r.output);
    // A match across a part's end belongs to the part it starts in.
    var seam: [1400]u8 = undefined;
    @memset(&seam, 'x');
    @memcpy(seam[699..701], "ab");
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/seam.txt", .data = &seam });
    var s = f.run("print(find_in(\"seam.txt\", \"ab\", 0, 700), find_in(\"seam.txt\", \"ab\", 700, 700), count_in(\"seam.txt\", \"ab\", 0, 700), count_in(\"seam.txt\", \"ab\", 700, 700), count_lines(\"seam.txt\", 0, 700), count_lines(\"seam.txt\", 700, 700), find_in(\"seam.txt\", \"ab\", 5000, 10))", capped);
    defer s.deinit();
    try testing.expectEqualStrings("699\tnil\t1\t0\t0\t1\tnil\n", s.output);
}

/// What the walk-vanish test removes between a listing and its stat.
var vanish_path: ?[]const u8 = null;
var vanish_io: std.Io = undefined;

fn vanishOnce() void {
    const p = vanish_path orelse return;
    vanish_path = null;
    std.Io.Dir.cwd().deleteFile(vanish_io, p) catch {};
}

test "builtins: walk's stats count as reads, a call considers at most call_entries, and a walk in parts by `after` gives the whole walk's entries (metal-vmm QUEUE 211, the caps)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    try f.tmp.dir.createDirPath(io, "data/chat/deep/deeper");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/deep/deeper/c.md", .data = "x" });
    // Four folders listed and seven entries stat'ed.
    var reads = f.run("local w = walk(\"\") print(20 - budget().reads)", .{ .reads = 20 });
    defer reads.deinit();
    try testing.expectEqualStrings("11\n", reads.output);
    // In parts of at most two entries, every option the same: the whole.
    const parts =
        \\function all(opts_kind)
        \\  local got = {}
        \\  local after = ""
        \\  while true do
        \\    local part = nil
        \\    if opts_kind == "" then part = walk("", {after = after}) else part = walk("", {after = after, kind = opts_kind}) end
        \\    local more = nil
        \\    for e in part do
        \\      if e.kind == "more" then more = e.path else push(got, e.path) end
        \\    end
        \\    if more == nil then return join(got, ",") end
        \\    after = more
        \\  end
        \\end
        \\print(all(""))
        \\print(all("file"))
    ;
    var whole = f.run(parts, .{});
    defer whole.deinit();
    try testing.expectEqualStrings("chat,chat/a.md,chat/b.md,chat/deep,chat/deep/deeper,chat/deep/deeper/c.md,top.txt\nchat/a.md,chat/b.md,chat/deep/deeper/c.md,top.txt\n", whole.output);
    var cut = f.run(parts, .{ .call_entries = 2 });
    defer cut.deinit();
    if (cut.stop) |s| std.debug.print("{s}\n", .{s.message});
    try testing.expectEqualStrings(whole.output, cut.output);
    // A part is the cap's entries and where to go on from.
    var part = f.run("local w = walk(\"\") print(#w, w[#w].kind, w[#w].path)", .{ .call_entries = 2 });
    defer part.deinit();
    try testing.expectEqualStrings("3\tmore\tchat/a.md\n", part.output);
    // `after` is a place in the walk's order, there or not.
    try f.expectOutput("for e in walk(\"\", {after = \"chat/aa.md\"}) do print(e.path) end", "chat/b.md\nchat/deep\nchat/deep/deeper\nchat/deep/deeper/c.md\ntop.txt\n");
    try f.expectOutput("for e in walk(\"chat\", {after = \"chat/deep\"}) do print(e.path) end", "chat/deep/deeper\nchat/deep/deeper/c.md\n");
    try f.expectStop("walk(\"chat\", {after = \"top.txt\"})", .argument);
    // An entry gone between its folder's listing and its stat: a background
    // run, which only reads while others write, goes on without it; an
    // atomic one, which holds the turn, says so.
    const b_md = try std.fs.path.join(testing.allocator, &.{ f.root, "chat", "b.md" });
    defer testing.allocator.free(b_md);
    script.builtins_walk.between_list_and_stat_for_test = vanishOnce;
    defer script.builtins_walk.between_list_and_stat_for_test = null;
    vanish_io = io;
    for ([_]script.process.Mode{ .background, .atomic }) |mode| {
        try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/b.md", .data = "world!" });
        vanish_path = b_md;
        const p = try script.process.Process.start(io, testing.allocator, f.root, "for e in walk(\"chat\", {depth = 1}) do print(e.path) end", mode, .{}, 0, 4096);
        defer p.kill();
        while (p.step(.{}) == .paused) {}
        switch (mode) {
            .background => try testing.expectEqualStrings("chat/a.md\nchat/deep\n", p.output()),
            .atomic => try testing.expectEqual(script.diag.Class.store, p.status().stop.?.class),
            .dry_run => unreachable,
        }
    }
}

test "builtins: an empty needle is found where the search starts, never a crash: find and contains, as Lua's find (220's cold read found the panic)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(find(\"abc\", \"\"), contains(\"abc\", \"\"), find(\"\", \"\"), contains(\"\", \"\"))", "1\ttrue\t1\ttrue\n");
    try f.expectStop("split(\"abc\", \"\")", .argument);
    try f.expectStop("substitute(\"abc\", \"\", \"x\")", .argument);
}

// ── 229, chunk 3: lenient reads ──────────────────────────────────────────

test "builtin: parse_int reads an integer from real data, or gives nil, where tonumber stops the run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(parse_int(\"42\"), parse_int(\" -7\\r\\n\"), parse_int(\"log-x\"), parse_int(\"\"), parse_int(\"12a\"))", "42\t-7\tnil\tnil\tnil\n");
    try f.expectOutput("print(parse_int(nil), parse_int(5), parse_int(\"99999999999999999999\"))", "nil\t5\tnil\n");
    try f.expectStop("print(parse_int({}))", .type);
}

test "builtin: get gives a map's value or a list's item, and the default where there is none" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("local m = {a = 1} print(get(m, \"a\", 0), get(m, \"b\", 0), get({}, \"x\", \"none\"))", "1\t0\tnone\n");
    try f.expectOutput("local l = {\"x\", \"y\"} print(get(l, 2, \"-\"), get(l, 3, \"-\"), get(l, 0, \"-\"), get(l, 1))", "y\t-\t-\tx\n");
    try f.expectOutput("print(get({a = 1}, \"b\"))", "nil\n");
    try f.expectStop("print(get({a = 1}, 1, 0))", .type);
    try f.expectStop("print(get(5, \"a\", 0))", .type);
}

test "builtin: read_lines gives whole lines from an offset, where the next part starts, and whether the file is done" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/log.txt", .data = "one\ntwo\nthree\nfour" });
    // At least n bytes, and on to the end of the line it stops in.
    try f.expectOutput("local r = read_lines(\"log.txt\", 0, 5) print(join(r.lines, \",\"), r.next, r.done)", "one,two\t8\tfalse\n");
    try f.expectOutput("local r = read_lines(\"log.txt\", 8, 100) print(join(r.lines, \",\"), r.next, r.done)", "three,four\t18\ttrue\n");
    try f.expectOutput("local r = read_lines(\"log.txt\", 18, 100) print(#r.lines, r.next, r.done)", "0\t18\ttrue\n");
    try f.expectOutput("local r = read_lines(\"log.txt\") print(#r.lines, r.done)", "4\ttrue\n");
    try f.expectStop("local r = read_lines(\"log.txt\", -1, 5)", .argument);
    try f.expectStop("local r = read_lines(\"log.txt\", 0, 0)", .argument);
    try f.expectStop("local r = read_lines(\"none.txt\", 0, 5)", .store);
}

test "builtin: line_at gives the whole line holding an offset, without its newline, or nil past the end" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/log.txt", .data = "one\ntwo\nthree\nfour" });
    try f.expectOutput("print(line_at(\"log.txt\", 0), line_at(\"log.txt\", 5), line_at(\"log.txt\", 7), line_at(\"log.txt\", 3), line_at(\"log.txt\", 17), line_at(\"log.txt\", 18))", "one\ttwo\ttwo\tone\tfour\tnil\n");
    try f.expectStop("print(line_at(\"log.txt\", -1))", .argument);
}

test "builtin: a line longer than one call brings is an error that says so, for read_lines and line_at" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/long.txt", .data = "a\n" ++ "x" ** 300 ++ "\nb\n" });
    var r = f.run("local r = read_lines(\"long.txt\", 2, 10)", .{ .call_bytes = 100 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Class.argument, r.stop.?.class);
    var l = f.run("print(line_at(\"long.txt\", 150))", .{ .call_bytes = 100 });
    defer l.deinit();
    try testing.expectEqual(script.diag.Class.argument, l.stop.?.class);
    var ok = f.run("print(line_at(\"long.txt\", 0), line_at(\"long.txt\", 303))", .{ .call_bytes = 100 });
    defer ok.deinit();
    try testing.expectEqualStrings("a\tb\n", ok.output);
}

test "builtins: re_find and re_match at their edges, and a run's patterns past the cache's eight (QUEUE 230)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The empty pattern matches at the start; `$` alone at the end.
    try f.expectOutput("local m = re_find(\"abc\", \"\") print(m.at, \"[\" .. m.text .. \"]\")", "1\t[]\n");
    try f.expectOutput("local m = re_find(\"abc\", \"$\") print(m.at, \"[\" .. m.text .. \"]\")", "4\t[]\n");
    // Leftmost, then as much as each repetition can take.
    try f.expectOutput("local m = re_find(\"xaab aaab\", \"a+b\") print(m.at, m.text)", "2\taab\n");
    // `^` is the string's start only; `.` takes no newline.
    try f.expectOutput("print(re_match(\"x\\nab\", \"^ab\"), re_match(\"a\\nb\", \"a.b\"), re_match(\"a\\nb\", \"a\\\\sb\"))", "false\tfalse\ttrue\n");
    // A group the match did not go through is ""; a pattern with no group
    // gives no `group`.
    try f.expectOutput("local m = re_find(\"b\", \"(a)?b\") print(\"[\" .. m.group .. \"]\", has_key(re_find(\"b\", \"b\"), \"group\"))", "[]\tfalse\n");
    // A repeated group keeps its last turn; an empty turn ends the loop.
    try f.expectOutput("print(re_find(\"abab\", \"(ab)*\").group, re_find(\"a\", \"(a?)*\").group)", "ab\ta\n");
    // A `]` first in a class is the byte; `\\]` is too.
    try f.expectOutput("print(re_find(\"x]y\", \"[]]\").at, re_find(\"x]y\", \"[^]x]\").text, re_find(\"a]\", \"\\\\]\").at)", "2\ty\t2\n");
    // No match: nil, and `if m` is how it is told.
    try f.expectOutput("local m = re_find(\"abc\", \"d\") if m then print(\"found\") else print(\"none\") end", "none\n");
    // Twelve patterns, each used twice: the cache holds eight, and every
    // search says what it should whichever were put out.
    try f.expectOutput(
        \\local ok = 0
        \\for round = 1, 2 do
        \\  for i = 1, 12 do
        \\    local m = re_find("x" .. rep("a", 12) .. "y", rep("a", i) .. "y$")
        \\    if m.at == 14 - i and #m.text == i + 1 and re_match(rep("a", i), rep("a", i) .. "$") then ok = ok + 1 end
        \\  end
        \\end
        \\print(ok)
    , "24\n");
}

test "builtins: re_find's alternatives, \\b and nocase (the design, final; QUEUE 232)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // `|` is the loosest; the leftmost alternative that matches is taken.
    try f.expectOutput("print(re_find(\"a warning, then an error\", \"error|warning\").text, re_find(\"ab\", \"a|ab\").text, re_find(\"xab\", \"^a|b\").at)", "warning\ta\t3\n");
    // A group around alternatives is the one group.
    try f.expectOutput("print(re_find(\"level=WARN msg\", \"level=(INFO|WARN|ERROR)\").group)", "WARN\n");
    // `\\b`: a word's edge; `\\B` not one.
    try f.expectOutput("print(re_match(\"a cat.\", \"\\\\bcat\\\\b\"), re_match(\"concatenate\", \"\\\\bcat\\\\b\"), re_find(\"concat cat\", \"\\\\Bcat\").at)", "true\tfalse\t4\n");
    // nocase: letters either way; a class folded before its `^`.
    try f.expectOutput("print(re_match(\"FAILED\", \"fail\", {nocase = true}), re_match(\"FAILED\", \"fail\"), re_find(\"Ab\", \"[^a]\", {nocase = true}).text)", "true\tfalse\tb\n");
    // The cache keeps a pattern's two compilations apart.
    try f.expectOutput("print(re_match(\"A\", \"a\"), re_match(\"A\", \"a\", {nocase = true}), re_match(\"A\", \"a\"))", "false\ttrue\tfalse\n");
}
