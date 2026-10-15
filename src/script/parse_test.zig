//! The parser's tests.

// ── tests ────────────────────────────────────────────────────────────────

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const parse = @import("parse.zig").parse;
const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, src: []const u8) !ast.Program {
    var stop: ?diag.Stop = null;
    return parse(arena, src, 200, &stop) catch |e| {
        if (stop) |s| std.debug.print("{d}:{d} {s}: {s}\n", .{ s.line, s.column, @tagName(s.class), s.message });
        return e;
    };
}

fn parseStop(src: []const u8) !diag.Stop {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stop: ?diag.Stop = null;
    if (parse(arena.allocator(), src, 200, &stop)) |_| {
        std.debug.print("parsed, and should not have: {s}\n", .{src});
        return error.TestUnexpectedResult;
    } else |e| switch (e) {
        error.Parse => {},
        else => return e,
    }
    var s = stop.?;
    s.message = try testing.allocator.dupe(u8, s.message);
    return s;
}

test "parse: every construct of the language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseOk(arena.allocator(),
        \\-- a script
        \\local n = 0
        \\local l = {1, 2, 3}
        \\local m = {a = 1, ["b c"] = 2}
        \\local e = {}
        \\if n == 0 then n = 1 elseif n < 0 then n = -1 else n = 2 end
        \\while n < 10 do n = n + 1; if n == 5 then break end end
        \\for i = 1, 10 do n = n + i end
        \\for i = 10, 1, -1 do n = n - i end
        \\for x in l do push(e, x * 2) end
        \\do local inner = "x" .. n end
        \\m.a = m["b c"] // 2 % 7
        \\l[#l + 1] = 4
        \\print(fact(5), not true and nil or "s")
        \\function fact(k)
        \\  if k <= 1 then return 1 end
        \\  return k * fact(k - 1)
        \\end
        \\return
    );
    try testing.expectEqual(@as(usize, 1), p.functions.len);
    try testing.expectEqualStrings("fact", p.functions[0].name);
    try testing.expectEqual(@as(u16, 1), p.functions[0].params);
    try testing.expect(p.main.frame >= 7);
}

test "parse: precedence as Lua's: `..` to the right, the rest to the left, unary above binary, `and` above `or`" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseOk(arena.allocator(), "local x = 1 + 2 * 3 - 4 local s = \"a\" .. \"b\" .. \"c\" local b = not 1 == 2 or 3 and 4 local y = -2 * 3");
    // 1 + 2*3 - 4 is ((1 + (2*3)) - 4)
    const x = p.main.body[0].kind.local.value.?;
    try testing.expectEqual(ast.BinOp.sub, x.kind.binary.op);
    try testing.expectEqual(ast.BinOp.add, x.kind.binary.left.kind.binary.op);
    try testing.expectEqual(ast.BinOp.mul, x.kind.binary.left.kind.binary.right.kind.binary.op);
    // "a" .. ("b" .. "c")
    const s = p.main.body[1].kind.local.value.?;
    try testing.expectEqual(ast.Expr.Kind.string, std.meta.activeTag(s.kind.binary.left.kind));
    try testing.expectEqual(ast.BinOp.concat, s.kind.binary.right.kind.binary.op);
    // ((not 1) == 2) or (3 and 4)
    const b = p.main.body[2].kind.local.value.?;
    try testing.expectEqual(ast.BinOp.@"or", b.kind.binary.op);
    try testing.expectEqual(ast.BinOp.eq, b.kind.binary.left.kind.binary.op);
    try testing.expectEqual(ast.UnOp.not, b.kind.binary.left.kind.binary.left.kind.unary.op);
    try testing.expectEqual(ast.BinOp.@"and", b.kind.binary.right.kind.binary.op);
    // (-2) * 3, the literal folded
    const y = p.main.body[3].kind.local.value.?;
    try testing.expectEqual(@as(i64, -2), y.kind.binary.left.kind.int);
}

test "parse: what is refused, and the class it is refused as" {
    const cases = [_]struct { src: []const u8, class: diag.Class, says: []const u8 }{
        // names
        .{ .src = "x = 1", .class = .name, .says = "no local `x`" },
        .{ .src = "print(y)", .class = .name, .says = "no local `y`" },
        .{ .src = "local a = 1 local a = 2", .class = .name, .says = "already" },
        .{ .src = "local s = 1 function f() return s end", .class = .name, .says = "only its own" },
        .{ .src = "nosuch(1)", .class = .name, .says = "no function `nosuch`" },
        .{ .src = "function f() end function f() end", .class = .name, .says = "already declared" },
        .{ .src = "function attempt() end", .class = .name, .says = "language's own" },
        .{ .src = "local x = attempt(nosuch)", .class = .name, .says = "no function `nosuch`" },
        .{ .src = "function f() end local x = attempt(f())", .class = .syntax, .says = "without its own parentheses" },
        .{ .src = "continue", .class = .syntax, .says = "outside a loop" },
        .{ .src = "function f(a) end f(1, 2)", .class = .argument, .says = "takes 1" },
        // Lua's own, by name
        .{ .src = "local s = string.upper(\"a\")", .class = .refused, .says = "standard library" },
        .{ .src = "table.insert(l, 1)", .class = .refused, .says = "standard library" },
        .{ .src = "for k, v in pairs(m) do end", .class = .refused, .says = "several loop names" },
        .{ .src = "local l = {} for x in ipairs(l) do end", .class = .refused, .says = "ipairs" },
        .{ .src = "pcall(f)", .class = .refused, .says = "pcall" },
        .{ .src = "local a, b = 1, 2", .class = .refused, .says = "several locals" },
        .{ .src = "local a = 1 local b = 2 a, b = b, a", .class = .refused, .says = "multiple assignment" },
        .{ .src = "function f() return 1, 2 end", .class = .refused, .says = "multiple returns" },
        .{ .src = "local f = function() end", .class = .refused, .says = "not values" },
        .{ .src = "local function f() end", .class = .refused, .says = "local function" },
        .{ .src = "function f() function g() end end", .class = .refused, .says = "top-level" },
        .{ .src = "if true then function g() end end", .class = .refused, .says = "top-level" },
        .{ .src = "function t.f() end", .class = .refused, .says = "tables" },
        .{ .src = "local x = print", .class = .refused, .says = "not a value" },
        .{ .src = "local s = 1 s(2)", .class = .refused, .says = "is a local" },
        .{ .src = "print \"hi\"", .class = .refused, .says = "parentheses" },
        .{ .src = "local x <const> = 1", .class = .refused, .says = "attributes" },
        // tables
        .{ .src = "local t = {1, a = 2}", .class = .type, .says = "mixes" },
        .{ .src = "local t = {a = 1, 2}", .class = .type, .says = "mixes" },
        .{ .src = "local t = {1, nil}", .class = .type, .says = "nil" },
        .{ .src = "local t = {a = 1, a = 2}", .class = .index, .says = "twice" },
        .{ .src = "local t = {[1] = 2}", .class = .refused, .says = "keys" },
        // plain syntax
        .{ .src = "if true then", .class = .syntax, .says = "`end`" },
        .{ .src = "end", .class = .syntax, .says = "nothing open" },
        .{ .src = "break", .class = .syntax, .says = "outside a loop" },
        .{ .src = "return 1 print(2)", .class = .syntax, .says = "last statement" },
        .{ .src = "1 + 2", .class = .syntax, .says = "a call or an assignment" },
        .{ .src = "local x = )", .class = .syntax, .says = "expected a value" },
        .{ .src = "local x = 1 x", .class = .syntax, .says = "a call or an assignment" },
        .{ .src = "local x = (1", .class = .syntax, .says = "`)`" },
        .{ .src = "print(1) = 2", .class = .syntax, .says = "can be assigned" },
        // lexer refusals come through with their class
        .{ .src = "local x = 1.5", .class = .refused, .says = "float" },
    };
    for (cases) |case| {
        const s = try parseStop(case.src);
        defer testing.allocator.free(s.message);
        if (s.class != case.class or std.mem.indexOf(u8, s.message, case.says) == null) {
            std.debug.print("{s}\n  got {s}: {s}\n", .{ case.src, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "parse: a source nested past the nesting budget stops as that budget, however it nests" {
    // ("- " with its space: "--" is a comment.)
    for ([_][]const u8{ "(", "{", "- ", "not ", "# " }) |opener| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "local x = ");
        for (0..10_000) |_| try src.appendSlice(testing.allocator, opener);
        const s = try parseStop(src.items);
        defer testing.allocator.free(s.message);
        try testing.expectEqual(diag.Class.budget, s.class);
        try testing.expectEqual(diag.Budget.nesting, s.budget.?);
    }
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    for (0..10_000) |_| try deep.appendSlice(testing.allocator, "do ");
    const s = try parseStop(deep.items);
    defer testing.allocator.free(s.message);
    try testing.expectEqual(diag.Budget.nesting, s.budget.?);
}

test "parse: a name is the innermost declared before it; a block's locals end with it; `local x = x` reads the outer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseOk(arena.allocator(), "local x = 1 do local x = x end print(x)");
    const outer = p.main.body[0].kind.local.slot;
    const inner = p.main.body[1].kind.do[0].kind.local;
    try testing.expect(inner.slot != outer);
    try testing.expectEqual(outer, inner.value.?.kind.local);
    try testing.expectEqual(outer, p.main.body[2].kind.call.kind.call.args[0].kind.local);
    const s = try parseStop("do local y = 1 end print(y)");
    defer testing.allocator.free(s.message);
    try testing.expectEqual(diag.Class.name, s.class);
}
