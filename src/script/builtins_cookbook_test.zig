//! The builtins the cookbook asked for (metal-vmm QUEUE 220): a sort that
//! goes down, the first of a list, paths, and a read of a file that may be
//! missing. Every run here is the gate's (script.run in tests).

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;
const Fixture = @import("builtins_test.zig").Fixture;

test "cookbook: sort by a key, descending, keeps equal keys in their order; take gives the first n, or all of a shorter list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rows = "local r = {{n = 2, s = \"a\"}, {n = 3, s = \"b\"}, {n = 2, s = \"c\"}, {n = 1, s = \"d\"}} ";
    try f.expectOutput(rows ++ "sort(r, \"n\", \"desc\") for x in r do print(x.n, x.s) end", "3\tb\n2\ta\n2\tc\n1\td\n");
    try f.expectOutput(rows ++ "sort(r, \"n\", \"asc\") for x in r do print(x.n, x.s) end", "1\td\n2\ta\n2\tc\n3\tb\n");
    try f.expectOutput(rows ++ "sort(r, \"s\", \"desc\") print(r[1].s, r[4].s)", "d\ta\n");
    try f.expectStop(rows ++ "sort(r, \"n\", \"down\")", .argument);
    try f.expectOutput("local l = {5, 6, 7} local t = take(l, 2) print(#t, t[1], t[2], #l)", "2\t5\t6\t3\n");
    try f.expectOutput("print(#take({5, 6}, 9), #take({5, 6}, 0), #take({}, 3))", "2\t0\t0\n");
    try f.expectStop("take({1}, -1)", .argument);
    try f.expectStop("take(\"abc\", 1)", .type);
    // A new list: the old one is as it was.
    try f.expectOutput("local l = {1, 2} local t = take(l, 1) push(t, 9) print(#l, #t)", "2\t2\n");
}

test "cookbook: path joins its parts with / and \"\" is the root; basename is the last part; strip_suffix takes a suffix off, if it is there" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(path(\"chat\", \"a.md\"), path(\"\", \"top.txt\"), path(\"a\", \"\", \"b\", \"c\"), path(\"x\"), path(\"\"))", "chat/a.md\ttop.txt\ta/b/c\tx\t\n");
    // What it makes is a path the store takes.
    try f.expectOutput("print(read(path(\"chat\", \"a.md\")), #ls(path(\"\", \"chat\")))", "hello\t2\n");
    try f.expectStop("path(\"a\", 1)", .type);
    try f.expectOutput("print(basename(\"chat/channels/x.md\"), basename(\"top.txt\"), basename(\"\"))", "x.md\ttop.txt\t\n");
    try f.expectOutput("print(strip_suffix(\"plans.md\", \".md\"), strip_suffix(\"plans.count\", \".md\"), strip_suffix(\".md\", \".md\"), strip_suffix(\"a\", \"\"))", "plans\tplans.count\t\ta\n");
    try f.expectOutput("print(strip_suffix(basename(\"chat/s/plans.md\"), \".md\"))", "plans\n");
}

test "cookbook: read_or reads a file, or answers the default when nothing is there, for one store read; any other failure is still an error" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectOutput("print(read_or(\"top.txt\", \"none\"), read_or(\"missing\", \"none\"), read_or(\"chat/missing.count\", nil))", "top\tnone\tnil\n");
    // One read either way, where exists then read was two.
    var one = f.run("local a = read_or(\"top.txt\", \"\") local b = read_or(\"gone\", \"\") print(10 - budget().reads)", .{ .reads = 10 });
    defer one.deinit();
    try testing.expectEqualStrings("2\n", one.output);
    // A folder is not a missing file: the store's error.
    try f.expectStop("read_or(\"chat\", \"\")", .store);
    // Its bytes are a read's: the read budget holds.
    var over = f.run("print(read_or(\"top.txt\", \"\"))", .{ .read_bytes = 2 });
    defer over.deinit();
    try testing.expectEqual(script.diag.Class.budget, over.stop.?.class);
}
