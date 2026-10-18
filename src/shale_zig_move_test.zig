//! **DECLARATIONS MOVED, AND WHAT THE MOVE BROKE, TESTED** (metal-vmm
//! QUEUE 235, 2): `zig_move` through the gate on fixtures and on the two
//! files the linux_host split began from; the pure mover
//! (`shale_zig_move.move`) over the repo's own files, there and back; and
//! `zig_rename` and `uses_left` held to one answer.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");
const zm = @import("shale_zig_move.zig");
const za = @import("shale_zig_ast.zig");
const zig = @import("shale_host_zig.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{host_linux.linux_prelude};
    // The CLI's: a change is one line.
    t.diffs = .summary;
}

/// A move's report, a row each: `list name line`.
const report =
    \\function report(r)
    \\  print("moved", r.moved)
    \\  for k in {"needs_pub", "needs_import", "needs_from_from", "uses_left"} do
    \\    for x in r[k] do print(k, x.name, x.line, get(x, "target", "")) end
    \\  end
    \\end
    \\
;

const fixture =
    \\const std = @import("std");
    \\const Mem = std.mem;
    \\
    \\const a = 1;
    \\
    \\/// doc of X
    \\const X = struct {
    \\    y: u8,
    \\    fn hidden() void {}
    \\    pub fn shown() void {}
    \\};
    \\
    \\fn helper() void {}
    \\
    \\// plain, above w
    \\pub fn w() void {
    \\    _ = std.mem;
    \\    _ = Mem;
    \\    helper();
    \\    _ = a;
    \\}
    \\
    \\const b = X.hidden;
    \\const c = X.shown;
    \\test "x" {
    \\    _ = X{ .y = 1 };
    \\}
    \\
;

test "zig_move: cut and put, its doc comment with it, and what it broke: pub, imports, from's own, uses left" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("from.zig", fixture);
    try t.expectOutput(
        report ++ "report(zig_move(\"from.zig\", \"to.zig\", {\"X\", \"w\"}))",
        "edit to.zig: 1 hunk, -1 +14 lines\n" ++
            "edit from.zig: 2 hunks, -16 +2 lines\n" ++
            "moved\t2\n" ++
            "needs_pub\tX\t7\t\n" ++
            "needs_pub\tX.hidden\t23\t\n" ++
            "needs_import\tstd\t17\t@import(\"std\")\n" ++
            "needs_import\tMem\t18\tstd.mem\n" ++
            "needs_from_from\thelper\t19\t\n" ++
            "needs_from_from\ta\t20\t\n" ++
            "uses_left\tX\t23\t\n" ++
            "uses_left\tX\t24\t\n" ++
            "uses_left\tX\t26\t\n",
    );
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\const Mem = std.mem;
        \\
        \\const a = 1;
        \\
        \\fn helper() void {}
        \\
        \\// plain, above w
        \\const b = X.hidden;
        \\const c = X.shown;
        \\test "x" {
        \\    _ = X{ .y = 1 };
        \\}
        \\
    , try t.file("from.zig"));
    try testing.expectEqualStrings(
        \\/// doc of X
        \\const X = struct {
        \\    y: u8,
        \\    fn hidden() void {}
        \\    pub fn shown() void {}
        \\};
        \\
        \\pub fn w() void {
        \\    _ = std.mem;
        \\    _ = Mem;
        \\    helper();
        \\    _ = a;
        \\}
        \\
    , try t.file("to.zig"));
}

test "zig_move: doc_and_plain takes the comment above; after puts it after a declaration; the last one leaves one newline" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("from.zig", fixture);
    try t.put("to.zig", "const one = 1;\n\nconst two = 2;\n");
    try t.expectOutput("local r = zig_move(\"from.zig\", \"to.zig\", {\"w\"}, {comment = \"doc_and_plain\", after = \"one\"}) print(r.moved)", "edit to.zig: 1 hunk, -1 +9 lines\nedit from.zig: 1 hunk, -9 +1 lines\n1\n");
    try testing.expectEqualStrings("const one = 1;\n\n// plain, above w\npub fn w() void {\n    _ = std.mem;\n    _ = Mem;\n    helper();\n    _ = a;\n}\n\nconst two = 2;\n", try t.file("to.zig"));
    try testing.expect(std.mem.indexOf(u8, try t.file("from.zig"), "plain, above w") == null);
    // The file's last declaration: one newline at its end, after what is left.
    try t.put("end.zig", "const p = 1;\n\nconst q = 2;\n");
    try t.expectOutput("local r = zig_move(\"end.zig\", \"q.zig\", {\"q\"}) print(r.moved)", "edit q.zig: 1 hunk, -1 +2 lines\nedit end.zig: 1 hunk, -3 +1 lines\n1\n");
    try testing.expectEqualStrings("const p = 1;\n", try t.file("end.zig"));
    try testing.expectEqualStrings("const q = 2;\n", try t.file("q.zig"));
}

fn moveFor(a: std.mem.Allocator, from: [:0]const u8, to: [:0]const u8, names: []const []const u8, mode: zm.CommentMode, after: ?[]const u8) !zm.Moved {
    var wants: std.ArrayList(zm.Want) = .empty;
    for (names) |n| try wants.append(a, .{ .name = n });
    return switch (try zm.move(a, from, to, wants.items, mode, after)) {
        .done => |d| d,
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
}

test "zig_move: moved lines end as `to`'s do, a CRLF block into an LF file and back, so neither file mixes them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const crlf = "const a = 1;\r\n\r\nfn b() void {\r\n    _ = a;\r\n}\r\n";
    const m = try moveFor(a, crlf, "const x = 1;\n", &.{"b"}, .doc, null);
    try testing.expectEqualStrings("const x = 1;\n\nfn b() void {\n    _ = a;\n}\n", m.to_now);
    // And back: LF lines into the CRLF file end in CRLF there.
    const back = try moveFor(a, "fn b() void {\n    _ = a;\n}\n", "const a = 1;\r\n", &.{"b"}, .doc, null);
    try testing.expectEqualStrings(crlf, back.to_now);
}

test "zig_move: declarations on lines next to each other stay next to each other; a blank line between stays one (metal-vmm main.zig's addresses, under one doc)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try moveFor(a, "/// The addresses.\nconst a = 1;\nconst b = 2;\n\nconst c = 3;\nconst keep = 4;\n", "", &.{ "a", "b", "c" }, .doc, null);
    try testing.expectEqualStrings("/// The addresses.\nconst a = 1;\nconst b = 2;\n\nconst c = 3;\n", m.to_now);
    // Not next to each other in `from` (one between, left): apart in `to`.
    const n = try moveFor(a, "const a = 1;\nconst x = 2;\nconst b = 3;\n", "", &.{ "a", "b" }, .doc, null);
    try testing.expectEqualStrings("const a = 1;\n\nconst b = 3;\n", n.to_now);
}

test "zig_move: a section's banner goes with its section when every declaration under it moves, and stays when one is left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const from = "const a = 1;\n\n// ── the timer ──\n\nconst t1 = 2;\nconst t2 = 3;\n\n// ── the rest ──\n\nconst r = 4;\n";
    const m = try moveFor(a, from, "", &.{ "t1", "t2" }, .doc, null);
    try testing.expectEqualStrings("const a = 1;\n\n// ── the rest ──\n\nconst r = 4;\n", m.from_now);
    try testing.expectEqualStrings("// ── the timer ──\n\nconst t1 = 2;\nconst t2 = 3;\n", m.to_now);
    // One of the two moves: the banner stays over what is left.
    const n = try moveFor(a, from, "", &.{"t1"}, .doc, null);
    try testing.expectEqualStrings("const a = 1;\n\n// ── the timer ──\n\nconst t2 = 3;\n\n// ── the rest ──\n\nconst r = 4;\n", n.from_now);
    try testing.expectEqualStrings("const t1 = 2;\n", n.to_now);
}

test "zig_move: an indented comment between two moved declarations joins their cuts (it sliced backwards)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try moveFor(a, "const a = 1;\n  // b\nconst b = 2;\n", "", &.{ "a", "b" }, .doc_and_plain, null);
    try testing.expectEqualStrings("", m.from_now);
    // b and its comment sat right under a: they stay so.
    try testing.expectEqualStrings("const a = 1;\n  // b\nconst b = 2;\n", m.to_now);
}

test "zig_move: a comment on a declaration's last line goes with it, and `after` puts a block after the comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try moveFor(a, "const a = 1;\nconst b = 2; // why\nconst c = 3;\n", "", &.{"b"}, .doc, null);
    try testing.expectEqualStrings("const a = 1;\nconst c = 3;\n", m.from_now);
    try testing.expectEqualStrings("const b = 2; // why\n", m.to_now);
    const n = try moveFor(a, "const b = 2;\n", "const x = 1; // x's\n\nconst y = 2;\n", &.{"b"}, .doc, "x");
    try testing.expectEqualStrings("const x = 1; // x's\n\nconst b = 2;\n\nconst y = 2;\n", n.to_now);
}

test "zig_move: a CRLF file's separators are CRLF, there and back (found by the repo-wide property)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "const a = 1;\r\n\r\nconst b = 2;\r\n\r\nconst c = 3;\r\n";
    const m = try moveFor(a, src, "", &.{"b"}, .doc, null);
    try testing.expectEqualStrings("const a = 1;\r\n\r\nconst c = 3;\r\n", m.from_now);
    try testing.expectEqualStrings("const b = 2;\r\n", m.to_now);
    const n = try moveFor(a, "const b = 2;\n", "const x = 1;\r\n\r\nconst y = 2;\r\n", &.{"b"}, .doc, "x");
    try testing.expectEqualStrings("const x = 1;\r\n\r\nconst b = 2;\r\n\r\nconst y = 2;\r\n", n.to_now);
    const o = try moveFor(a, "const b = 2;\n", "const x = 1;\r\n", &.{"b"}, .doc, null);
    try testing.expectEqualStrings("const x = 1;\r\n\r\nconst b = 2;\r\n", o.to_now);
}

test "zig_move: with the change budget room for one of its two writes, it writes neither" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("from.zig", "const a = 1;\n\nconst b = 2;\n");
    // 999 of the 1,000 changes spent: one write left, and a move is two.
    try t.expectStop("for i = 1, 999 do replace(\"spent.txt\", \"x\") end zig_move(\"from.zig\", \"to.zig\", {\"b\"})", .atomic, .budget, "change budget");
    try testing.expectEqualStrings("const a = 1;\n\nconst b = 2;\n", try t.file("from.zig"));
    try testing.expectError(error.FileNotFound, t.file("to.zig"));
}

test "zig_move: what stops it, with nothing written: a name not there, a name that is two, a name twice, an unnamed one, an `after` not there" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const two = "const foo = 1;\n\ntest foo {}\n\ntest {}\n";
    try t.put("f.zig", two);
    try t.put("g.zig", "const g = 1;\n");
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"nope\"}", "`nope` is not a top-level declaration of `from`" },
        .{ "{\"foo\"}", "`foo` names 2 declarations of `from`: say which" },
        .{ "{{kind = \"const\", name = \"foo\"}, {kind = \"const\", name = \"foo\"}}", "`foo` is named twice" },
        .{ "{\"\"}", "cannot be named, so it cannot be moved" },
        .{ "{{kind = \"fn\", name = \"foo\"}}", "`foo` of that kind is not" },
    };
    for (cases) |c| {
        try t.expectStop(try std.fmt.allocPrint(t.arena.allocator(), "zig_move(\"f.zig\", \"g.zig\", {s})", .{c[0]}), .atomic, .argument, c[1]);
        try testing.expectEqualStrings(two, try t.file("f.zig"));
        try testing.expectEqualStrings("const g = 1;\n", try t.file("g.zig"));
    }
    try t.expectStop("zig_move(\"f.zig\", \"g.zig\", {{kind = \"const\", name = \"foo\"}}, {after = \"h\"})", .atomic, .argument, "`after`: `h` is not");
    try t.expectStop("zig_move(\"f.zig\", \"f.zig\", {\"foo\"})", .atomic, .argument, "one file");
    try t.put("bad.zig", "const = ;\n");
    try t.expectStop("zig_move(\"bad.zig\", \"g.zig\", {\"x\"})", .atomic, .argument, "does not parse as Zig: line 1");
    // By kind, a name that is two moves the one named.
    try t.expectOutput("print(zig_move(\"f.zig\", \"g.zig\", {{kind = \"test\", name = \"foo\"}}).moved)", "edit g.zig: 1 hunk, -1 +3 lines\nedit f.zig: 1 hunk, -3 +1 lines\n1\n");
    try testing.expectEqualStrings("const foo = 1;\n\ntest {}\n", try t.file("f.zig"));
}

test "zig_move: a use without a call counts; the known limits, pinned: a method through a value, a name through an @This() alias" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    // angry-gopher router.zig's shape: a function given, not called.
    try t.put("u.zig",
        \\const store = @import("store.zig");
        \\
        \\fn scriptDurable() bool {
        \\    return true;
        \\}
        \\
        \\test "durable" {
        \\    store.durable_now = scriptDurable;
        \\}
        \\
    );
    try t.expectOutput(report ++ "report(zig_move(\"u.zig\", \"h.zig\", {\"scriptDurable\"}))", "edit h.zig: 1 hunk, -1 +4 lines\nedit u.zig: 1 hunk, -5 +1 lines\nmoved\t1\nneeds_pub\tscriptDurable\t3\t\nuses_left\tscriptDurable\t8\t\n");
    // Known limits: `p.end()` through a value names no `P.end`, and
    // `self_file.P` through an alias is no use of `P`: the compiler says.
    try t.put("l.zig",
        \\const self_file = @This();
        \\
        \\const P = struct {
        \\    fn end(p: P) void {
        \\        _ = p;
        \\    }
        \\};
        \\
        \\fn f() void {
        \\    var p: P = .{};
        \\    p.end();
        \\    _ = self_file.P;
        \\}
        \\
    );
    try t.expectOutput(report ++ "report(zig_move(\"l.zig\", \"p.zig\", {\"P\"}))", "edit p.zig: 1 hunk, -1 +6 lines\nedit l.zig: 1 hunk, -7 +1 lines\nmoved\t1\nneeds_pub\tP\t3\t\nuses_left\tP\t10\t\n");
}

test "zig_move and zig_rename: `const` that qualifies a pointer declares nothing: `[]const X` is a use of `X`" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const src = "const X = u8;\n\nfn f(a: []const X, b: *const X, c: *align(1) const X) void {\n    _ = .{ a, b, c };\n}\n";
    try t.put("k.zig", src);
    try t.expectOutput(report ++ "report(zig_move(\"k.zig\", \"x.zig\", {\"X\"}))", "edit x.zig: 1 hunk, -1 +2 lines\nedit k.zig: 1 hunk, -3 +1 lines\nmoved\t1\nneeds_pub\tX\t1\t\nuses_left\tX\t3\t\n");
    // And a qualified rename of those uses does not stop as at a declaration.
    try t.put("k.zig", "fn f(a: []const X, b: *const X, c: *align(1) const X) void {\n    _ = .{ a, b, c };\n}\n");
    try t.expectOutput("print(zig_rename(\"k.zig\", \"X\", \"m.X\").renamed)", "edit k.zig: 1 hunk, -1 +1 lines\n3\n");
}

/// The linux_host split, replayed: `commit`'s parent's linux_host.zig, the
/// declarations its new file took from it (in the new file, in the parent,
/// gone from linux_host.zig after), moved by `zig_move`; its report a row
/// a list, `name:line` each.
const replay =
    \\function show(rev, p) return must(run({"git", "show", rev .. ":src/" .. p}, {timeout_ms = 30000, whole = 2097152})).out end
    \\function replay(commit, newfile)
    \\  create("lh.zig", show(commit .. "^", "linux_host.zig"))
    \\  create("new_hand.zig", show(commit, newfile))
    \\  create("lh_hand.zig", show(commit, "linux_host.zig"))
    \\  local before = {}
    \\  for d in zig_decls("lh.zig") do before[d.name] = true end
    \\  local after = {}
    \\  for d in zig_decls("lh_hand.zig") do after[d.name] = true end
    \\  local names = {}
    \\  for d in zig_decls("new_hand.zig") do
    \\    if has_key(before, d.name) and not has_key(after, d.name) then push(names, {kind = d.kind, name = d.name}) end
    \\  end
    \\  local r = zig_move("lh.zig", "new.zig", names)
    \\  local rows = {moved = r.moved}
    \\  for k in {"needs_pub", "needs_import", "needs_from_from", "uses_left"} do
    \\    local row = {}
    \\    for x in r[k] do push(row, x.name .. ":" .. x.line) end
    \\    rows[k] = " " .. join(row, " ") .. " "
    \\  end
    \\  return rows
    \\end
    \\-- Every row of a replay's report, so one more or one fewer fails.
    \\function every(rows)
    \\  print("moved", rows.moved)
    \\  for k in {"needs_pub", "needs_import", "needs_from_from", "uses_left"} do print(k .. ":" .. rows[k]) end
    \\end
    \\
;

test "zig_move replays 589837e (linux_writes.zig): every row: the three the hand made pub and WriteWatch.run; std, net and Io imports; sleepMs from's own; the uses left" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput(replay ++
        \\every(replay("589837e", "linux_writes.zig"))
    , "edit new.zig: 1 hunk, -1 +240 lines\nedit lh.zig: 1 hunk, -241 +1 lines\nmoved\t22\nneeds_pub: Hold:527 Sent:593 WriteWatch:703 WriteWatch.run:484 \nneeds_import: std:519 net:595 Io:596 \nneeds_from_from: sleepMs:683 \nuses_left: Sent:305 Hold:308 Hold:325 Sent:325 WriteWatch:483 write_deadline_for_test_ms:483 kept_write_deadline_ms:483 WriteWatch:484 writes_ended_by_deadline:1427 kept_write_deadline_ms:1427 write_deadline_for_test_ms:2294 write_deadline_for_test_ms:2295 turn_write_deadline_for_test_ms:2942 turn_write_deadline_for_test_ms:2943 \n");
}

test "zig_move replays 35317cf (linux_reads.zig): every row: the fifteen the hand made pub and Progress.Ended; std, net, Io and body_rule imports; sleepMs from's own; the uses left" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput(replay ++
        \\every(replay("35317cf", "linux_reads.zig"))
    , "edit new.zig: 1 hunk, -1 +326 lines\nedit lh.zig: 4 hunks, -330 +4 lines\nmoved\t28\nneeds_pub: Got:531 Progress:548 readWhole:568 Raced:623 verdict:771 watch:797 neverRead:819 slots:830 nextAsk:838 takeSlot:856 readDone:887 giveBackSlot:893 small_held:901 unchargeSmall:913 Whole:922 Progress.Ended:1716 \nneeds_import: std:549 net:551 Io:552 body_rule:568 \nneeds_from_from: sleepMs:803 \nuses_left: Progress:222 neverRead:239 takeSlot:242 nextAsk:242 readWhole:250 fail_after_read_for_test:251 readDone:254 Progress:340 Raced:343 Raced:344 watch:347 Progress:402 giveBackSlot:404 unchargeSmall:411 unchargeSmall:463 deadline_for_test_ms:1438 deadline_for_test_ms:1439 deadline_for_test_ms:1530 deadline_for_test_ms:1531 Progress:1560 Whole:1568 small_held:1620 small_held:1623 stall_for_test_ms:1627 stall_for_test_ms:1628 deadline_for_test_ms:1648 deadline_for_test_ms:1649 small_held:1661 slots:1668 slots:1680 slots:1691 nextAsk:1701 Progress:1706 takeSlot:1707 nextAsk:1707 giveBackSlot:1711 slot_wait_for_test_ms:1712 slot_wait_for_test_ms:1713 Progress:1714 takeSlot:1715 Progress:1716 stall_for_test_ms:1720 stall_for_test_ms:1721 slots:1726 small_budget_for_test:1730 small_budget_for_test:1731 small_held:1739 slot_wait_for_test_ms:1761 slot_wait_for_test_ms:1762 slots:1774 slots:1786 deadline_for_test_ms:1805 deadline_for_test_ms:1806 Got:1826 Progress:1827 Got:1829 verdict:1829 Got:1830 verdict:1830 Got:1831 verdict:1831 Got:1834 verdict:1834 Got:1835 verdict:1835 Got:1836 verdict:1836 Got:1837 verdict:1837 fail_after_read_for_test:1841 fail_after_read_for_test:1842 small_held:1847 slots:1853 stall_for_test_ms:1862 stall_for_test_ms:1863 tick_for_test_ms:1864 tick_for_test_ms:1865 slots:1889 small_held:1906 Progress:1947 small_held:1962 unchargeSmall:1964 Whole:1965 tick_for_test_ms:1979 tick_for_test_ms:1980 tick_for_test_ms:2480 tick_for_test_ms:2481 \n");
}

test "zig_move: an import named through another (`Bus = streams.Bus`) brings that one too, and its own in turn" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    // angry-gopher router.zig's shape, which its search tests needed.
    try t.put("c.zig", "const std = @import(\"std\");\nconst streams = std.mem;\nconst Bus = streams.Allocator;\n\nfn f(b: Bus) void {\n    _ = b;\n}\n");
    try t.expectOutput(report ++ "report(zig_move(\"c.zig\", \"d.zig\", {\"f\"}))", "edit d.zig: 1 hunk, -1 +4 lines\nedit c.zig: 1 hunk, -5 +1 lines\nmoved\t1\nneeds_import\tBus\t5\tstreams.Allocator\nneeds_import\tstreams\t5\tstd.mem\nneeds_import\tstd\t5\t@import(\"std\")\n");
}

test "zig_move: a step a token and a node of both files, more for a file four times the size" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    var steps: [2]u64 = undefined;
    for ([_]usize{ 200, 800 }, 0..) |n, k| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "const moved = 1;\n\n");
        for (0..n) |i| try src.print(a, "const v{d} = x;\n", .{i});
        try t.put("n.zig", src.items);
        try t.put("m.zig", "");
        var r = t.run("local r = zig_move(\"n.zig\", \"m.zig\", {\"moved\"})", .atomic);
        defer r.deinit();
        try testing.expect(r.stop == null);
        steps[k] = r.steps;
    }
    if (steps[1] < steps[0] + 7 * 600) {
        std.debug.print("{d} steps at 200 lines, {d} at 800: less than a step a token and a node more\n", .{ steps[0], steps[1] });
        return error.TestUnexpectedResult;
    }
}

/// The repo's own src/**/*.zig, each read NUL-ended, by path.
fn eachSource(a: std.mem.Allocator, io: std.Io) ![]const struct { path: []const u8, src: [:0]const u8 } {
    const Item = struct { path: []const u8, src: [:0]const u8 };
    var out: std.ArrayList(Item) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
        try out.append(a, .{ .path = try a.dupe(u8, e.path), .src = try dir.readFileAllocOptions(io, e.path, a, .limited(16 << 20), .of(u8), 0) });
    }
    return @ptrCast(out.items);
}

test "zig_move's mover over the repo's own src/**/*.zig: two declarations moved to an empty file and back give the file it began with, at each boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var tried: usize = 0;
    for (try eachSource(a, threaded.io())) |f| {
        const ds = switch (try za.decls(a, f.src)) {
            .ok => |ok| ok.decls,
            else => continue,
        };
        // The first run of two, neither first nor last, single blank lines
        // around, every name once in the file.
        var i: usize = 1;
        while (i + 2 < ds.len) : (i += 1) {
            if (!(blankApart(f.src, ds[i - 1], ds[i]) and blankApart(f.src, ds[i], ds[i + 1]) and blankApart(f.src, ds[i + 1], ds[i + 2]))) continue;
            if (!(once(ds, ds[i - 1]) and once(ds, ds[i]) and once(ds, ds[i + 1]))) continue;
            break;
        } else continue;
        // The file as it is, and with each boundary the box found
        // (metal-vmm QUEUE 235's review): a trailing comment on both
        // moved declarations' last lines, an indented comment between
        // them, and every line ended by CRLF.
        for (std.enums.values(Boundary)) |b| try thereAndBack(a, f.path, try withBoundary(a, f.src, ds, i, b), i, b);
        tried += 1;
    }
    try testing.expect(tried > 30);
}

const Boundary = enum { blank, trailing, indented, crlf };

/// `src` with boundary `b` at the declarations `ds[i]` and `ds[i + 1]`.
fn withBoundary(a: std.mem.Allocator, src: [:0]const u8, ds: []const za.Decl, i: usize, b: Boundary) ![:0]const u8 {
    const x = ds[i];
    const y = ds[i + 1];
    return switch (b) {
        .blank => src,
        .trailing => try std.mem.concatWithSentinel(a, u8, &.{ src[0..x.stop], " // x's", src[x.stop..y.stop], " // y's", src[y.stop..] }, 0),
        .indented => try std.mem.concatWithSentinel(a, u8, &.{ src[0 .. x.stop + 2], "    // between\n", src[y.start..] }, 0),
        .crlf => crlf: {
            const n = std.mem.replacementSize(u8, src, "\n", "\r\n");
            const out = try a.allocSentinel(u8, n, 0);
            _ = std.mem.replace(u8, src, "\n", "\r\n", out);
            break :crlf out;
        },
    };
}

/// `ds[i]` and `ds[i + 1]` of `src` (read again, for the boundary may have
/// moved them) to an empty file, and back after `ds[i - 1]`: the file it
/// began with.
fn thereAndBack(a: std.mem.Allocator, path: []const u8, src: [:0]const u8, i: usize, b: Boundary) !void {
    const ds = (try za.decls(a, src)).ok.decls;
    const mode: zm.CommentMode = if (b == .indented) .doc_and_plain else .doc;
    const wants = [_]zm.Want{ .{ .name = ds[i].name, .kind = ds[i].kind }, .{ .name = ds[i + 1].name, .kind = ds[i + 1].kind } };
    const there = switch (try zm.move(a, src, "", &wants, mode, null)) {
        .done => |d| d,
        .refused => |why| {
            std.debug.print("src/{s} ({t}): {s}\n", .{ path, b, why });
            return error.TestUnexpectedResult;
        },
    };
    const back = switch (try zm.move(a, try a.dupeZ(u8, there.to_now), try a.dupeZ(u8, there.from_now), &wants, mode, ds[i - 1].name)) {
        .done => |d| d,
        .refused => |why| {
            std.debug.print("src/{s} ({t}), back: {s}\n", .{ path, b, why });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, back.to_now, src)) {
        std.debug.print("src/{s} ({t}): `{s}` and `{s}` there and back is not the file\n", .{ path, b, ds[i].name, ds[i + 1].name });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("", back.from_now);
}

fn blankApart(src: []const u8, x: za.Decl, y: za.Decl) bool {
    return y.start == x.stop + 2 and std.mem.eql(u8, src[x.stop..y.start], "\n\n") and y.comment_above == null;
}

fn once(ds: []const za.Decl, d: za.Decl) bool {
    if (d.name_form == .none) return false;
    var n: usize = 0;
    for (ds) |e| n += @intFromBool(std.mem.eql(u8, e.name, d.name));
    return n == 1;
}

test "zig_rename and zig_move read identifiers alike: a declaration's uses outside it are the lines a rename changes there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var compared: usize = 0;
    for (try eachSource(a, threaded.io())) |f| {
        const ds = switch (try za.decls(a, f.src)) {
            .ok => |ok| ok.decls,
            else => continue,
        };
        const starts = try za.lineStarts(a, f.src);
        for (ds) |d| {
            if (d.name_form != .identifier or d.kind == .@"test" or !once(ds, d)) continue;
            const moved = switch (try zm.move(a, f.src, "", &.{.{ .name = d.name, .kind = d.kind }}, .doc, null)) {
                .done => |m| m,
                .refused => continue,
            };
            const renamed = switch (try zig.plan(a, f.src, d.name, "zz_one_reading", null)) {
                .done => |p| p,
                else => return error.TestUnexpectedResult,
            };
            // The rename's lines outside the declaration, each once: what
            // it renames there is uses (a declaration of the name is the
            // one, inside it).
            var want: std.ArrayList(usize) = .empty;
            for (renamed.spans) |s| {
                if (s.o0 >= d.start and s.o0 < d.stop) continue;
                const l = za.lineOf(starts, s.o0);
                if (want.items.len == 0 or want.items[want.items.len - 1] != l) try want.append(a, l);
            }
            var got: std.ArrayList(usize) = .empty;
            for (moved.uses_left) |u| try got.append(a, u.line);
            if (!std.mem.eql(usize, want.items, got.items)) {
                std.debug.print("src/{s}: `{s}`: zig_rename changes lines {any}, uses_left says {any}\n", .{ f.path, d.name, want.items, got.items });
                return error.TestUnexpectedResult;
            }
            compared += 1;
        }
    }
    try testing.expect(compared > 1000);
}
