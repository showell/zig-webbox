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
    try f.expectStop("count({1})", .type);
    try f.expectStop("push({a = 1}, 2)", .type);
    try f.expectStop("push({}, nil)", .type);
    try f.expectStop("has_key({a = 1}, 1)", .type);
}

test "builtins: every builtin's work is charged, so one call cannot hide a million bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A string of a million bytes built in twenty doublings, then searched:
    // the steps the search takes are counted.
    var r = f.run("local s = \"x\" for i = 1, 20 do s = s .. s end print(contains(s, \"y\"))", .{ .steps = 2_500_000 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.steps, r.stop.?.budget.?);
}
