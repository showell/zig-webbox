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

test "run: a local whose value is a call keeps it, when the call grows the locals' stack (the stack moved under the slot's pointer)" {
    // `local s = f()` took the slot's address before the call, and the
    // call's frame, appended, could move the stack: the value went to the
    // old memory and the slot stayed nil. A frame and nested locals enough
    // that the call's frame outgrows the stack's capacity.
    try expectOutput(
        \\function scan(t)
        \\  return {messages = 1}
        \\end
        \\function topics(rows)
        \\  for name in {"a.md", "b.md"} do
        \\    if true then
        \\      local sid = 1
        \\      local text = "hello"
        \\      local s = scan(text)
        \\      print(s.messages)
        \\    end
        \\  end
        \\end
        \\local rows = {}
        \\topics(rows)
    , "1\n1\n");
    // And deeper: every frame size from 1 to 40, each local a call's value.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "function one(x)\n  return {v = x}\nend\n");
    for (1..41) |n| {
        try src.print(testing.allocator, "function f{d}(p)\n", .{n});
        for (1..n + 1) |k| try src.print(testing.allocator, "  local a{d} = one({d})\n", .{ k, k });
        try src.print(testing.allocator, "  print(a{d}.v)\nend\nf{d}(0)\n", .{ n, n });
        try want.print(testing.allocator, "{d}\n", .{n});
    }
    try expectOutput(src.items, want.items);
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
    // Linux's main thread has 8 MiB, metal's 16 MiB: the worst of both,
    // in Debug (the largest frames), within half the smaller.
    try testing.expect(p.stack_bytes < 4 * 1024 * 1024);
    try testing.expect(w.stack_bytes < 4 * 1024 * 1024);
}

test "run: print evaluates all its arguments before it writes one, as Lua's" {
    try expectOutput("function f() print(\"inner\") return 2 end print(1, f())", "inner\n1\t2\n");
}

test "run: a top-level const is seen by the functions declared after it, and is never assigned (metal-vmm QUEUE 206)" {
    try expectOutput("const LIMIT = 3 function f(n) return n + LIMIT end print(f(1), LIMIT)", "4\t3\n");
    // A table a const names can still change; the name cannot.
    try expectOutput("const SEEN = {} function mark(k) SEEN[k] = true end mark(\"a\") print(count(SEEN))", "1\n");
    // A function's own local of the same name is its own.
    try expectOutput("const N = 1 function f() local N = 2 return N end print(f(), N)", "2\t1\n");
    try expectStop("const X = 1 X = 2", .name, null);
    try expectStop("const X = 1 function f() X = 2 end", .name, null);
    try expectStop("function f() const Y = 1 end", .refused, null);
    try expectStop("if true then const Y = 1 end", .refused, null);
    try expectStop("const X", .syntax, null);
    try expectStop("const X = 1 const X = 2", .name, null);
    // A const may take a builtin's name, as a local may (208(c)).
    try expectOutput("const print = 1 print(print)", "1\n");
    // A function declared before the const does not see it.
    try expectStop("function f() return A end const A = 1 print(f())", .name, null);
    // Called before the const's line has run: an error, not nil.
    try expectStop("const A = g() function g() return f() end function f() return A end", .name, null);
}

// ── 208(a): `..` joined once, in place; `for x in` without a copy ────────

test "run: a chain of `..` built in place never changes a string already made, however it is shared or cut" {
    // `b` extends `a`'s buffer; `c`, from `a` again, must not see `b`'s
    // bytes; a cut of the growing string keeps its own bytes.
    try expectOutput("local a = \"ab\" .. \"c\" local b = a .. \"x\" local c = a .. \"y\" print(a, b, c)", "abc\tabcx\tabcy\n");
    try expectOutput(
        \\local s = ""
        \\for i = 1, 100 do s = s .. i .. "," end
        \\local head = sub(s, 1, 6)
        \\local t = s
        \\s = s .. "END"
        \\print(head, #t, #s, sub(s, -4), sub(t, -4))
    , "1,2,3,\t292\t295\t,END\t100,\n");
    try expectOutput("local s = \"x\" s = s .. s .. s print(s, #(s .. 1 .. 2))", "xxx\t5\n");
    // A shorter string in the growing buffer (an alias taken earlier, a
    // prefix cut by `sub`) joined after the buffer grew past it: a fresh
    // string, never written over the buffer's newer bytes.
    try expectOutput(
        \\local s = ""
        \\for i = 1, 10 do s = s .. "ab" end
        \\local a = s
        \\local p = sub(s, 1, 4)
        \\s = s .. "XY"
        \\local c = a .. "zz"
        \\local d = p .. "!"
        \\print(sub(s, -4), sub(c, -4), d, #s)
    , "abXY\tabzz\tabab!\t22\n");
}

test "run: a chain of `..` stops at the part the nested joins would have stopped at, there" {
    // The innermost pair is checked first: `1 .. {}`, at the second `..`.
    var r = runWith("local x = nil .. 1 .. {}", .{});
    defer r.deinit();
    try testing.expectEqual(script.diag.Class.type, r.stop.?.class);
    try testing.expectEqual(@as(u32, 20), r.stop.?.column);
    try testing.expect(std.mem.indexOf(u8, r.stop.?.message, "empty table") != null);
    var q = runWith("local x = nil .. \"a\"", .{});
    defer q.deinit();
    try testing.expectEqual(@as(u32, 15), q.stop.?.column);
}

test "run: a string built a piece at a time is linear: 20,000 lines in well under the default budgets" {
    var r = runWith("local s = \"\" for i = 1, 20000 do s = s .. \"line \" .. i .. \"\\n\" end print(#s)", .{});
    defer r.deinit();
    try testing.expect(r.finished());
    try testing.expectEqualStrings("208894\n", r.output);
    // About the bytes written, and twice the string's size in arena.
    try testing.expect(r.steps < 1_000_000);
    try testing.expect(r.arena_bytes < 2 * 1024 * 1024);
}

test "run: `for x in l` visits the first #l items, each as it is when reached, and copies nothing" {
    try expectOutput("local l = {1, 2, 3} for x in l do push(l, x) l[3] = 30 print(x) end print(#l)", "1\n2\n30\n6\n");
    // A loop over a list inside a loop over it: no arena for the inner.
    var r = runWith("local l = {} for i = 1, 300 do push(l, i) end local s = 0 for a in l do for b in l do s = s + 1 end end print(s)", .{});
    defer r.deinit();
    try testing.expectEqualStrings("90000\n", r.output);
    try testing.expect(r.arena_bytes < 64 * 1024);
}

// ── 208(c): the language, small but complete ─────────────────────────────

test "run: a script's names may take a builtin's: a local is the value, a call is the script's function first, then the builtin; so a new builtin never breaks an old script" {
    try expectOutput("local lines = 3 print(lines, #lines(\"a\\nb\"))", "3\t2\n");
    try expectOutput("function count(t) return 99 end print(count({1}))", "99\n");
    // Declared after the call: still the script's.
    try expectOutput("print(walk(\"x\")) function walk(p) return p .. \"!\" end", "x!\n");
    // `table` a local: `table.insert` is a field, not Lua's library.
    try expectOutput("local table = {} table.insert = 1 print(table.insert)", "1\n");
    // Lua's library names are the one exception: kept to say what to
    // write instead.
    try expectStop("function pairs(m) return keys(m) end", .name, null);
    try expectStop("local s = 1 s(2)", .refused, null);
    try expectStop("local x = table.insert", .refused, null);
}

test "run: continue skips to the loop's next turn, in every kind of loop, and only its own loop" {
    try expectOutput("for i = 1, 5 do if i % 2 == 0 then continue end print(i) end", "1\n3\n5\n");
    try expectOutput("for x in {1, 2, 3} do if x == 2 then continue end print(x) end", "1\n3\n");
    try expectOutput("local i = 0 while i < 4 do i = i + 1 if i == 2 then continue end print(i) end", "1\n3\n4\n");
    try expectOutput("for i = 1, 2 do for j = 1, 3 do if j == 2 then continue end print(i, j) end end", "1\t1\n1\t3\n2\t1\n2\t3\n");
    try expectOutput("for i = 1, 3 do do if i == 2 then continue end end print(i) end", "1\n3\n");
}

test "run: string escapes: \\r, \\0 and \\xHH as bytes; the rest refused by name" {
    try expectOutput("print(#\"a\\r\\0b\", \"\\x41\\x62\", #\"\\xff\", \"\\x0a\" == \"\\n\")", "4\tAb\t1\ttrue\n");
    try expectStop("print(\"\\x4\")", .syntax, null);
    try expectStop("print(\"\\65\")", .refused, null);
    try expectStop("print(\"\\012\")", .refused, null);
    try expectStop("print(\"\\u{41}\")", .refused, null);
    try expectStop("print(\"\\z\")", .refused, null);
}

test "run: attempt(f, ...) gives f's error as a value, with where it was; a budget is never caught; what f did stays done" {
    try expectOutput(
        \\function half(n) return tonumber(n) // 2 end
        \\local good = attempt(half, "10")
        \\local bad = attempt(half, "ten")
        \\print(good.ok, good.value, bad.ok, bad.class, bad.line, bad.in_function)
        \\function say(s) print(s) end
        \\print(has_key(attempt(say, "said"), "value"))
    , "true\t5\tfalse\targument\t1\thalf\nsaid\nfalse\n");
    // The arguments are evaluated before the attempt: an error there is
    // the run's.
    try expectStop("function f(x) return x end local r = attempt(f, tonumber(\"x\"))", .argument, null);
    // A budget is the run's, inside an attempt too.
    try expectStopWith("function spin() while true do end end local r = attempt(spin)", .budget, .steps, .{ .steps = 10_000 });
    try expectStopWith("function deep(n) return deep(n + 1) end local r = attempt(deep, 1)", .budget, .call_depth, .{});
    // After a caught error the run goes on, its stack and depth as they were.
    try expectOutput(
        \\function boom(n) if n == 0 then return {}[1] end return boom(n - 1) end
        \\local r = attempt(boom, 5)
        \\local s = 0
        \\for i = 1, 3 do s = s + i end
        \\print(r.ok, r.class, r.in_function, s)
    , "false\tindex\tboom\t6\n");
}

test "run: a stop inside a function names it" {
    var r = runWith("function f(x) return x + {} end print(f(1))", .{});
    defer r.deinit();
    try testing.expectEqualStrings("f", r.stop.?.function);
    var top = runWith("local x = 1 + {}", .{});
    defer top.deinit();
    try testing.expectEqualStrings("", top.stop.?.function);
}
