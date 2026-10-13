//! **THE INTERPRETER**: a walk over the tree, every statement and every
//! expression a step, every budget checked where it is spent. A run ends
//! finished or stopped, never in a Zig panic: every error is a `Stop` with
//! its line, column and class.

const std = @import("std");
const Io = @import("host_io").Io;
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const value = @import("value.zig");
const builtins = @import("builtins.zig");

const Value = value.Value;
const Table = value.Table;

/// Every budget, a named default each, any of which the caller overrides.
pub const Budgets = struct {
    steps: u64 = 5_000_000,
    arena_bytes: usize = 16 * 1024 * 1024,
    call_depth: u32 = 64,
    output_bytes: usize = 256 * 1024,
    reads: u64 = 10_000,
    read_bytes: u64 = 64 * 1024 * 1024,
    changes: u64 = 1_000,
    change_bytes: u64 = 16 * 1024 * 1024,
    source_bytes: usize = 64 * 1024,
    nesting: u32 = 200,
    /// **THE WALK'S DEPTH** (README, "The Zig stack"): expressions and
    /// statements the walk is inside of at once, across every call. The
    /// call depth times the nesting is 12,800 levels, and at about 1 KB of
    /// Zig stack a level in Debug that is more than a thread has; this
    /// bounds the walk to what the stack holds, whatever the script.
    depth: u32 = 2_000,
};

/// One store change the script attempted, in order, root-relative.
pub const Effect = struct {
    op: []const u8,
    path: []const u8,
    /// "ok", or the store's error.
    outcome: []const u8,
};

pub const Error = error{ Stop, OutOfMemory };

pub const Run = struct {
    io: Io,
    alloc: std.mem.Allocator,
    budgeted: *value.Budgeted,
    budgets: Budgets,
    /// The data root the script's paths are confined to.
    root: []const u8,
    now: i64,
    program: *const ast.Program,
    out: []u8,
    out_len: usize = 0,
    out_cap: usize,
    steps: u64 = 0,
    depth: u32 = 0,
    /// The walk's recursion now (`Budgets.depth`).
    walk: u32 = 0,
    reads: u64 = 0,
    read_bytes: u64 = 0,
    changes: u64 = 0,
    change_bytes: u64 = 0,
    effects: std.ArrayList(Effect) = .empty,
    /// Every frame's slots, one stack, each call's frame on top.
    stack: std.ArrayList(Value) = .empty,
    base: usize = 0,
    ret: Value = .nil,
    stop: ?diag.Stop = null,
    /// The lowest frame address the walk reached: the Zig stack it took,
    /// measured (README, "The Zig stack").
    stack_low: usize = std.math.maxInt(usize),

    pub fn fail(self: *Run, pos: ast.Pos, class: diag.Class, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(self.alloc, fmt, args) catch fmt;
        self.stop = .{ .line = pos.line, .column = pos.column, .class = class, .message = message };
        return error.Stop;
    }

    pub fn budgetStop(self: *Run, pos: ast.Pos, b: diag.Budget) Error {
        self.stop = .{ .line = pos.line, .column = pos.column, .class = .budget, .budget = b, .message = switch (b) {
            .steps => "the step budget ran out",
            .arena => "the arena budget ran out",
            .call_depth => "calls nest deeper than the call-depth budget",
            .output => "the output budget ran out",
            .reads => "the store-read budget (count) ran out",
            .read_bytes => "the store-read budget (bytes) ran out",
            .changes => "the store-change budget (count) ran out",
            .change_bytes => "the store-change budget (bytes) ran out",
            .source => "the source is larger than the source budget",
            .nesting => "the source nests deeper than the nesting budget",
            .depth => "calls and the expressions inside them nest deeper than the depth budget",
        } };
        return error.Stop;
    }

    /// Steps, charged; `n` for a builtin's work in proportion to what it
    /// touches.
    pub fn charge(self: *Run, pos: ast.Pos, n: u64) Error!void {
        self.steps +|= n;
        if (self.steps > self.budgets.steps) return self.budgetStop(pos, .steps);
    }

    /// A step, one level deeper, and the stack it took so far.
    fn enter(self: *Run, pos: ast.Pos) Error!void {
        self.stack_low = @min(self.stack_low, @frameAddress());
        self.steps += 1;
        if (self.steps > self.budgets.steps) return self.budgetStop(pos, .steps);
        if (self.walk >= self.budgets.depth) return self.budgetStop(pos, .depth);
        self.walk += 1;
    }

    /// An allocation's failure, read as the arena budget.
    pub fn oom(self: *Run, pos: ast.Pos) Error {
        return self.budgetStop(pos, .arena);
    }

    // ── statements ────────────────────────────────────────────────────────

    const Flow = enum { normal, @"break", @"return" };

    fn block(self: *Run, stmts: []const ast.Stmt) Error!Flow {
        for (stmts) |*s| {
            const f = try self.stmt(s);
            if (f != .normal) return f;
        }
        return .normal;
    }

    fn slot(self: *Run, s: u16) *Value {
        return &self.stack.items[self.base + s];
    }

    /// A dispatcher, its frame small for the reason `eval`'s is.
    fn stmt(self: *Run, s: *const ast.Stmt) Error!Flow {
        try self.enter(s.pos);
        defer self.walk -= 1;
        switch (s.kind) {
            .local => |*l| self.slot(l.slot).* = if (l.value) |e| try self.eval(e) else .nil,
            .assign => |*a| try self.assign(a.target, a.value),
            .call => |c| _ = try self.eval(c),
            .@"if" => |*i| return self.ifStmt(i.arms, i.otherwise),
            .@"while" => |*w| return self.whileStmt(w.cond, w.body),
            .numeric_for => |*f| return self.numericFor(s.pos, f),
            .list_for => |*f| return self.listFor(s.pos, f),
            .@"return" => |r| {
                self.ret = if (r) |e| try self.eval(e) else .nil;
                return .@"return";
            },
            .@"break" => return .@"break",
            .do => |b| return self.block(b),
        }
        return .normal;
    }

    noinline fn assign(self: *Run, target: *const ast.Expr, value_expr: *const ast.Expr) Error!void {
        const v = try self.eval(value_expr);
        switch (target.kind) {
            .local => |sl| self.slot(sl).* = v,
            .index => |ix| {
                const obj = try self.eval(ix.obj);
                const key = try self.eval(ix.key);
                try self.setIndex(target.pos, obj, key, v);
            },
            else => unreachable, // the parser takes only these
        }
    }

    noinline fn ifStmt(self: *Run, arms: []const ast.Arm, otherwise: ?[]ast.Stmt) Error!Flow {
        for (arms) |arm| {
            if ((try self.eval(arm.cond)).truthy()) return self.block(arm.body);
        }
        if (otherwise) |o| return self.block(o);
        return .normal;
    }

    noinline fn whileStmt(self: *Run, cond: *const ast.Expr, body: []const ast.Stmt) Error!Flow {
        while ((try self.eval(cond)).truthy()) {
            switch (try self.block(body)) {
                .normal => {},
                .@"break" => break,
                .@"return" => return .@"return",
            }
        }
        return .normal;
    }

    const NumericFor = @FieldType(ast.Stmt.Kind, "numeric_for");
    const ListFor = @FieldType(ast.Stmt.Kind, "list_for");

    noinline fn numericFor(self: *Run, pos: ast.Pos, f: *const NumericFor) Error!Flow {
        const from = try self.int(f.from, "a `for`'s start");
        const to = try self.int(f.to, "a `for`'s end");
        const step: i64 = if (f.step) |e| try self.int(e, "a `for`'s step") else 1;
        if (step == 0) return self.fail(pos, .argument, "a `for` with a step of 0 never ends", .{});
        var i: i64 = from;
        while (if (step > 0) i <= to else i >= to) {
            // An iteration is a step, its body or none.
            try self.charge(pos, 1);
            self.slot(f.slot).* = .{ .int = i };
            switch (try self.block(f.body)) {
                .normal => {},
                .@"break" => break,
                .@"return" => return .@"return",
            }
            // The last step of a loop that ends at maxint is not taken
            // past it.
            i = std.math.add(i64, i, step) catch break;
        }
        return .normal;
    }

    noinline fn listFor(self: *Run, pos: ast.Pos, f: *const ListFor) Error!Flow {
        const l = try self.eval(f.list);
        const items: []const Value = switch (l) {
            .table => |t| switch (t.kind) {
                .empty => &.{},
                .list => blk: {
                    // As the list was when the loop began.
                    try self.charge(pos, t.list.items.len);
                    break :blk self.alloc.dupe(Value, t.list.items) catch return self.oom(pos);
                },
                .map => return self.fail(f.list.pos, .type, "`for x in` a map: walk `keys(m)` instead", .{}),
            },
            else => return self.fail(f.list.pos, .type, "`for x in` takes a list, given {s}", .{l.typeName()}),
        };
        for (items) |x| {
            try self.charge(pos, 1);
            self.slot(f.slot).* = x;
            switch (try self.block(f.body)) {
                .normal => {},
                .@"break" => break,
                .@"return" => return .@"return",
            }
        }
        return .normal;
    }

    fn int(self: *Run, e: *const ast.Expr, what: []const u8) Error!i64 {
        const v = try self.eval(e);
        return switch (v) {
            .int => |i| i,
            else => self.fail(e.pos, .type, "{s} must be an integer, not {s}", .{ what, v.typeName() }),
        };
    }

    // ── tables ────────────────────────────────────────────────────────────

    pub fn newTable(self: *Run, pos: ast.Pos) Error!*Table {
        const t = self.alloc.create(Table) catch return self.oom(pos);
        t.* = .{};
        return t;
    }

    fn setIndex(self: *Run, pos: ast.Pos, obj: Value, key: Value, v: Value) Error!void {
        const t = switch (obj) {
            .table => |t| t,
            else => return self.fail(pos, .type, "only a list or a map can be indexed, not {s}", .{obj.typeName()}),
        };
        switch (key) {
            .int => |k| {
                if (t.kind == .map) return self.fail(pos, .type, "a map's keys are strings: this one is a map, indexed by an integer", .{});
                if (v == .nil) return self.fail(pos, .type, "a list cannot hold nil", .{});
                const len = t.list.items.len;
                if (k >= 1 and k <= len) {
                    t.list.items[@intCast(k - 1)] = v;
                } else if (k == len + 1) {
                    t.list.append(self.alloc, v) catch return self.oom(pos);
                    t.kind = .list;
                } else return self.fail(pos, .index, "index {d} is outside the list (length {d}; only {d} appends)", .{ k, len, len + 1 });
            },
            .string => |k| {
                if (t.kind == .list) return self.fail(pos, .type, "a list's keys are integers: this one is a list, indexed by a string", .{});
                if (v == .nil) return self.fail(pos, .type, "a map cannot hold nil (`m.k = nil` is an error: there is no remove)", .{});
                const g = t.map.getOrPut(self.alloc, k) catch return self.oom(pos);
                g.value_ptr.* = v;
                t.kind = .map;
            },
            else => return self.fail(pos, .type, "a key must be an integer (a list) or a string (a map), not {s}", .{key.typeName()}),
        }
    }

    fn getIndex(self: *Run, pos: ast.Pos, obj: Value, key: Value) Error!Value {
        const t = switch (obj) {
            .table => |t| t,
            else => return self.fail(pos, .type, "only a list or a map can be indexed, not {s}", .{obj.typeName()}),
        };
        switch (key) {
            .int => |k| {
                if (t.kind == .map) return self.fail(pos, .type, "a map's keys are strings: this one is a map, indexed by an integer", .{});
                const len = t.list.items.len;
                if (k < 1 or k > len) return self.fail(pos, .index, "index {d} is outside the list (length {d})", .{ k, len });
                return t.list.items[@intCast(k - 1)];
            },
            .string => |k| {
                if (t.kind == .list) return self.fail(pos, .type, "a list's keys are integers: this one is a list, indexed by a string", .{});
                return t.map.get(k) orelse self.fail(pos, .index, "no key \"{s}\" in the map (`has_key` asks first)", .{k});
            },
            else => return self.fail(pos, .type, "a key must be an integer (a list) or a string (a map), not {s}", .{key.typeName()}),
        }
    }

    // ── expressions ───────────────────────────────────────────────────────

    /// **THE RECURSION'S FRAME IS KEPT SMALL** (README, "The Zig stack"):
    /// every case that needs locals or a message's formatting is a function
    /// of its own, out of this frame, which every nested expression pays.
    pub fn eval(self: *Run, e: *const ast.Expr) Error!Value {
        try self.enter(e.pos);
        defer self.walk -= 1;
        switch (e.kind) {
            .nil => return .nil,
            .boolean => |b| return .{ .boolean = b },
            .int => |i| return .{ .int = i },
            .string => |s| return .{ .string = s },
            .local => |s| return self.slot(s).*,
            .index => return self.indexExpr(e),
            .call => |*c| return self.call(e.pos, c),
            .unary => return self.unary(e),
            .binary => |*b| return self.binary(e.pos, b.op, b.left, b.right),
            .list => |items| return self.listLiteral(e.pos, items),
            .map => |entries| return self.mapLiteral(e.pos, entries),
            .empty_table => return .{ .table = try self.newTable(e.pos) },
        }
    }

    noinline fn indexExpr(self: *Run, e: *const ast.Expr) Error!Value {
        const obj = try self.eval(e.kind.index.obj);
        const key = try self.eval(e.kind.index.key);
        return self.getIndex(e.pos, obj, key);
    }

    noinline fn unary(self: *Run, e: *const ast.Expr) Error!Value {
        return self.unaryOp(e.pos, e.kind.unary.op, try self.eval(e.kind.unary.operand));
    }

    noinline fn unaryOp(self: *Run, pos: ast.Pos, op: ast.UnOp, v: Value) Error!Value {
        switch (op) {
            .not => return .{ .boolean = !v.truthy() },
            .neg => switch (v) {
                .int => |i| return .{ .int = std.math.negate(i) catch return self.fail(pos, .arithmetic, "-{d} overflows 64 bits", .{i}) },
                else => return self.fail(pos, .type, "`-` takes an integer, not {s}", .{v.typeName()}),
            },
            .len => switch (v) {
                .string => |s| return .{ .int = @intCast(s.len) },
                .table => |t| switch (t.kind) {
                    .empty, .list => return .{ .int = @intCast(t.list.items.len) },
                    .map => return self.fail(pos, .type, "`#` of a map: use `count(m)`", .{}),
                },
                else => return self.fail(pos, .type, "`#` takes a string or a list, not {s}", .{v.typeName()}),
            },
        }
    }

    noinline fn listLiteral(self: *Run, pos: ast.Pos, items: []const *ast.Expr) Error!Value {
        const t = try self.newTable(pos);
        t.list.ensureTotalCapacity(self.alloc, items.len) catch return self.oom(pos);
        for (items) |it| {
            const v = try self.eval(it);
            if (v == .nil) return self.fail(it.pos, .type, "a list cannot hold nil", .{});
            t.list.appendAssumeCapacity(v);
        }
        t.kind = .list;
        return .{ .table = t };
    }

    noinline fn mapLiteral(self: *Run, pos: ast.Pos, entries: []const ast.MapEntry) Error!Value {
        const t = try self.newTable(pos);
        for (entries) |en| {
            const v = try self.eval(en.value);
            if (v == .nil) return self.fail(en.pos, .type, "a map cannot hold nil", .{});
            t.map.put(self.alloc, en.key, v) catch return self.oom(pos);
        }
        t.kind = .map;
        return .{ .table = t };
    }

    fn binary(self: *Run, pos: ast.Pos, op: ast.BinOp, le: *const ast.Expr, re: *const ast.Expr) Error!Value {
        // Short-circuit, returning an operand, as Lua's.
        if (op == .@"and") {
            const l = try self.eval(le);
            return if (!l.truthy()) l else self.eval(re);
        }
        if (op == .@"or") {
            const l = try self.eval(le);
            return if (l.truthy()) l else self.eval(re);
        }
        const l = try self.eval(le);
        const r = try self.eval(re);
        return switch (op) {
            .add, .sub, .mul, .idiv, .mod => self.arith(pos, op, l, r),
            .concat => self.concat(pos, l, r),
            .eq, .ne => .{ .boolean = (try self.equal(pos, l, r)) == (op == .eq) },
            .lt, .le, .gt, .ge => self.compare(pos, op, l, r),
            .@"and", .@"or" => unreachable,
        };
    }

    noinline fn arith(self: *Run, pos: ast.Pos, op: ast.BinOp, l: Value, r: Value) Error!Value {
        const a = switch (l) {
            .int => |i| i,
            else => return self.fail(pos, .type, "arithmetic on {s}", .{l.typeName()}),
        };
        const b = switch (r) {
            .int => |i| i,
            else => return self.fail(pos, .type, "arithmetic on {s}", .{r.typeName()}),
        };
        const result: ?i64 = switch (op) {
            .add => std.math.add(i64, a, b) catch null,
            .sub => std.math.sub(i64, a, b) catch null,
            .mul => std.math.mul(i64, a, b) catch null,
            .idiv => blk: {
                if (b == 0) return self.fail(pos, .arithmetic, "integer division by zero", .{});
                break :blk std.math.divFloor(i64, a, b) catch null;
            },
            .mod => blk: {
                if (b == 0) return self.fail(pos, .arithmetic, "`%` by zero", .{});
                if (b == -1) break :blk 0;
                break :blk @mod(a, b);
            },
            else => unreachable,
        };
        return .{ .int = result orelse return self.fail(pos, .arithmetic, "{d} {s} {d} overflows 64 bits", .{ a, opText(op), b }) };
    }

    noinline fn concat(self: *Run, pos: ast.Pos, l: Value, r: Value) Error!Value {
        var a_buf: [24]u8 = undefined;
        var b_buf: [24]u8 = undefined;
        const a = try self.concatPart(pos, l, &a_buf);
        const b = try self.concatPart(pos, r, &b_buf);
        try self.charge(pos, a.len + b.len);
        const s = self.alloc.alloc(u8, a.len + b.len) catch return self.oom(pos);
        @memcpy(s[0..a.len], a);
        @memcpy(s[a.len..], b);
        return .{ .string = s };
    }

    noinline fn compare(self: *Run, pos: ast.Pos, op: ast.BinOp, l: Value, r: Value) Error!Value {
        const order: std.math.Order = switch (l) {
            .int => |a| switch (r) {
                .int => |b| std.math.order(a, b),
                else => return self.fail(pos, .type, "`{s}` compares {s} with {s}", .{ opText(op), l.typeName(), r.typeName() }),
            },
            .string => |a| switch (r) {
                .string => |b| blk: {
                    try self.charge(pos, @min(a.len, b.len));
                    break :blk std.mem.order(u8, a, b);
                },
                else => return self.fail(pos, .type, "`{s}` compares {s} with {s}", .{ opText(op), l.typeName(), r.typeName() }),
            },
            else => return self.fail(pos, .type, "`{s}` compares {s} with {s}", .{ opText(op), l.typeName(), r.typeName() }),
        };
        return .{ .boolean = switch (op) {
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
            else => unreachable,
        } };
    }

    fn concatPart(self: *Run, pos: ast.Pos, v: Value, buf: *[24]u8) Error![]const u8 {
        return switch (v) {
            .string => |s| s,
            .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
            else => self.fail(pos, .type, "`..` takes strings and integers, not {s}", .{v.typeName()}),
        };
    }

    pub fn equal(self: *Run, pos: ast.Pos, l: Value, r: Value) Error!bool {
        if (l == .table or r == .table) return self.fail(pos, .type, "`==` on a list or a map is not in this language", .{});
        if (std.meta.activeTag(l) != std.meta.activeTag(r)) return false;
        return switch (l) {
            .nil => true,
            .boolean => |a| a == r.boolean,
            .int => |a| a == r.int,
            .string => |a| blk: {
                try self.charge(pos, @min(a.len, r.string.len));
                break :blk std.mem.eql(u8, a, r.string);
            },
            .table => unreachable,
        };
    }

    fn call(self: *Run, pos: ast.Pos, c: *const ast.Call) Error!Value {
        switch (c.target) {
            .builtin => |b| return self.callBuiltin(pos, b, c.args),
            .function => |index| return self.callFunction(pos, index, c.args),
        }
    }

    noinline fn callBuiltin(self: *Run, pos: ast.Pos, b: ast.Builtin, arg_exprs: []const *ast.Expr) Error!Value {
        const c = .{ .args = arg_exprs };
        {
            {
                // `print` takes any number, all evaluated before any is written
                // (as Lua's: a call among them that prints, prints first), then
                // joined by tabs, and a newline.
                if (b == .print) {
                    var small: [8]Value = undefined;
                    const vals = if (c.args.len <= small.len) small[0..c.args.len] else self.alloc.alloc(Value, c.args.len) catch return self.oom(pos);
                    for (c.args, vals) |a, *v| v.* = try self.eval(a);
                    for (vals, c.args, 0..) |v, a, i| {
                        if (i > 0) try self.write(pos, "\t");
                        var buf: [24]u8 = undefined;
                        try self.write(a.pos, try builtins.scalarText(self, a.pos, v, &buf, "print"));
                    }
                    try self.write(pos, "\n");
                    return .nil;
                }
                var args: [4]Value = undefined;
                if (c.args.len > args.len) return builtins.tooMany(self, pos, b);
                for (c.args, 0..) |a, i| args[i] = try self.eval(a);
                return builtins.call(self, pos, b, args[0..c.args.len]);
            }
        }
    }

    noinline fn callFunction(self: *Run, pos: ast.Pos, index: u32, arg_exprs: []const *ast.Expr) Error!Value {
        const c = .{ .args = arg_exprs };
        {
            {
                const f = &self.program.functions[index];
                if (self.depth >= self.budgets.call_depth) return self.budgetStop(pos, .call_depth);
                const new_base = self.stack.items.len;
                self.stack.appendNTimes(self.alloc, .nil, f.frame) catch return self.oom(pos);
                for (c.args, 0..) |a, i| {
                    const v = try self.eval(a);
                    self.stack.items[new_base + i] = v;
                }
                const saved = self.base;
                self.base = new_base;
                self.depth += 1;
                defer {
                    self.depth -= 1;
                    self.base = saved;
                    self.stack.shrinkRetainingCapacity(new_base);
                }
                self.ret = .nil;
                _ = try self.block(f.body);
                const r = self.ret;
                self.ret = .nil;
                return r;
            }
        }
    }

    /// The script's own top level, its frame at the stack's foot.
    pub fn main(self: *Run) Error!void {
        self.stack.appendNTimes(self.alloc, .nil, self.program.main.frame) catch return self.oom(self.program.main.pos);
        self.base = 0;
        _ = try self.block(self.program.main.body);
    }

    // ── output ────────────────────────────────────────────────────────────

    pub fn write(self: *Run, pos: ast.Pos, bytes: []const u8) Error!void {
        try self.charge(pos, bytes.len);
        if (bytes.len > self.out_cap - self.out_len) {
            const room = self.out_cap - self.out_len;
            @memcpy(self.out[self.out_len..][0..room], bytes[0..room]);
            self.out_len += room;
            return self.budgetStop(pos, .output);
        }
        @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
        self.out_len += bytes.len;
    }
};

fn opText(op: ast.BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .idiv => "//",
        .mod => "%",
        .concat => "..",
        .eq => "==",
        .ne => "~=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .@"and" => "and",
        .@"or" => "or",
    };
}
