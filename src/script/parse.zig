//! **THE PARSER**: tokens to `ast.Program`, names resolved, Lua's
//! constructs this language does not take refused by name, and its depth
//! held to the nesting budget so no source can run the parser off its stack.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");
const diag = @import("diag.zig");

const Tag = lex.Tag;
const Token = lex.Token;

pub const Error = error{ Parse, OutOfMemory };

/// Lua's library tables and functions a writer will reach for, each with
/// what to write instead.
const lua_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "string", "the standard library is not in this language: call the builtin, `upper(s)`, not `string.upper(s)`" },
    .{ "table", "the standard library is not in this language: call the builtin, `push(l, x)`, not `table.insert(l, x)`" },
    .{ "math", "the standard library is not in this language" },
    .{ "os", "the standard library is not in this language: `now()` is the only time" },
    .{ "io", "the standard library is not in this language: `read`, `print`" },
    .{ "utf8", "the standard library is not in this language" },
    .{ "coroutine", "coroutines are not in this language" },
    .{ "debug", "the standard library is not in this language" },
    .{ "package", "the standard library is not in this language" },
    .{ "require", "`require` is not in this language" },
    .{ "pcall", "`pcall` is not in this language: an error stops the script" },
    .{ "xpcall", "`xpcall` is not in this language: an error stops the script" },
    .{ "error", "`error` is not in this language" },
    .{ "pairs", "`pairs` is not in this language: `for k in keys(m) do ... m[k] ... end`" },
    .{ "ipairs", "`ipairs` is not in this language: `for x in list do ... end`, or `for i = 1, #list do`" },
    .{ "setmetatable", "metatables are not in this language" },
    .{ "getmetatable", "metatables are not in this language" },
    .{ "type", "`type` is not in this language" },
    .{ "select", "varargs are not in this language" },
    .{ "unpack", "multiple values are not in this language" },
    .{ "load", "`load` is not in this language" },
    .{ "dofile", "`dofile` is not in this language" },
    .{ "rawget", "metatables are not in this language" },
    .{ "rawset", "metatables are not in this language" },
});

const Local = struct { name: []const u8, slot: u16, depth: u16 };

/// One function's names: a stack of locals, each in the block it was
/// declared in.
const Frame = struct {
    locals: std.ArrayList(Local) = .empty,
    depth: u16 = 0,
    slots: u16 = 0,
    loops: u16 = 0,
};

const PendingCall = struct { call: *ast.Call, name: []const u8, pos: ast.Pos };

pub const Parser = struct {
    alloc: std.mem.Allocator,
    lexer: lex.Lexer,
    tok: Token,
    ahead: ?Token = null,
    stop: ?diag.Stop = null,
    max_nesting: u32,
    nesting: u32 = 0,
    frame: Frame = .{},
    /// Whether the frame is the script's own (top level) or a function's.
    in_function: bool = false,
    functions: std.ArrayList(ast.Function) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    pending: std.ArrayList(PendingCall) = .empty,
    /// The lowest frame address the parse reached (README, "The Zig stack").
    stack_low: usize = std.math.maxInt(usize),

    fn failAt(self: *Parser, pos: ast.Pos, class: diag.Class, message: []const u8) Error {
        self.stop = .{ .line = pos.line, .column = pos.column, .class = class, .message = message };
        return error.Parse;
    }

    fn failf(self: *Parser, pos: ast.Pos, class: diag.Class, comptime fmt: []const u8, args: anytype) Error {
        return self.failAt(pos, class, try std.fmt.allocPrint(self.alloc, fmt, args));
    }

    fn here(self: *const Parser) ast.Pos {
        return .{ .line = self.tok.line, .column = self.tok.column };
    }

    fn advance(self: *Parser) Error!void {
        if (self.ahead) |t| {
            self.tok = t;
            self.ahead = null;
            return;
        }
        self.tok = self.lexer.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Lex => {
                const le = self.lexer.err.?;
                return self.failAt(.{ .line = le.line, .column = le.column }, if (le.refused) .refused else .syntax, le.message);
            },
        };
    }

    fn peek(self: *Parser) Error!Token {
        if (self.ahead == null) {
            self.ahead = self.lexer.next() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Lex => {
                    const le = self.lexer.err.?;
                    return self.failAt(.{ .line = le.line, .column = le.column }, if (le.refused) .refused else .syntax, le.message);
                },
            };
        }
        return self.ahead.?;
    }

    fn expect(self: *Parser, tag: Tag, what: []const u8) Error!Token {
        if (self.tok.tag != tag) return self.failf(self.here(), .syntax, "expected {s}, found {s}", .{ what, describe(self.tok) });
        const t = self.tok;
        try self.advance();
        return t;
    }

    fn enter(self: *Parser) Error!void {
        self.stack_low = @min(self.stack_low, @frameAddress());
        self.nesting += 1;
        if (self.nesting > self.max_nesting) {
            self.stop = .{ .line = self.tok.line, .column = self.tok.column, .class = .budget, .budget = .nesting, .message = "the source nests deeper than the nesting budget" };
            return error.Parse;
        }
    }

    fn leave(self: *Parser) void {
        self.nesting -= 1;
    }

    fn new(self: *Parser, comptime T: type, v: T) Error!*T {
        const p = try self.alloc.create(T);
        p.* = v;
        return p;
    }

    // ── names ────────────────────────────────────────────────────────────

    fn lookup(self: *const Parser, name: []const u8) ?u16 {
        var i = self.frame.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.frame.locals.items[i];
            if (std.mem.eql(u8, l.name, name)) return l.slot;
        }
        return null;
    }

    fn declare(self: *Parser, name: []const u8, pos: ast.Pos) Error!u16 {
        if (std.meta.stringToEnum(ast.Builtin, name) != null) return self.failf(pos, .name, "`{s}` is a builtin: a local cannot take its name", .{name});
        var i = self.frame.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.frame.locals.items[i];
            if (l.depth < self.frame.depth) break;
            if (std.mem.eql(u8, l.name, name)) return self.failf(pos, .name, "`{s}` is already a local in this block", .{name});
        }
        if (self.frame.slots == std.math.maxInt(u16)) return self.failAt(pos, .syntax, "too many locals in one function");
        const slot = self.frame.slots;
        self.frame.slots += 1;
        try self.frame.locals.append(self.alloc, .{ .name = name, .slot = slot, .depth = self.frame.depth });
        return slot;
    }

    fn unknownName(self: *Parser, name: []const u8, pos: ast.Pos) Error {
        if (lua_names.get(name)) |why| return self.failAt(pos, .refused, why);
        if (self.in_function) return self.failf(pos, .name, "no local `{s}` here: a function sees only its own parameters and locals, not the script's", .{name});
        return self.failf(pos, .name, "no local `{s}`: declare it with `local {s} = ...` (there are no globals)", .{ name, name });
    }

    // ── blocks and statements ────────────────────────────────────────────

    fn blockEnds(tag: Tag) bool {
        return switch (tag) {
            .eof, .kw_end, .kw_else, .kw_elseif => true,
            else => false,
        };
    }

    /// Statements up to the end of a block, in a scope of their own.
    fn block(self: *Parser) Error![]ast.Stmt {
        try self.enter();
        defer self.leave();
        self.frame.depth += 1;
        const mark = self.frame.locals.items.len;
        defer {
            self.frame.locals.shrinkRetainingCapacity(mark);
            self.frame.depth -= 1;
        }
        var out: std.ArrayList(ast.Stmt) = .empty;
        while (!blockEnds(self.tok.tag)) {
            if (self.tok.tag == .semicolon) {
                try self.advance();
                continue;
            }
            const s = try self.statement();
            try out.append(self.alloc, s);
            if (s.kind == .@"return") {
                while (self.tok.tag == .semicolon) try self.advance();
                if (!blockEnds(self.tok.tag)) return self.failAt(self.here(), .syntax, "`return` must be the last statement of its block");
                break;
            }
        }
        return out.items;
    }

    fn statement(self: *Parser) Error!ast.Stmt {
        try self.enter();
        defer self.leave();
        const pos = self.here();
        switch (self.tok.tag) {
            .kw_local => {
                try self.advance();
                if (self.tok.tag == .kw_function) return self.failAt(pos, .refused, "`local function` is not in this language: functions are declared at the top level with `function name(...)`");
                const name = (try self.expect(.name, "a name after `local`")).text;
                if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "declaring several locals at once is not in this language: one `local` each");
                if (self.tok.tag == .lt) return self.failAt(self.here(), .refused, "attributes (`<const>`, `<close>`) are not in this language");
                var value: ?*ast.Expr = null;
                if (self.tok.tag == .assign) {
                    try self.advance();
                    value = try self.expr();
                    if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple values are not in this language");
                }
                // Declared after its value: `local x = x` reads an outer x.
                const slot = try self.declare(name, pos);
                return .{ .pos = pos, .kind = .{ .local = .{ .slot = slot, .value = value } } };
            },
            .kw_if => return self.ifStatement(pos),
            .kw_while => {
                try self.advance();
                const cond = try self.expr();
                _ = try self.expect(.kw_do, "`do` after the `while` condition");
                self.frame.loops += 1;
                const body = try self.block();
                self.frame.loops -= 1;
                _ = try self.expect(.kw_end, "`end` to close the `while`");
                return .{ .pos = pos, .kind = .{ .@"while" = .{ .cond = cond, .body = body } } };
            },
            .kw_for => return self.forStatement(pos),
            .kw_do => {
                try self.advance();
                const body = try self.block();
                _ = try self.expect(.kw_end, "`end` to close the `do`");
                return .{ .pos = pos, .kind = .{ .do = body } };
            },
            .kw_return => {
                try self.advance();
                var value: ?*ast.Expr = null;
                if (!blockEnds(self.tok.tag) and self.tok.tag != .semicolon) {
                    value = try self.expr();
                    if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple returns are not in this language: return a list or a map");
                }
                return .{ .pos = pos, .kind = .{ .@"return" = value } };
            },
            .kw_break => {
                try self.advance();
                if (self.frame.loops == 0) return self.failAt(pos, .syntax, "`break` outside a loop");
                return .{ .pos = pos, .kind = .@"break" };
            },
            .kw_function => {
                if (self.in_function or self.frame.depth > 1) return self.failAt(pos, .refused, "functions are top-level statements only: nested functions and closures are not in this language");
                try self.function(pos);
                return .{ .pos = pos, .kind = .{ .do = &.{} } };
            },
            else => {
                const target = try self.suffixed();
                if (self.tok.tag == .assign) {
                    switch (target.kind) {
                        .local, .index => {},
                        else => return self.failAt(target.pos, .syntax, "only a local or an element `t[k]`, `t.k` can be assigned"),
                    }
                    try self.advance();
                    const value = try self.expr();
                    if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple values are not in this language");
                    return .{ .pos = pos, .kind = .{ .assign = .{ .target = target, .value = value } } };
                }
                if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple assignment is not in this language: one assignment each");
                if (target.kind != .call) return self.failf(pos, .syntax, "a statement must be a call or an assignment, found {s}", .{describe(self.tok)});
                return .{ .pos = pos, .kind = .{ .call = target } };
            },
        }
    }

    fn ifStatement(self: *Parser, pos: ast.Pos) Error!ast.Stmt {
        try self.advance();
        var arms: std.ArrayList(ast.Arm) = .empty;
        const cond = try self.expr();
        _ = try self.expect(.kw_then, "`then` after the `if` condition");
        try arms.append(self.alloc, .{ .cond = cond, .body = try self.block() });
        var otherwise: ?[]ast.Stmt = null;
        while (true) {
            switch (self.tok.tag) {
                .kw_elseif => {
                    try self.advance();
                    const c = try self.expr();
                    _ = try self.expect(.kw_then, "`then` after the `elseif` condition");
                    try arms.append(self.alloc, .{ .cond = c, .body = try self.block() });
                },
                .kw_else => {
                    try self.advance();
                    otherwise = try self.block();
                    _ = try self.expect(.kw_end, "`end` to close the `if`");
                    break;
                },
                else => {
                    _ = try self.expect(.kw_end, "`end` to close the `if`");
                    break;
                },
            }
        }
        return .{ .pos = pos, .kind = .{ .@"if" = .{ .arms = arms.items, .otherwise = otherwise } } };
    }

    fn forStatement(self: *Parser, pos: ast.Pos) Error!ast.Stmt {
        try self.advance();
        const name_tok = try self.expect(.name, "a name after `for`");
        const name_pos: ast.Pos = .{ .line = name_tok.line, .column = name_tok.column };
        if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "several loop names are not in this language: `for k in keys(m) do ... m[k] ... end`");
        if (self.tok.tag == .assign) {
            try self.advance();
            const from = try self.expr();
            _ = try self.expect(.comma, "`,` between the loop's start and end");
            const to = try self.expr();
            var step: ?*ast.Expr = null;
            if (self.tok.tag == .comma) {
                try self.advance();
                step = try self.expr();
            }
            _ = try self.expect(.kw_do, "`do` after the `for`");
            self.frame.depth += 1;
            const mark = self.frame.locals.items.len;
            const slot = try self.declare(name_tok.text, name_pos);
            self.frame.loops += 1;
            const body = try self.block();
            self.frame.loops -= 1;
            self.frame.locals.shrinkRetainingCapacity(mark);
            self.frame.depth -= 1;
            _ = try self.expect(.kw_end, "`end` to close the `for`");
            return .{ .pos = pos, .kind = .{ .numeric_for = .{ .slot = slot, .from = from, .to = to, .step = step, .body = body } } };
        }
        _ = try self.expect(.kw_in, "`=` or `in` after the loop's name");
        const list = try self.expr();
        _ = try self.expect(.kw_do, "`do` after the `for`");
        self.frame.depth += 1;
        const mark = self.frame.locals.items.len;
        const slot = try self.declare(name_tok.text, name_pos);
        self.frame.loops += 1;
        const body = try self.block();
        self.frame.loops -= 1;
        self.frame.locals.shrinkRetainingCapacity(mark);
        self.frame.depth -= 1;
        _ = try self.expect(.kw_end, "`end` to close the `for`");
        return .{ .pos = pos, .kind = .{ .list_for = .{ .slot = slot, .list = list, .body = body } } };
    }

    fn function(self: *Parser, pos: ast.Pos) Error!void {
        try self.advance();
        const name_tok = try self.expect(.name, "the function's name");
        const name = name_tok.text;
        if (self.tok.tag == .dot) return self.failAt(self.here(), .refused, "functions in tables are not in this language: functions are not values");
        if (std.meta.stringToEnum(ast.Builtin, name) != null) return self.failf(pos, .name, "`{s}` is a builtin: a function cannot take its name", .{name});
        if (self.function_names.contains(name)) return self.failf(pos, .name, "a function `{s}` is already declared", .{name});
        const index: u32 = @intCast(self.functions.items.len);
        try self.function_names.put(self.alloc, name, index);
        // Reserved now, so it may call itself.
        try self.functions.append(self.alloc, undefined);

        const saved = self.frame;
        self.frame = .{};
        self.in_function = true;
        defer {
            self.frame = saved;
            self.in_function = false;
        }
        _ = try self.expect(.lparen, "`(` after the function's name");
        self.frame.depth = 1;
        var params: u16 = 0;
        if (self.tok.tag != .rparen) {
            while (true) {
                if (self.tok.tag == .dot_dot) return self.failAt(self.here(), .refused, "varargs are not in this language");
                const p = try self.expect(.name, "a parameter's name");
                _ = try self.declare(p.text, .{ .line = p.line, .column = p.column });
                params += 1;
                if (self.tok.tag != .comma) break;
                try self.advance();
            }
        }
        _ = try self.expect(.rparen, "`)` after the parameters");
        const body = try self.block();
        _ = try self.expect(.kw_end, "`end` to close the function");
        self.functions.items[index] = .{ .name = name, .pos = pos, .params = params, .frame = self.frame.slots, .body = body };
    }

    // ── expressions ──────────────────────────────────────────────────────

    pub fn expr(self: *Parser) Error!*ast.Expr {
        return self.binary(0);
    }

    const Level = struct { op: ast.BinOp, prec: u8, right: bool = false };

    fn binop(tag: Tag) ?Level {
        return switch (tag) {
            .kw_or => .{ .op = .@"or", .prec = 1 },
            .kw_and => .{ .op = .@"and", .prec = 2 },
            .lt => .{ .op = .lt, .prec = 3 },
            .le => .{ .op = .le, .prec = 3 },
            .gt => .{ .op = .gt, .prec = 3 },
            .ge => .{ .op = .ge, .prec = 3 },
            .eq_eq => .{ .op = .eq, .prec = 3 },
            .not_eq => .{ .op = .ne, .prec = 3 },
            .dot_dot => .{ .op = .concat, .prec = 4, .right = true },
            .plus => .{ .op = .add, .prec = 5 },
            .minus => .{ .op = .sub, .prec = 5 },
            .star => .{ .op = .mul, .prec = 6 },
            .slash_slash => .{ .op = .idiv, .prec = 6 },
            .percent => .{ .op = .mod, .prec = 6 },
            else => null,
        };
    }

    /// Precedence climbing: operators of at least `min` bind here; `..`
    /// binds to the right, every other to the left.
    fn binary(self: *Parser, min: u8) Error!*ast.Expr {
        try self.enter();
        defer self.leave();
        var left = try self.unary();
        while (binop(self.tok.tag)) |lv| {
            if (lv.prec < min) break;
            const pos = self.here();
            try self.advance();
            const right = try self.binary(if (lv.right) lv.prec else lv.prec + 1);
            left = try self.new(ast.Expr, .{ .pos = pos, .kind = .{ .binary = .{ .op = lv.op, .left = left, .right = right } } });
        }
        return left;
    }

    fn unary(self: *Parser) Error!*ast.Expr {
        const pos = self.here();
        const op: ?ast.UnOp = switch (self.tok.tag) {
            .kw_not => .not,
            .minus => .neg,
            .hash => .len,
            else => null,
        };
        if (op) |o| {
            try self.enter();
            defer self.leave();
            try self.advance();
            // A literal's minus is the literal's: -9223372036854775808 cannot
            // be written, but every other negative can, without overflow.
            const operand = try self.unary();
            if (o == .neg and operand.kind == .int) {
                operand.kind.int = std.math.negate(operand.kind.int) catch unreachable;
                operand.pos = pos;
                return operand;
            }
            return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .unary = .{ .op = o, .operand = operand } } });
        }
        return self.suffixed();
    }

    fn suffixed(self: *Parser) Error!*ast.Expr {
        try self.enter();
        defer self.leave();
        var e = try self.primary();
        while (true) {
            const pos = self.here();
            switch (self.tok.tag) {
                .dot => {
                    try self.advance();
                    const key = try self.expect(.name, "a name after `.`");
                    const k = try self.new(ast.Expr, .{ .pos = .{ .line = key.line, .column = key.column }, .kind = .{ .string = key.text } });
                    e = try self.new(ast.Expr, .{ .pos = pos, .kind = .{ .index = .{ .obj = e, .key = k } } });
                },
                .lbracket => {
                    try self.advance();
                    const k = try self.expr();
                    _ = try self.expect(.rbracket, "`]`");
                    e = try self.new(ast.Expr, .{ .pos = pos, .kind = .{ .index = .{ .obj = e, .key = k } } });
                },
                .lparen => return self.failAt(pos, .refused, "only a name can be called: functions are not values"),
                .string, .lbrace => if (e.kind == .call) return e else return self.failAt(pos, .refused, "a call needs its parentheses: `f(\"x\")`, not `f \"x\"`"),
                else => return e,
            }
        }
    }

    fn primary(self: *Parser) Error!*ast.Expr {
        const pos = self.here();
        const t = self.tok;
        switch (t.tag) {
            .kw_nil => {
                try self.advance();
                return self.new(ast.Expr, .{ .pos = pos, .kind = .nil });
            },
            .kw_true, .kw_false => {
                try self.advance();
                return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .boolean = t.tag == .kw_true } });
            },
            .int => {
                try self.advance();
                return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .int = t.int } });
            },
            .string => {
                try self.advance();
                return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .string = t.text } });
            },
            .lparen => {
                try self.advance();
                const e = try self.expr();
                _ = try self.expect(.rparen, "`)`");
                return e;
            },
            .lbrace => return self.table(pos),
            .kw_function => return self.failAt(pos, .refused, "functions are not values in this language: declare one at the top level with `function name(...)`"),
            .name => {
                try self.advance();
                if (self.tok.tag == .lparen) return self.call(t.text, pos);
                if (self.tok.tag == .string or self.tok.tag == .lbrace) return self.failAt(self.here(), .refused, "a call needs its parentheses: `f(\"x\")`, not `f \"x\"`");
                if (std.meta.stringToEnum(ast.Builtin, t.text) != null) return self.failf(pos, .refused, "`{s}` is a builtin, not a value: call it, `{s}(...)`", .{ t.text, t.text });
                const slot = self.lookup(t.text) orelse return self.unknownName(t.text, pos);
                return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .local = slot } });
            },
            else => return self.failf(pos, .syntax, "expected a value, found {s}", .{describe(t)}),
        }
    }

    fn call(self: *Parser, name: []const u8, pos: ast.Pos) Error!*ast.Expr {
        const builtin = std.meta.stringToEnum(ast.Builtin, name);
        if (builtin == null) {
            if (lua_names.get(name)) |why| return self.failAt(pos, .refused, why);
            if (self.lookup(name) != null) return self.failf(pos, .refused, "`{s}` is a local, and functions are not values: only a declared function can be called", .{name});
        }
        try self.advance(); // (
        var args: std.ArrayList(*ast.Expr) = .empty;
        if (self.tok.tag != .rparen) {
            while (true) {
                try args.append(self.alloc, try self.expr());
                if (self.tok.tag != .comma) break;
                try self.advance();
            }
        }
        _ = try self.expect(.rparen, "`)` to close the call");
        const e = try self.new(ast.Expr, .{ .pos = pos, .kind = .{ .call = .{ .target = .{ .function = 0 }, .args = args.items } } });
        if (builtin) |b| {
            e.kind.call.target = .{ .builtin = b };
        } else {
            try self.pending.append(self.alloc, .{ .call = &e.kind.call, .name = name, .pos = pos });
        }
        return e;
    }

    fn table(self: *Parser, pos: ast.Pos) Error!*ast.Expr {
        try self.enter();
        defer self.leave();
        try self.advance(); // {
        var items: std.ArrayList(*ast.Expr) = .empty;
        var entries: std.ArrayList(ast.MapEntry) = .empty;
        while (self.tok.tag != .rbrace) {
            const at = self.here();
            var key: ?[]const u8 = null;
            if (self.tok.tag == .name and (try self.peek()).tag == .assign) {
                key = self.tok.text;
                try self.advance();
                try self.advance();
            } else if (self.tok.tag == .lbracket) {
                try self.advance();
                if (self.tok.tag != .string) return self.failAt(self.here(), .refused, "a map literal's keys are names or string literals: `{a = 1}` or `{[\"a b\"] = 1}`");
                key = self.tok.text;
                try self.advance();
                _ = try self.expect(.rbracket, "`]`");
                _ = try self.expect(.assign, "`=` after the key");
            }
            const value = try self.expr();
            if (key) |k| {
                if (items.items.len > 0) return self.failAt(at, .type, "a table literal mixes positional and keyed entries: a list or a map, not both");
                for (entries.items) |en| if (std.mem.eql(u8, en.key, k)) return self.failf(at, .index, "the key `{s}` is given twice", .{k});
                if (value.kind == .nil) return self.failAt(at, .type, "a map cannot hold nil");
                try entries.append(self.alloc, .{ .key = k, .value = value, .pos = at });
            } else {
                if (entries.items.len > 0) return self.failAt(at, .type, "a table literal mixes positional and keyed entries: a list or a map, not both");
                if (value.kind == .nil) return self.failAt(at, .type, "a list cannot hold nil");
                try items.append(self.alloc, value);
            }
            if (self.tok.tag == .comma or self.tok.tag == .semicolon) {
                try self.advance();
            } else break;
        }
        _ = try self.expect(.rbrace, "`}` to close the table");
        if (entries.items.len > 0) return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .map = entries.items } });
        if (items.items.len > 0) return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .list = items.items } });
        return self.new(ast.Expr, .{ .pos = pos, .kind = .empty_table });
    }
};

fn describe(t: Token) []const u8 {
    return switch (t.tag) {
        .eof => "the end of the script",
        .name => "a name",
        .int => "a number",
        .string => "a string",
        else => t.text,
    };
}

/// The whole source, parsed. On `error.Parse`, `stop` says where and why.
pub fn parse(alloc: std.mem.Allocator, source: []const u8, max_nesting: u32, stop: *?diag.Stop) Error!ast.Program {
    return parseMeasured(alloc, source, max_nesting, stop, null);
}

/// `parse`, saying how many bytes of the Zig stack it took.
pub fn parseMeasured(alloc: std.mem.Allocator, source: []const u8, max_nesting: u32, stop: *?diag.Stop, stack_used: ?*usize) Error!ast.Program {
    const top = @frameAddress();
    var p: Parser = .{ .alloc = alloc, .lexer = lex.Lexer.init(alloc, source), .tok = undefined, .max_nesting = max_nesting };
    defer if (stack_used) |u| {
        u.* = top -| p.stack_low;
    };
    errdefer stop.* = p.stop;
    try p.advance();
    p.frame.depth = 0;
    const body = try p.block();
    if (p.tok.tag != .eof) return p.failf(p.here(), .syntax, "{s} with nothing open to close", .{describe(p.tok)});
    for (p.pending.items) |pc| {
        const i = p.function_names.get(pc.name) orelse return p.failf(pc.pos, .name, "no function `{s}`", .{pc.name});
        pc.call.target = .{ .function = i };
        const f = p.functions.items[i];
        if (pc.call.args.len != f.params) return p.failf(pc.pos, .argument, "`{s}` takes {d} arguments, given {d}", .{ pc.name, f.params, pc.call.args.len });
    }
    return .{ .functions = p.functions.items, .main = .{ .name = "the script", .pos = .{ .line = 1, .column = 1 }, .params = 0, .frame = p.frame.slots, .body = body } };
}
