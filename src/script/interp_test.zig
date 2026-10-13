//! The interpreter's tests: every construct's meaning, every error by
//! class, every budget a hostile script reaches.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

var out_buf: [64 * 1024]u8 = undefined;

fn runWith(src: []const u8, budgets: script.Budgets) script.Result {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    return script.run(threaded.io(), testing.allocator, ".zig-cache/no-root", src, budgets, 1_700_000_000, &out_buf);
}

/// Finishes, and prints exactly `want`.
fn expectOutput(src: []const u8, want: []const u8) !void {
    var r = runWith(src, .{});
    defer r.deinit();
    if (r.stop) |s| {
        std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
        return error.TestUnexpectedResult;
    }
    testing.expectEqualStrings(want, r.output) catch |e| {
        std.debug.print("source: {s}\n", .{src});
        return e;
    };
}

fn expectStop(src: []const u8, class: script.diag.Class, budget: ?script.diag.Budget) !void {
    return expectStopWith(src, class, budget, .{});
}

fn expectStopWith(src: []const u8, class: script.diag.Class, budget: ?script.diag.Budget, budgets: script.Budgets) !void {
    var r = runWith(src, budgets);
    defer r.deinit();
    const s = r.stop orelse {
        std.debug.print("finished, and should have stopped: {s}\n", .{src});
        return error.TestUnexpectedResult;
    };
    if (s.class != class or s.budget != budget) {
        std.debug.print("{s}\n  stopped {s} ({?s}): {s}\n", .{ src, @tagName(s.class), if (s.budget) |b| @tagName(b) else null, s.message });
        return error.TestUnexpectedResult;
    }
}

test "run: values, arithmetic and strings as the README says" {
    try expectOutput("print(1 + 2 * 3, 7 // 2, -7 // 2, 7 % 3, -7 % 3, 7 % -3)", "7\t3\t-4\t1\t2\t-2\n");
    try expectOutput("print(\"a\" .. \"b\" .. 1 .. 2)", "ab12\n");
    try expectOutput("print(nil, true, false, \"s\", -5)", "nil\ttrue\tfalse\ts\t-5\n");
    try expectOutput("print()", "\n");
    try expectOutput("print(#\"abc\", #{1, 2}, #{})", "3\t2\t0\n");
    try expectOutput("print(1 < 2, \"a\" < \"b\", \"b\" <= \"a\", 2 >= 2, 3 > 4)", "true\ttrue\tfalse\ttrue\tfalse\n");
    try expectOutput("print(1 == 1, 1 == \"1\", nil == nil, nil == false, \"x\" ~= \"y\")", "true\tfalse\ttrue\tfalse\ttrue\n");
    try expectOutput("print(-9223372036854775807 - 1)", "-9223372036854775808\n");
    try expectOutput("print(tostring(12) .. tostring(true))", "12true\n");
    try expectOutput("print(now())", "1700000000\n");
}

test "run: truthiness and short-circuits return an operand" {
    try expectOutput("print(nil or \"d\", false or nil, 0 and \"t\", \"\" and 1, nil and never())  function never() print(\"evaluated\") end", "d\tnil\tt\t1\tnil\n");
    try expectOutput("if 0 then print(\"0 is true\") end if \"\" then print(\"empty is true\") end", "0 is true\nempty is true\n");
    try expectOutput("print(not nil, not 0)", "true\tfalse\n");
}

test "run: control flow, loops, break, and a top-level return" {
    try expectOutput("local s = 0 for i = 1, 10 do s = s + i end print(s)", "55\n");
    try expectOutput("local s = \"\" for i = 5, 1, -2 do s = s .. i end print(s)", "531\n");
    try expectOutput("for i = 1, 0 do print(i) end print(\"none\")", "none\n");
    try expectOutput("local n = 0 while true do n = n + 1 if n == 3 then break end end print(n)", "3\n");
    try expectOutput("local l = {1, 2, 3} for x in l do push(l, x) end print(#l)", "6\n");
    try expectOutput("for x in {} do print(x) end print(\"empty\")", "empty\n");
    try expectOutput("print(1) if true then return end print(2)", "1\n");
    // As Lua: `return print(2)` returns the call's value, so it is called.
    try expectOutput("print(1) return print(2)", "1\n2\n");
    try expectOutput("local x = 1 if x == 2 then print(\"a\") elseif x == 1 then print(\"b\") else print(\"c\") end", "b\n");
    try expectOutput("for i = 9223372036854775806, 9223372036854775807 do print(i) end", "9223372036854775806\n9223372036854775807\n");
}

test "run: functions, recursion, forward calls, and a frame of their own" {
    try expectOutput("print(fact(10)) function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end", "3628800\n");
    try expectOutput("function f(a, b) local c = a .. b return c end print(f(\"x\", 1), f(\"y\", 2))", "x1\ty2\n");
    try expectOutput("function none() end print(none())", "nil\n");
    try expectOutput("function f(n) local x = n if n > 0 then f(n - 1) end return x end print(f(3))", "3\n");
}

test "run: lists and maps, their kinds, keys in insertion order, a list as it was when its loop began" {
    try expectOutput("local l = {} l[1] = \"a\" l[#l + 1] = \"b\" l[1] = \"c\" print(l[1], l[2], #l)", "c\tb\t2\n");
    try expectOutput("local m = {} m.b = 1 m[\"a\"] = 2 m.b = 3 for k in keys(m) do print(k, m[k]) end", "b\t3\na\t2\n");
    try expectOutput("local m = {x = {1, 2}} push(m.x, 3) print(#m.x, m.x[3])", "3\t3\n");
    try expectOutput("local a = {1} local b = a push(b, 2) print(#a)", "2\n");
}

test "run: every run-time error by class" {
    const cases = [_]struct { src: []const u8, class: script.diag.Class }{
        .{ .src = "local m = {a = 1} print(m.b)", .class = .index },
        .{ .src = "local l = {1} print(l[2])", .class = .index },
        .{ .src = "local l = {1} print(l[0])", .class = .index },
        .{ .src = "local l = {1} l[3] = 1", .class = .index },
        .{ .src = "local l = {1} l.a = 1", .class = .type },
        .{ .src = "local m = {a = 1} m[1] = 1", .class = .type },
        .{ .src = "local m = {a = 1} m.a = nil", .class = .type },
        .{ .src = "local l = {} l[1] = nil", .class = .type },
        .{ .src = "local t = {} t[true] = 1", .class = .type },
        .{ .src = "print({} == {})", .class = .type },
        .{ .src = "print(1 < \"2\")", .class = .type },
        .{ .src = "print(nil < 1)", .class = .type },
        .{ .src = "print(1 + \"2\")", .class = .type },
        .{ .src = "print(\"a\" .. nil)", .class = .type },
        .{ .src = "print(\"a\" .. {})", .class = .type },
        .{ .src = "print(#{a = 1})", .class = .type },
        .{ .src = "print(#5)", .class = .type },
        .{ .src = "print(-\"a\")", .class = .type },
        .{ .src = "print({1})", .class = .type },
        .{ .src = "print(tostring({}))", .class = .type },
        .{ .src = "local x = 1 print(x[1])", .class = .type },
        .{ .src = "for x in {a = 1} do end", .class = .type },
        .{ .src = "for x in 5 do end", .class = .type },
        .{ .src = "for i = 1, \"x\" do end", .class = .type },
        .{ .src = "for i = 1, 2, 0 do end", .class = .argument },
        .{ .src = "print(1 // 0)", .class = .arithmetic },
        .{ .src = "print(1 % 0)", .class = .arithmetic },
        .{ .src = "print(9223372036854775807 + 1)", .class = .arithmetic },
        .{ .src = "print((-9223372036854775807 - 1) // -1)", .class = .arithmetic },
        .{ .src = "print(-(-9223372036854775807 - 1))", .class = .arithmetic },
        .{ .src = "print(9223372036854775807 * 2)", .class = .arithmetic },
        .{ .src = "print(now(1))", .class = .argument },
    };
    for (cases) |case| try expectStop(case.src, case.class, null);
}

test "run: a stop says its line and column" {
    var r = runWith("local a = 1\nlocal b = 2\n  print(a // (b - 2))", .{});
    defer r.deinit();
    try testing.expectEqual(@as(u32, 3), r.stop.?.line);
    try testing.expectEqual(@as(u32, 11), r.stop.?.column);
    try testing.expectEqualStrings("", r.output);
}

test "run: each budget stops a script that runs into it, and names it" {
    try expectStop("while true do end", .budget, .steps);
    try expectStop("for i = 1, 9223372036854775807 do end", .budget, .steps);
    try expectStop("function f(n) return f(n + 1) end f(1)", .budget, .call_depth);
    // A string that doubles: `..` charges a step per byte it makes, so the
    // steps run out first; with steps to spare, the arena does.
    try expectStop("local s = \"x\" while true do s = s .. s end", .budget, .steps);
    try expectStopWith("local s = \"x\" while true do s = s .. s end", .budget, .arena, .{ .steps = 1_000_000_000 });
    try expectStop("local l = {} while true do push(l, 1) end", .budget, .arena);
    try expectStopWith("local l = {} while true do push(l, \"some bytes\") end", .budget, .arena, .{ .steps = 100_000_000, .arena_bytes = 64 * 1024 });
    try expectStop("while true do print(\"a line of output\") end", .budget, .output);
    try expectStopWith("print(1)", .budget, .source, .{ .source_bytes = 4 });
    try expectStopWith("print((((1))))", .budget, .nesting, .{ .nesting = 3 });
    try expectStopWith("for i = 1, 100 do end", .budget, .steps, .{ .steps = 50 });
}

test "run: output past its budget keeps what fit, and stops" {
    var r = runWith("print(\"0123456789\") print(\"abcdefghij\")", .{ .output_bytes = 15 });
    defer r.deinit();
    try testing.expectEqual(script.diag.Budget.output, r.stop.?.budget.?);
    try testing.expectEqualStrings("0123456789\nabcd", r.output);
}

test "run: the same source and now give the same output and the same steps, byte for byte" {
    const src = "local m = {} for i = 1, 50 do m[\"k\" .. (i * 7919 % 101)] = i end for k in keys(m) do print(k, m[k]) end";
    var a = runWith(src, .{});
    defer a.deinit();
    const first = try testing.allocator.dupe(u8, a.output);
    defer testing.allocator.free(first);
    var b = runWith(src, .{});
    defer b.deinit();
    try testing.expectEqualStrings(first, b.output);
    try testing.expectEqual(a.steps, b.steps);
}

test "run: the Zig stack the deepest parse and the deepest walk take, measured (README, \"The Zig stack\")" {
    // The deepest parse: the nesting budget's worth of parentheses (each
    // enters an expression and its operand: two of the budget's 200).
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "local x = ");
    for (0..97) |_| try src.append(testing.allocator, '(');
    try src.append(testing.allocator, '1');
    for (0..97) |_| try src.append(testing.allocator, ')');
    var p = runWith(src.items, .{});
    defer p.deinit();
    if (p.stop) |st| std.debug.print("{s}\n", .{st.message});
    try testing.expect(p.finished());
    // The deepest walk: the call-depth budget's worth of calls, each
    // evaluating an expression nested as deep as the parse allows.
    const levels = 60;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, "function f(n) if n == 0 then return 0 end return ");
    // `0 + (0 + (... f(n - 1)))`: each level a binary node the walk
    // recurses into, as deep as the nesting budget lets it parse.
    for (0..levels) |_| try deep.appendSlice(testing.allocator, "0 + (");
    try deep.appendSlice(testing.allocator, "f(n - 1)");
    for (0..levels) |_| try deep.append(testing.allocator, ')');
    try deep.appendSlice(testing.allocator, " end print(f(63))");
    // 64 calls of 60 levels each is past the depth budget: the walk stops
    // there, at the deepest it may go, and that is what is measured.
    var w = runWith(deep.items, .{});
    defer w.deinit();
    try testing.expectEqual(script.diag.Budget.depth, w.stop.?.budget.?);
    if (p.stop) |s| std.debug.print("{s}\n", .{s.message});
    if (@import("builtin").mode == .Debug) std.debug.print("script stack: deepest parse {d} bytes ({d} a level of 200), deepest walk {d} bytes ({d} a level of 2,000)\n", .{ p.stack_bytes, p.stack_bytes / 200, w.stack_bytes, w.stack_bytes / 2000 });
    // Linux's main thread has 8 MiB, metal's 16 MiB: the worst of both,
    // in Debug (the largest frames), within half the smaller.
    try testing.expect(p.stack_bytes < 4 * 1024 * 1024);
    try testing.expect(w.stack_bytes < 4 * 1024 * 1024);
}
