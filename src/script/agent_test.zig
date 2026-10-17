//! **SHALE AS AN AGENT'S TOOL** (metal-vmm QUEUE 229, chunk 4): what a
//! script needs to work on a code checkout, held through the gate like
//! every other run: its values by name (`arg`), globs (`match_path`, the
//! prelude's `glob`), lines that hold a literal (`grep`), and edits that
//! show their diff, made only when the run may change the store (a dry
//! run logs them).

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

var out_buf: [64 * 1024]u8 = undefined;

const Tree = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,

    fn init(self: *Tree) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        const io = self.threaded.io();
        const d = self.tmp.dir;
        for ([_][]const u8{ "data/src/sub", "data/.zig-cache/o", "data/docs" }) |p| try d.createDirPath(io, p);
        const files = [_][2][]const u8{
            .{ "data/src/tcp.zig", "const x = 1;\n// DEPARTS (bounded): the window\nfn send() void {}\n" },
            .{ "data/src/tcp_arrives.zig", "// DEPARTS (fast): no timer\n// DEPARTS (bounded): four pieces\nfn send_it() void { send(); }\n" },
            .{ "data/src/sub/deep.zig", "fn send() void {}\nconst sender = send;\n" },
            .{ "data/.zig-cache/o/junk.zig", "// DEPARTS (bounded): never seen\n" },
            .{ "data/docs/a.md", "see src/tcp.zig:2 and src/tcp.zig:9\n" },
            .{ "data/README.md", "top\n" },
        };
        for (files) |f| try d.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }

    fn deinit(self: *Tree) void {
        testing.allocator.free(self.root);
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Tree, src: []const u8, options: script.Options) script.Result {
        return script.runWith(self.threaded.io(), testing.allocator, self.root, src, .{}, 0, &out_buf, options);
    }

    fn expectOutput(self: *Tree, src: []const u8, options: script.Options, want: []const u8) !void {
        var r = self.run(src, options);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(want, r.output);
    }

    fn expectStop(self: *Tree, src: []const u8, options: script.Options, class: script.diag.Class, has: []const u8) !void {
        var r = self.run(src, options);
        defer r.deinit();
        const s = r.stop orelse return error.TestUnexpectedResult;
        errdefer std.debug.print("{s}: {s}\n", .{ @tagName(s.class), s.message });
        try testing.expectEqual(class, s.class);
        try testing.expect(std.mem.indexOf(u8, s.message, has) != null);
    }

    fn file(self: *Tree, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.threaded.io(), rel, testing.allocator, .unlimited);
    }
};

test "agent: arg gives the run's values by name, read as the default's kind, and the default when not given" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const given = [_]script.Arg{ .{ .name = "dir", .value = "src" }, .{ .name = "n", .value = "12" }, .{ .name = "loud", .value = "true" } };
    try t.expectOutput("print(arg(\"dir\", \".\"), arg(\"n\", 3) + 1, arg(\"loud\", false), arg(\"none\", \"x\"), arg(\"none\"))", .{ .args = &given }, "src\t13\ttrue\tx\tnil\n");
    try t.expectOutput("print(arg(\"n\", \"s\"), arg(\"dir\"))", .{ .args = &given }, "12\tsrc\n");
    try t.expectStop("print(arg(\"dir\", 3))", .{ .args = &given }, .argument, "dir=src is not an integer");
    try t.expectStop("print(arg(\"dir\", true))", .{ .args = &given }, .argument, "not true or false");
}

test "agent: match_path matches a glob part by part: ** any parts, * and ? never across a /" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput(
        \\print(match_path("src/tcp.zig", "src/*.zig"), match_path("src/sub/deep.zig", "src/*.zig"))
        \\print(match_path("src/sub/deep.zig", "src/**/*.zig"), match_path("src/tcp.zig", "src/**/*.zig"))
        \\print(match_path("src/tcp_arrives.zig", "src/tcp*.zig"), match_path("a/b/c", "**"), match_path("a", "a/**"))
        \\print(match_path("src/x.zig", "src/?.zig"), match_path("src/xy.zig", "src/?.zig"), match_path("src", "src/**/*.zig"))
    , .{}, "true\tfalse\ntrue\ttrue\ntrue\ttrue\ttrue\ntrue\tfalse\tfalse\n");
}

test "agent: walk's skip passes by names, a folder never entered; glob finds files and leaves hidden ones out" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput("local got = {} for e in walk_all(\"\", {kind = \"file\", skip = \".*\"}) do push(got, e.path) end print(join(got, \" \"))", .{}, "README.md docs/a.md src/sub/deep.zig src/tcp.zig src/tcp_arrives.zig\n");
    try t.expectOutput("print(join(glob(\"src/tcp*.zig\"), \" \"))", .{}, "src/tcp.zig src/tcp_arrives.zig\n");
    try t.expectOutput("print(join(glob(\"**/*.zig\"), \" \"))", .{}, "src/sub/deep.zig src/tcp.zig src/tcp_arrives.zig\n");
    try t.expectOutput("print(join(glob(\"README.md\"), \" \"), #glob(\"none/*.zig\"), #glob(\"none.md\"))", .{}, "README.md\t0\t0\n");
    // `{hidden = true}` takes dot-names too (QUEUE 233); another option is a mistake.
    try t.expectOutput("print(join(glob(\"**/*.zig\", {hidden = true}), \" \"), #glob(\"**/*.zig\", {hidden = false}))", .{}, ".zig-cache/o/junk.zig src/sub/deep.zig src/tcp.zig src/tcp_arrives.zig\t3\n");
    try t.expectStop("glob(\"*.zig\", {hiden = true})", .{}, .fail, "`glob` takes `hidden`, not `hiden`");
    // In parts of two entries, the same.
    var cut = script.runWith(t.threaded.io(), testing.allocator, t.root, "print(join(glob(\"**/*.zig\"), \" \"))", .{ .call_entries = 2 }, 0, &out_buf, .{});
    defer cut.deinit();
    try testing.expectEqualStrings("src/sub/deep.zig src/tcp.zig src/tcp_arrives.zig\n", cut.output);
}

test "agent: grep gives the lines holding a literal, numbered" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput("for m in grep(\"src/tcp_arrives.zig\", \"DEPARTS\") do print(m.line, m.text) end print(#grep(\"src/tcp.zig\", \"nothing\"))", .{}, "1\t// DEPARTS (fast): no timer\n2\t// DEPARTS (bounded): four pieces\n0\n");
}

test "agent: edit prints its diff and changes the file, one occurrence or all of them, whole words if asked" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput("print(edit(\"src/tcp.zig\", \"const x = 1;\", \"const x = 2;\"))", .{},
        \\--- a/src/tcp.zig
        \\+++ b/src/tcp.zig
        \\@@ -1,1 +1,1 @@
        \\-const x = 1;
        \\+const x = 2;
        \\1
        \\
    );
    const now = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("const x = 2;\n// DEPARTS (bounded): the window\nfn send() void {}\n", now);
    // A rename: whole words only, every one: `sender` is not `send`.
    try t.expectOutput("print(edit(\"src/sub/deep.zig\", \"send\", \"transmit\", {all = true, word = true}))", .{},
        \\--- a/src/sub/deep.zig
        \\+++ b/src/sub/deep.zig
        \\@@ -1,1 +1,1 @@
        \\-fn send() void {}
        \\+fn transmit() void {}
        \\@@ -2,1 +2,1 @@
        \\-const sender = send;
        \\+const sender = transmit;
        \\2
        \\
    );
    // A line added: the hunk counts it.
    try t.expectOutput("print(edit(\"README.md\", \"top\", \"top\\nmore\"))", .{}, "--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,2 @@\n-top\n+top\n+more\n1\n");
    try t.expectStop("edit(\"src/tcp.zig\", \"nothing here\", \"x\")", .{}, .argument, "is not in src/tcp.zig");
    try t.expectStop("edit(\"src/tcp_arrives.zig\", \"DEPARTS\", \"X\")", .{}, .argument, "2 times");
    try t.expectStop("edit(\"src/tcp.zig\", \"\", \"x\")", .{}, .argument, "nothing to replace");
    try t.expectStop("edit(\"src/tcp.zig\", \"x\", \"y\", {every = true})", .{}, .argument, "takes `all` and `word`");
}

test "agent: edit's list form applies its edits in sequence, each to the one before, one diff and one write (QUEUE 232)" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    // The second matches only after the first; the third is two lines on.
    try t.expectOutput(
        \\print(edit("src/tcp.zig", {
        \\  {old = "const x = 1;", new = "const y = 1;"},
        \\  {old = "const y", new = "const z"},
        \\  {old = "fn send()", new = "fn send2()"},
        \\}))
    , .{},
        \\--- a/src/tcp.zig
        \\+++ b/src/tcp.zig
        \\@@ -1,1 +1,1 @@
        \\-const x = 1;
        \\+const z = 1;
        \\@@ -3,1 +3,1 @@
        \\-fn send() void {}
        \\+fn send2() void {}
        \\3
        \\
    );
    const now = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("const z = 1;\n// DEPARTS (bounded): the window\nfn send2() void {}\n", now);
    // An edit across what an earlier one changed and the line after: one
    // hunk from the old file to the new.
    try t.expectOutput(
        \\print(edit("src/tcp.zig", {
        \\  {old = "const z = 1;", new = "const z = 10;"},
        \\  {old = "10;\n// DEPARTS", new = "10; // merged\n// DEPARTS"},
        \\}))
    , .{},
        \\--- a/src/tcp.zig
        \\+++ b/src/tcp.zig
        \\@@ -1,2 +1,2 @@
        \\-const z = 1;
        \\-// DEPARTS (bounded): the window
        \\+const z = 10; // merged
        \\+// DEPARTS (bounded): the window
        \\2
        \\
    );
    // An edit's own options: the rename, as the one-edit form gives it.
    try t.expectOutput("print(edit(\"src/sub/deep.zig\", {{old = \"send\", new = \"transmit\", all = true, word = true}}))", .{},
        \\--- a/src/sub/deep.zig
        \\+++ b/src/sub/deep.zig
        \\@@ -1,1 +1,1 @@
        \\-fn send() void {}
        \\+fn transmit() void {}
        \\@@ -2,1 +2,1 @@
        \\-const sender = send;
        \\+const sender = transmit;
        \\2
        \\
    );
}

test "agent: a list of edits that fails anywhere writes nothing and prints no diff; each edit is held to the one-edit form's rules (QUEUE 232)" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const before = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(before);
    var r = t.run("print(\"before\") edit(\"src/tcp.zig\", {{old = \"const x\", new = \"const y\"}, {old = \"fn send\", new = \"fn go\"}, {old = \"absent\", new = \"x\"}})", .{});
    defer r.deinit();
    try testing.expectEqual(script.diag.Class.argument, r.stop.?.class);
    try testing.expect(std.mem.indexOf(u8, r.stop.?.message, "\"absent\" is not in src/tcp.zig") != null);
    try testing.expectEqualStrings("before\n", r.output);
    try testing.expectEqual(@as(usize, 0), r.effects.len);
    const after = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    // An `old` there twice, without `all`: the one-edit form's refusal.
    try t.expectStop("edit(\"src/tcp_arrives.zig\", {{old = \"DEPARTS\", new = \"X\"}})", .{}, .argument, "is in src/tcp_arrives.zig 2 times: a longer `old` picks one");
    try t.expectStop("edit(\"src/tcp.zig\", {})", .{}, .argument, "no edits");
    try t.expectStop("edit(\"src/tcp.zig\", {{old = \"x\"}})", .{}, .argument, "`new`");
    try t.expectStop("edit(\"src/tcp.zig\", {{old = \"x\", new = \"y\", every = true}})", .{}, .argument, "takes `old`, `new`, `all` and `word`");
    try t.expectStop("edit(\"src/tcp.zig\", {\"x\"})", .{}, .type, "a map");
    try t.expectStop("edit(\"src/tcp.zig\", \"x\")", .{}, .type, "a list of edits");
    // At most 64 edits a call; a background run refuses the call before
    // its list is read, a wrong one included.
    try t.expectStop("local l = {} for i = 1, 65 do push(l, {old = \"const x\", new = \"const x\"}) end edit(\"src/tcp.zig\", l)", .{}, .argument, "at most 64 edits");
    try t.expectStop("edit(\"src/tcp.zig\", {\"not an edit\"})", .{ .mode = .background }, .argument, "only reads");
    // A dry run: the diff, one effect, the file as it was.
    var d = t.run("edit(\"src/tcp.zig\", {{old = \"const x\", new = \"const y\"}, {old = \"fn send\", new = \"fn go\"}})", .{ .mode = .dry_run });
    defer d.deinit();
    try testing.expectEqual(@as(?script.Stop, null), d.stop);
    try testing.expectEqual(@as(usize, 1), d.effects.len);
    try testing.expectEqualStrings("dry run", d.effects[0].outcome);
    const kept = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(before, kept);
}

test "agent: a dry run shows the diff and logs every change, and changes nothing; what a real run would refuse it refuses too" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    var r = t.run("edit(\"src/tcp.zig\", \"const x = 1;\", \"const x = 2;\") replace(\"new.txt\", \"hi\") remove(\"README.md\") mkdir(\"made\")", .{ .mode = .dry_run });
    defer r.deinit();
    try testing.expectEqual(@as(?script.Stop, null), r.stop);
    try testing.expect(std.mem.startsWith(u8, r.output, "--- a/src/tcp.zig\n"));
    try testing.expectEqual(@as(usize, 4), r.effects.len);
    for (r.effects, [_][]const u8{ "edit", "replace", "remove", "mkdir" }) |e, op| {
        try testing.expectEqualStrings(op, e.op);
        try testing.expectEqualStrings("dry run", e.outcome);
    }
    const kept = try t.file("data/src/tcp.zig");
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.startsWith(u8, kept, "const x = 1;"));
    const readme = try t.file("data/README.md");
    defer testing.allocator.free(readme);
    try testing.expectEqualStrings("top\n", readme);
    try testing.expectError(error.FileNotFound, t.tmp.dir.access(t.threaded.io(), "data/new.txt", .{}));
    try t.expectStop("remove(\"none.txt\")", .{ .mode = .dry_run }, .store, "not found");
    // A background run refuses an edit, as any change.
    try t.expectStop("edit(\"src/tcp.zig\", \"const\", \"var\")", .{ .mode = .background }, .argument, "only reads");
}

// ── docs/SHALE-AGENTS.md: every block runs ──────────────────────────────

/// A checkout shaped like zig-metal-unikernel's, small: what the cookbook
/// in docs/SHALE-AGENTS.md is run on.
fn checkout(t: *Tree) !void {
    const io = t.threaded.io();
    const d = t.tmp.dir;
    try d.deleteTree(io, "data");
    for ([_][]const u8{ "data/src/sub", "data/.zig-cache/o", "data/docs" }) |p| try d.createDirPath(io, p);
    const files = [_][2][]const u8{
        .{ "data/src/tcp.zig", "//! TCP. The deadlines are in `tcp_timeouts.zig:2`.\nconst timeouts = @import(\"tcp_timeouts.zig\");\n// DEPARTS (bounded): four pieces held, not more.\n// DEPARTS (simpler): no SACK.\npub const pastDeadline = timeouts.pastDeadline;\nfn check() void {\n    props.always(@src(), true, \"tcp: what is sent was queued\", .{});\n}\n" },
        .{ "data/src/tcp_timeouts.zig", "// DEPARTS (fast): a 25 ms first RTO.\npub fn pastDeadline(now: u64) bool {\n    props.always(@src(), now > 0, \"tcp: a deadline is after the start\", .{});\n    return now > 100;\n}\n" },
        .{ "data/src/sub/deep.zig", "const x = 1;\n" },
        .{ "data/.zig-cache/o/tcp_copy.zig", "// DEPARTS (bounded): a cached copy\n" },
        .{ "data/docs/notes.md", "See `tcp.zig:5` for the alias, (tcp_timeouts.zig:40) for the check, and `gone.zig:1`.\n" },
    };
    for (files) |f| try d.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (1..1201) |i| try big.print(testing.allocator, "// line {d}\n", .{i});
    try d.writeFile(io, .{ .sub_path = "data/src/big_test.zig", .data = big.items });
}

test "docs/SHALE-AGENTS.md: every shale block runs on the checkout, as a dry run, and prints what the doc says it prints" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const doc = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "docs/SHALE-AGENTS.md", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(doc);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try @import("examples_test.zig").snippets(a, doc);
    var wrong: usize = 0;
    for (all) |sn| {
        var t: Tree = undefined;
        try t.init();
        defer t.deinit();
        try checkout(&t);
        var r = t.run(sn.source, .{ .mode = .dry_run });
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("docs/SHALE-AGENTS.md:{d}: stopped {d}:{d} {s}: {s}\n", .{ sn.line, s.line, s.column, @tagName(s.class), s.message });
            wrong += 1;
            continue;
        }
        const got = try std.mem.replaceOwned(u8, a, r.output, "\t", "<TAB>");
        if (sn.prints == null or !std.mem.eql(u8, got, sn.prints.?)) {
            std.debug.print("docs/SHALE-AGENTS.md:{d}: prints\n{s}-- not --\n{s}", .{ sn.line, got, sn.prints orelse "(nothing said)\n" });
            wrong += 1;
        }
        // A dry run: the checkout is as it was.
        const tcp = try t.file("data/src/tcp.zig");
        defer testing.allocator.free(tcp);
        try testing.expect(std.mem.indexOf(u8, tcp, "pastDeadline") != null);
    }
    try testing.expectEqual(@as(usize, 0), wrong);
    try testing.expect(all.len >= 5);
}

test "agent: a result says what the run took of its store budgets, as the Linux tool prints it" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    var r = t.run("local a = ls(\"\") local b = ls(\"src\") local c = read(\"README.md\")", .{});
    defer r.deinit();
    try testing.expectEqual(@as(u64, 3), r.reads);
    try testing.expectEqual(@as(u64, 4), r.read_bytes);
    try testing.expectEqual(@as(u64, 0), r.changes);
    var w = t.run("replace(\"x.txt\", \"hi\") mkdir(\"d\")", .{ .mode = .dry_run });
    defer w.deinit();
    try testing.expectEqual(@as(u64, 2), w.changes);
}

test "agent: between gives the text after one string and before the next, or nil" {
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput(
        \\print(between("// DEPARTS (bounded): four", "DEPARTS (", ")"))
        \\print(between("props.always(@src(), x, \"tcp: a b\", .{})", "\"", "\""))
        \\print(between("a=1;b=2", "b=", ""), between("abc", "", "b"), between("abc", "x", "c"), between("abc", "a", "x"))
        \\print(between("((x))", "(", ")"))
    , .{}, "bounded\ntcp: a b\n2\ta\tnil\tnil\n(x\n");
}
