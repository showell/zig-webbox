//! **`yield` AND COPY AT A YIELD** (metal-vmm QUEUE 211, M1): in a one-shot
//! run a `yield` only collects. Each test here runs through the gate, so
//! the output is the walker's too.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

var out_buf: [64 * 1024]u8 = undefined;

fn runWith(src: []const u8, budgets: script.Budgets) script.Result {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    return script.run(threaded.io(), testing.allocator, ".zig-cache/no-root", src, budgets, 1_700_000_000, &out_buf);
}

fn expectOutput(src: []const u8, want: []const u8) !void {
    var r = runWith(src, .{});
    defer r.deinit();
    if (r.stop) |s| {
        std.debug.print("{s}\n  stopped {d}:{d} {t}: {s}\n", .{ src, s.line, s.column, s.class, s.message });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(want, r.output);
}

/// Each round makes about 2 KB it lets go of: 10,000 of them is 20 MB.
const churn =
    \\local kept = {total = 0}
    \\for i = 1, 10000 do
    \\  local junk = {}
    \\  for j = 1, 20 do push(junk, "item " .. j .. " of round " .. i) end
    \\  kept.total = kept.total + #junk
    \\  YIELD
    \\end
    \\print(kept.total)
;

fn churnWith(comptime yield_call: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        const at = std.mem.indexOf(u8, churn, "YIELD").?;
        break :blk churn[0..at] ++ yield_call ++ churn[at + "YIELD".len ..];
    };
}

test "yield: 10,000 yields keep the arena flat, where the same rounds without them run it out" {
    const budgets: script.Budgets = .{ .arena_bytes = 2 * 1024 * 1024, .steps = 100_000_000 };
    var without = runWith(churnWith(""), budgets);
    defer without.deinit();
    try testing.expectEqual(script.diag.Budget.arena, without.stop.?.budget.?);
    var with = runWith(churnWith("yield()"), budgets);
    defer with.deinit();
    if (with.stop) |s| std.debug.print("{s}\n", .{s.message});
    try testing.expect(with.finished());
    try testing.expectEqualStrings("200000\n", with.output);
    // What it holds at the end is what one round keeps, not 20 MB.
    try testing.expect(with.arena_bytes <= 64 * 1024);
}

test "yield: a table reached twice is still one table after a yield" {
    try expectOutput(
        \\local a = {n = 1}
        \\local b = a
        \\local l = {a, a}
        \\yield()
        \\a.n = 2
        \\print(b.n, l[1].n, l[2].n)
        \\l[1].n = 3
        \\print(a.n, l[2].n)
    , "2\t2\t2\n3\t3\n");
}

test "yield: what is kept past the kept budget stops the run, by name" {
    var r = runWith(
        \\local l = {}
        \\for i = 1, 100000 do
        \\  push(l, "abcdefgh" .. i)
        \\  if i % 1000 == 0 then yield() end
        \\end
    , .{ .kept_bytes = 64 * 1024, .steps = 100_000_000 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.kept, r.stop.?.budget.?);
    try testing.expectEqual(@as(u32, 4), r.stop.?.line);
}

test "yield: every root survives it: locals, operands of a `..` chain, a loop's list, a const, a function's frame, attempt's answer" {
    try expectOutput(
        \\const NAMES = {"ann", "bo"}
        \\function inner(x)
        \\  local mine = {x, x .. "!"}
        \\  yield()
        \\  return mine[2] .. tostring(yield()) .. mine[1]
        \\end
        \\function risky(n)
        \\  local t = {deep = {n}}
        \\  yield()
        \\  if n > 1 then return t.deep[1] + "a" end
        \\  return t.deep[1]
        \\end
        \\local s = ""
        \\for name in NAMES do
        \\  s = s .. inner(name) .. ";"
        \\  yield()
        \\end
        \\print(s)
        \\local a = attempt(risky, 1)
        \\local b = attempt(risky, 2)
        \\print(a.ok, a.value, b.ok, b.class)
    , "ann!nilann;bo!nilbo;\n" ++ "true\t1\tfalse\ttype\n");
}

test "yield: a string built in place goes on growing after one" {
    try expectOutput(
        \\local s = ""
        \\for i = 1, 300 do
        \\  s = s .. "x"
        \\  if i % 7 == 0 then yield() end
        \\end
        \\print(#s, sub(s, 1, 3))
    , "300\txxx\n");
}

test "yield: its seconds are 0 or more, and an integer" {
    try expectOutput("yield(0) yield(5) yield() print(1)", "1\n");
    for ([_][]const u8{ "yield(-1)", "yield(\"a\")", "yield(1, 2)" }) |src| {
        var r = runWith(src, .{});
        defer r.deinit();
        try testing.expect(r.stop != null);
    }
}

test "yield: the effects so far are still the run's after one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDir(io, "data", .default_dir);
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    defer testing.allocator.free(root);
    var r = script.run(io, testing.allocator, root, "local p = \"note\" .. \".txt\" replace(p, \"hi\") yield() append(p, \"!\") yield() print(read(p))", .{}, 0, &out_buf);
    defer r.deinit();
    try testing.expect(r.finished());
    try testing.expectEqualStrings("hi!\n", r.output);
    try testing.expectEqual(@as(usize, 2), r.effects.len);
    try testing.expectEqualStrings("note.txt", r.effects[0].path);
    try testing.expectEqualStrings("append", r.effects[1].op);
}

test "yield: inside a list or map literal being built, the literal goes on (the box's review of M1)" {
    // The copy kept only the room a half-built list held, and the next
    // item was appended assuming the room its literal reserved.
    try expectOutput("function f() yield() return 3 end print(#{f(), 2, 4})", "3\n");
    try expectOutput("function f() yield() return 3 end local l = {1, f(), f(), 4} print(l[2] + l[3] + #l)", "10\n");
    try expectOutput("function f() yield() return \"v\" end local m = {a = f(), b = 2, c = f()} print(m.a .. m.c, m.b)", "vv\t2\n");
}
