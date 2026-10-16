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
