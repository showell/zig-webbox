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
    .{ "pcall", "`pcall` is not in this language: `attempt(f, ...)` calls a function and gives its error as a value" },
    .{ "xpcall", "`xpcall` is not in this language: `attempt(f, ...)` calls a function and gives its error as a value" },
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

const Local = struct { name: []const u8, slot: u16, depth: u16, constant: bool = false };

/// One function's names: a stack of locals, each in the block it was
/// declared in.
const Frame = struct {
    locals: std.ArrayList(Local) = .empty,
    depth: u16 = 0,
    slots: u16 = 0,
    loops: u16 = 0,
};

/// The one name a script may not take: `attempt`'s first argument is a
/// function's name, which only the language can parse.
const reserved_call = "attempt";

pub const Parser = struct {
    /// The tree's: what the parse returns.
    alloc: std.mem.Allocator,
    /// **WHAT THE PARSE BUILDS AND DROPS** (the box's re-review, FEEDBACK
    /// 1599c8f): the lists under construction, from an allocator that gives
    /// room back, each copied into the tree at its size when it is done. In
    /// the tree's arena, every growth left its old copy behind and every
    /// list its spare room: a 64 KiB source of `f()` held 7 MB of tree.
    scratch: std.mem.Allocator,
    /// The lists under construction, one stack a kind, shared by every
    /// level: a list is the stack above its mark.
    stmts: std.ArrayList(ast.Stmt) = .empty,
    exprs: std.ArrayList(*ast.Expr) = .empty,
    arms: std.ArrayList(ast.Arm) = .empty,
    entries: std.ArrayList(ast.MapEntry) = .empty,
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
    /// The script's own functions, by name.
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// **ONLY THE PRELUDE A SCRIPT CALLS** (metal-vmm QUEUE 230): each of
    /// `prelude_index`'s functions, once its first call has parsed it, as
    /// its index in `functions`. One never called is never parsed, and
    /// takes none of the machine.
    prelude_loaded: [prelude_index.len]?u32 = @splat(null),
    /// Whether a prelude function is being parsed: its calls are to the
    /// prelude's functions and the builtins, never to the script's.
    in_prelude: bool = false,
    /// The top-level `const`s declared so far: what a function declared
    /// after them sees (QUEUE 206).
    consts: std.ArrayList([]const u8) = .empty,
    /// The lowest frame address the parse reached (docs/SHALE.md, "The Zig stack").
    stack_low: usize = std.math.maxInt(usize),

    fn failAt(self: *Parser, pos: ast.Pos, class: diag.Class, message: []const u8) Error {
        self.stop = .{ .line = pos.line, .column = pos.column, .class = class, .message = message };
        return error.Parse;
    }

    fn failf(self: *Parser, pos: ast.Pos, class: diag.Class, comptime fmt: []const u8, args: anytype) Error {
        return self.failAt(pos, class, try std.fmt.allocPrint(self.alloc, fmt, args));
    }

    /// A token as an error message names it: words for the end, a string
    /// and a name or number shown, any other token quoted.
    fn describe(self: *Parser, t: Token) []const u8 {
        return switch (t.tag) {
            .eof => "the end of the script",
            .string => "a string",
            .name => std.fmt.allocPrint(self.alloc, "the name `{s}`", .{t.text}) catch "a name",
            .int => std.fmt.allocPrint(self.alloc, "the number {s}", .{t.text}) catch "a number",
            else => std.fmt.allocPrint(self.alloc, "`{s}`", .{t.text}) catch t.text,
        };
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
        if (self.tok.tag != tag) return self.failf(self.here(), .syntax, "expected {s}, found {s}", .{ what, self.describe(self.tok) });
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

    /// A local in this block. **A LOCAL MAY TAKE A BUILTIN'S NAME** (docs/SHALE.md,
    /// "Names"): a value by that name is the local; a call by it is still
    /// the builtin, since only functions are called. So a builtin added to
    /// the language never breaks a script that already used its name.
    fn declare(self: *Parser, name: []const u8, pos: ast.Pos) Error!u16 {
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
        try self.frame.locals.append(self.scratch, .{ .name = name, .slot = slot, .depth = self.frame.depth });
        return slot;
    }

    /// A top-level `const` by name, among those declared so far.
    fn constant(self: *const Parser, name: []const u8) ?u16 {
        for (self.consts.items, 0..) |c, i| if (std.mem.eql(u8, c, name)) return @intCast(i);
        return null;
    }

    /// Whether the local in `slot` of this frame is a `const`.
    fn isConst(self: *const Parser, slot: u16) bool {
        for (self.frame.locals.items) |l| if (l.slot == slot) return l.constant;
        return false;
    }

    fn unknownName(self: *Parser, name: []const u8, pos: ast.Pos) Error {
        if (lua_names.get(name)) |why| return self.failAt(pos, .refused, why);
        if (self.in_function) return self.failf(pos, .name, "no local `{s}` here: a function sees only its own parameters and locals, and the script's `const`s declared above it", .{name});
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
        const at = self.stmts.items.len;
        defer self.stmts.shrinkRetainingCapacity(at);
        while (!blockEnds(self.tok.tag)) {
            if (self.tok.tag == .semicolon) {
                try self.advance();
                continue;
            }
            const s = try self.statement();
            try self.stmts.append(self.scratch, s);
            if (s.kind == .@"return") {
                while (self.tok.tag == .semicolon) try self.advance();
                if (!blockEnds(self.tok.tag)) return self.failAt(self.here(), .syntax, "`return` must be the last statement of its block");
                break;
            }
        }
        return self.alloc.dupe(ast.Stmt, self.stmts.items[at..]);
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
            .kw_const => {
                if (self.in_function or self.frame.depth > 1) return self.failAt(pos, .refused, "`const` is a top-level statement only: a function or a block declares `local`s");
                try self.advance();
                const name = (try self.expect(.name, "a name after `const`")).text;
                if (self.tok.tag != .assign) return self.failAt(self.here(), .syntax, "a `const` needs its value: `const NAME = ...`");
                try self.advance();
                const value = try self.expr();
                if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple values are not in this language");
                const slot = try self.declare(name, pos);
                self.frame.locals.items[self.frame.locals.items.len - 1].constant = true;
                if (self.consts.items.len == std.math.maxInt(u16)) return self.failAt(pos, .syntax, "too many constants");
                const index: u16 = @intCast(self.consts.items.len);
                try self.consts.append(self.scratch, name);
                return .{ .pos = pos, .kind = .{ .constant = .{ .slot = slot, .index = index, .value = value } } };
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
            .kw_continue => {
                try self.advance();
                if (self.frame.loops == 0) return self.failAt(pos, .syntax, "`continue` outside a loop");
                return .{ .pos = pos, .kind = .@"continue" };
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
                        .local => |sl| if (self.isConst(sl)) return self.failAt(target.pos, .name, "a `const` is never assigned: declare a `local` to change it"),
                        .index => {},
                        .constant => return self.failAt(target.pos, .name, "a `const` is never assigned: declare a `local` to change it"),
                        else => return self.failAt(target.pos, .syntax, "only a local or an element `t[k]`, `t.k` can be assigned"),
                    }
                    try self.advance();
                    const value = try self.expr();
                    if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple values are not in this language");
                    return .{ .pos = pos, .kind = .{ .assign = .{ .target = target, .value = value } } };
                }
                if (self.tok.tag == .comma) return self.failAt(self.here(), .refused, "multiple assignment is not in this language: one assignment each");
                if (target.kind != .call) return self.failf(pos, .syntax, "a statement must be a call or an assignment, found {s}", .{self.describe(self.tok)});
                return .{ .pos = pos, .kind = .{ .call = target } };
            },
        }
    }

    fn ifStatement(self: *Parser, pos: ast.Pos) Error!ast.Stmt {
        try self.advance();
        const at = self.arms.items.len;
        defer self.arms.shrinkRetainingCapacity(at);
        const cond = try self.expr();
        _ = try self.expect(.kw_then, "`then` after the `if` condition");
        const first = try self.block();
        try self.arms.append(self.scratch, .{ .cond = cond, .body = first });
        var otherwise: ?[]ast.Stmt = null;
        while (true) {
            switch (self.tok.tag) {
                .kw_elseif => {
                    try self.advance();
                    const c = try self.expr();
                    _ = try self.expect(.kw_then, "`then` after the `elseif` condition");
                    const body = try self.block();
                    try self.arms.append(self.scratch, .{ .cond = c, .body = body });
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
        return .{ .pos = pos, .kind = .{ .@"if" = .{ .arms = try self.alloc.dupe(ast.Arm, self.arms.items[at..]), .otherwise = otherwise } } };
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
        // A function may take a builtin's name: the script's calls by that
        // name are then its own (docs/SHALE.md, "Names").
        if (std.mem.eql(u8, name, reserved_call)) return self.failAt(pos, .name, "`attempt` is the language's own: name the function otherwise");
        if (lua_names.get(name) != null) return self.failf(pos, .name, "`{s}` is a name of Lua's library, kept to say what to write instead: name the function otherwise", .{name});
        // **A SCRIPT'S OWN FUNCTION OF A PRELUDE NAME IS ITS OWN** (QUEUE
        // 220): from its line on, its calls by that name are to it, so a
        // function added to the prelude never breaks a script that already
        // declared one; declared twice by the script, it is refused.
        if (!self.in_prelude and self.function_names.contains(name))
            return self.failf(pos, .name, "a function `{s}` is already declared", .{name});
        const index: u32 = @intCast(self.functions.items.len);
        // An error in a prelude function names it so: its line is the
        // prelude's, never the script's.
        const shown = if (self.in_prelude) try std.fmt.allocPrint(self.alloc, "the prelude's {s}", .{name}) else name;
        if (self.in_prelude) {
            self.prelude_loaded[preludeAt(name).?] = index;
        } else try self.function_names.put(self.scratch, name, index);
        // Reserved now, so it may call itself.
        try self.functions.append(self.scratch, undefined);

        const saved = self.frame;
        const saved_in_function = self.in_function;
        self.frame = .{};
        self.in_function = true;
        defer {
            self.frame.locals.deinit(self.scratch);
            self.frame = saved;
            self.in_function = saved_in_function;
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
        // Known before the body, so the body may call it.
        self.functions.items[index] = .{ .name = shown, .pos = pos, .params = params, .frame = 0, .body = &.{} };
        const body = try self.block();
        _ = try self.expect(.kw_end, "`end` to close the function");
        self.functions.items[index] = .{ .name = shown, .pos = pos, .params = params, .frame = self.frame.slots, .body = body };
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
            // The smallest integer, written: its magnitude is no integer,
            // so only a minus right before it makes it one.
            if (o == .neg and self.tok.tag == .int and self.tok.min_magnitude) {
                try self.advance();
                return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .int = std.math.minInt(i64) } });
            }
            // A literal's minus is the literal's: every negative can be
            // written without overflow.
            const operand = try self.unary();
            // Folded, unless it overflows (`-(-9223372036854775808)`): that
            // is left to run, as the arithmetic error it is.
            if (o == .neg and operand.kind == .int) if (std.math.negate(operand.kind.int)) |n| {
                operand.kind.int = n;
                operand.pos = pos;
                return operand;
            } else |_| {};
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
                if (t.min_magnitude) return self.failAt(pos, .syntax, "an integer literal too big for 64 bits (only -9223372036854775808, with its minus, is the smallest integer)");
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
                if (self.lookup(t.text)) |slot| return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .local = slot } });
                if (self.in_function) if (self.constant(t.text)) |ci| return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .constant = ci } });
                // `table.insert` is Lua's library, though `table` is a builtin.
                if (self.tok.tag == .dot) if (lua_names.get(t.text)) |why| return self.failAt(pos, .refused, why);
                if (std.meta.stringToEnum(ast.Builtin, t.text) != null) return self.failf(pos, .refused, "`{s}` is a builtin, not a value: call it, `{s}(...)`", .{ t.text, t.text });
                return self.unknownName(t.text, pos);
            },
            else => return self.failf(pos, .syntax, "expected a value, found {s}", .{self.describe(t)}),
        }
    }

    /// **A CALL, RESOLVED WHERE IT STANDS** (metal-vmm QUEUE 209; Steve:
    /// "I'm fine with functions only being called after they're
    /// declared"): a name that is a value here (a local, a parameter, a
    /// `const`) is refused; then the script's own function declared above
    /// (or the one being declared: it may call itself); then the builtin;
    /// then Lua's library, refused by name. A function declared later never
    /// takes over an earlier call.
    fn call(self: *Parser, name: []const u8, pos: ast.Pos) Error!*ast.Expr {
        const attempt = std.mem.eql(u8, name, reserved_call);
        var target: ast.Call.Target = undefined;
        var params: ?u16 = null;
        var shown = name;
        if (attempt) {
            try self.advance(); // (
            const f = try self.expect(.name, "the name of the function `attempt` calls");
            if (self.tok.tag == .lparen) return self.failAt(self.here(), .syntax, "`attempt(f, a, b)` calls `f` itself: name it, without its own parentheses");
            const i = try self.functionNamed(f.text) orelse return self.failf(.{ .line = f.line, .column = f.column }, .name, "`attempt` calls a function of the script declared above it, and there is no function `{s}` above this line", .{f.text});
            target = .{ .attempt = i };
            params = self.functions.items[i].params;
            shown = f.text;
            if (self.tok.tag == .comma) {
                try self.advance();
                if (self.tok.tag == .rparen) return self.failAt(self.here(), .syntax, "expected a value after `,`, found `)`");
            } else if (self.tok.tag != .rparen) return self.failf(self.here(), .syntax, "expected `,` or `)` after the function's name, found {s}", .{self.describe(self.tok)});
        } else {
            if (self.lookup(name) != null or (self.in_function and self.constant(name) != null))
                return self.failf(pos, .refused, "`{s}` is a value here, not a function: a local, a parameter or a `const` of that name hides the function or builtin; name it otherwise", .{name});
            if (try self.functionNamed(name)) |i| {
                target = .{ .function = i };
                params = self.functions.items[i].params;
            } else if (std.meta.stringToEnum(ast.Builtin, name)) |b| {
                target = .{ .builtin = b };
            } else if (lua_names.get(name)) |why| {
                return self.failAt(pos, .refused, why);
            } else return self.failf(pos, .name, "no function `{s}` above this line: a function is called only after it is declared", .{name});
            try self.advance(); // (
        }
        const at = self.exprs.items.len;
        defer self.exprs.shrinkRetainingCapacity(at);
        if (self.tok.tag != .rparen) {
            while (true) {
                const arg = try self.expr();
                try self.exprs.append(self.scratch, arg);
                if (self.tok.tag != .comma) break;
                try self.advance();
            }
        }
        _ = try self.expect(.rparen, "`)` to close the call");
        const given = self.exprs.items.len - at;
        if (params) |n| if (given != n) return self.failf(pos, .argument, "`{s}` takes {d} argument{s}, given {d}", .{ shown, n, if (n == 1) "" else "s", given });
        return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .call = .{ .target = target, .args = try self.alloc.dupe(*ast.Expr, self.exprs.items[at..]) } } });
    }

    /// The function a call by `name` is to: the script's own, declared
    /// above (never, from inside the prelude); else the prelude's, parsed
    /// now if this is its first call; else none.
    fn functionNamed(self: *Parser, name: []const u8) Error!?u32 {
        if (!self.in_prelude) if (self.function_names.get(name)) |i| return i;
        const k = preludeAt(name) orelse return null;
        if (self.prelude_loaded[k] == null) try self.loadPrelude(k);
        return self.prelude_loaded[k].?;
    }

    /// **A PRELUDE FUNCTION, PARSED AT ITS FIRST CALL** (QUEUE 230), from
    /// its own line of prelude.shale, as if the prelude had been parsed
    /// before the script: no `const` of the script's, no local, no depth
    /// of the call it was met in. Its own calls to the prelude parse what
    /// they reach in turn.
    fn loadPrelude(self: *Parser, k: usize) Error!void {
        const saved_lexer = self.lexer;
        const saved_tok = self.tok;
        const saved_ahead = self.ahead;
        const saved_in_prelude = self.in_prelude;
        const saved_nesting = self.nesting;
        const saved_consts = self.consts;
        self.lexer = .{ .src = prelude, .at = prelude_index[k].at, .line = prelude_index[k].line, .alloc = self.alloc };
        self.ahead = null;
        self.in_prelude = true;
        self.nesting = 0;
        self.consts = .empty;
        defer {
            self.lexer = saved_lexer;
            self.tok = saved_tok;
            self.ahead = saved_ahead;
            self.in_prelude = saved_in_prelude;
            self.nesting = saved_nesting;
            self.consts = saved_consts;
        }
        try self.advance();
        try self.function(self.here());
    }

    fn table(self: *Parser, pos: ast.Pos) Error!*ast.Expr {
        try self.enter();
        defer self.leave();
        try self.advance(); // {
        const items_at = self.exprs.items.len;
        defer self.exprs.shrinkRetainingCapacity(items_at);
        const entries_at = self.entries.items.len;
        defer self.entries.shrinkRetainingCapacity(entries_at);
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
            const items = self.exprs.items[items_at..];
            const entries = self.entries.items[entries_at..];
            if (key) |k| {
                if (items.len > 0) return self.failAt(at, .type, "a table literal mixes positional and keyed entries: a list or a map, not both");
                for (entries) |en| if (std.mem.eql(u8, en.key, k)) return self.failf(at, .index, "the key `{s}` is given twice", .{k});
                if (value.kind == .nil) return self.failAt(at, .type, "a map cannot hold nil");
                try self.entries.append(self.scratch, .{ .key = k, .value = value, .pos = at });
            } else {
                if (entries.len > 0) return self.failAt(at, .type, "a table literal mixes positional and keyed entries: a list or a map, not both");
                if (value.kind == .nil) return self.failAt(at, .type, "a list cannot hold nil");
                try self.exprs.append(self.scratch, value);
            }
            if (self.tok.tag == .comma or self.tok.tag == .semicolon) {
                try self.advance();
            } else break;
        }
        _ = try self.expect(.rbrace, "`}` to close the table");
        if (self.entries.items.len > entries_at) return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .map = try self.alloc.dupe(ast.MapEntry, self.entries.items[entries_at..]) } });
        if (self.exprs.items.len > items_at) return self.new(ast.Expr, .{ .pos = pos, .kind = .{ .list = try self.alloc.dupe(*ast.Expr, self.exprs.items[items_at..]) } });
        return self.new(ast.Expr, .{ .pos = pos, .kind = .empty_table });
    }
};

/// **THE PRELUDE**: functions every script has, in Shale (prelude.shale).
pub const prelude = @embedFile("prelude.shale");

/// Where a prelude function begins: its `function`, at the start of `line`.
pub const PreludeFunction = struct { name: []const u8, at: usize, line: u32 };

/// **THE PRELUDE'S FUNCTIONS, FOUND WHEN THIS IS BUILT** (QUEUE 230): each
/// line of prelude.shale that begins `function name(`. The prelude holds
/// only functions, each from the start of a line; parse_test holds this
/// list to a parse of the whole prelude.
pub const prelude_index: []const PreludeFunction = blk: {
    @setEvalBranchQuota(100_000);
    var found: []const PreludeFunction = &.{};
    var at: usize = 0;
    var line: u32 = 1;
    while (at < prelude.len) {
        const end = std.mem.indexOfScalarPos(u8, prelude, at, '\n') orelse prelude.len;
        const text = prelude[at..end];
        if (std.mem.startsWith(u8, text, "function ")) {
            const paren = std.mem.indexOfScalar(u8, text, '(') orelse @compileError("prelude.shale: a function without its `(`");
            found = found ++ [_]PreludeFunction{.{ .name = text["function ".len..paren], .at = at, .line = line }};
        }
        at = end + 1;
        line += 1;
    }
    break :blk found;
};

/// The prelude function named `name`, as its place in `prelude_index`.
fn preludeAt(name: []const u8) ?usize {
    for (prelude_index, 0..) |f, k| if (std.mem.eql(u8, f.name, name)) return k;
    return null;
}

/// The whole source, parsed. On `error.Parse`, `stop` says where and why.
pub fn parse(alloc: std.mem.Allocator, source: []const u8, max_nesting: u32, stop: *?diag.Stop) Error!ast.Program {
    return parseMeasured(alloc, alloc, source, max_nesting, stop, null);
}

/// `parse`, saying how many bytes of the Zig stack it took.
/// What it builds and drops comes from `scratch` and is given back to it;
/// the tree, from `alloc`, exactly its size.
pub fn parseMeasured(alloc: std.mem.Allocator, scratch: std.mem.Allocator, source: []const u8, max_nesting: u32, stop: *?diag.Stop, stack_used: ?*usize) Error!ast.Program {
    const top = @frameAddress();
    var p: Parser = .{ .alloc = alloc, .scratch = scratch, .lexer = lex.Lexer.init(alloc, source), .tok = undefined, .max_nesting = max_nesting };
    defer if (stack_used) |u| {
        u.* = top -| p.stack_low;
    };
    defer {
        p.stmts.deinit(scratch);
        p.exprs.deinit(scratch);
        p.arms.deinit(scratch);
        p.entries.deinit(scratch);
        p.frame.locals.deinit(scratch);
        p.function_names.deinit(scratch);
        p.functions.deinit(scratch);
        p.consts.deinit(scratch);
    }
    errdefer stop.* = p.stop;
    p.frame.depth = 0;
    // The script; a prelude function (prelude.shale, QUEUE 220) is parsed
    // at its first call (QUEUE 230).
    try p.advance();
    const body = try p.block();
    if (p.tok.tag != .eof) return p.failf(p.here(), .syntax, "{s} with nothing open to close", .{p.describe(p.tok)});
    return .{ .functions = try alloc.dupe(ast.Function, p.functions.items), .const_names = try alloc.dupe([]const u8, p.consts.items), .main = .{ .name = "the script", .pos = .{ .line = 1, .column = 1 }, .params = 0, .frame = p.frame.slots, .body = body } };
}
