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
