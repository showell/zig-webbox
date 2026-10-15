//! **THE TREE, COMPILED** (metal-vmm QUEUE 211): a script's functions as
//! one array of ops for `vm.zig`, a stack machine over the walker's own
//! semantics (`interp.Run`'s helpers and the builtins).
//!
//! **STEP PARITY IS EXACT.** The walker charges a step as it enters each
//! node (`Run.enter`), before the node's own work, and checks the depth
//! budget there against how deep the walk is. The compiler keeps those
//! enters in the walker's order, each with its node's position and its
//! static depth in its function (`Enter`), and hangs the run of enters
//! that comes before an op's work on that op (`Op.enter`, `Op.enters`).
//! The VM runs them first. A run is charged at once when it fits the
//! budgets, and node by node when it doesn't, so a stop names the node the
//! walker's would. A label (a jump's target) first flushes the enters
//! pending before it onto a `nop`, so a jump never repeats or skips them.
//!
//! A call's frame starts its walk where the walker's would: the caller's
//! walk at the call (its frame's base plus the call's static depth), plus
//! one for the call itself (`Op.c` of `call` and `attempt`).

const std = @import("std");
const ast = @import("ast.zig");

pub const Tag = enum(u8) {
    nop,
    push_nil,
    /// `a`: 1 for true.
    push_bool,
    /// `a`: the index in `Code.ints`.
    push_int,
    /// `a`: the index in `Code.strings`.
    push_string,
    /// `a`: the slot.
    push_local,
    /// `a`: the const's index (an error before its line has run).
    push_const,
    pop,
    /// `a`: the slot.
    store_local,
    /// `a`: the slot; `b`: the const's index.
    store_const,
    /// obj, key -> value.
    index_get,
    /// value, obj, key ->.
    index_set,
    new_table,
    /// `a`: the items to come; pushes the list.
    list_begin,
    /// list, item -> list (`pos` the item's).
    list_item,
    map_begin,
    /// map, value -> map: `a` the key (`Code.strings`), `b` the map's
    /// position (`Code.positions`), `pos` the entry's.
    map_entry,
    /// `a`: the `ast.UnOp`.
    unary,
    /// `a`: the `ast.BinOp` (not `and`, `or` or `..`).
    binary,
    /// `a` parts -> one string; `b`: where each part is checked
    /// (`Code.positions`, `a` of them).
    concat,
    /// `a`: the target.
    jump,
    /// cond ->; to `a` when it is false.
    jump_false,
    /// To `a`, keeping the value, when it is false (`and`); else pops it.
    and_jump,
    /// To `a`, keeping the value, when it is true (`or`); else pops it.
    or_jump,
    /// `a`: the builtin; `b`: the arguments.
    builtin,
    /// `a`: the arguments; `b`: their positions (`Code.positions`).
    print,
    /// A call to builtin `a` with more arguments than any takes.
    too_many,
    /// The call-depth check before a function's arguments.
    call_prep,
    /// `a`: the function; `b`: the arguments; `c`: the callee's walk from
    /// the caller's frame.
    call,
    /// As `call`, its error a value.
    attempt,
    /// value ->: the frame's end.
    ret,
    ret_nil,
    /// A `for`'s start, end or step (`a`: 0, 1, 2) checked an integer.
    for_int,
    /// from, to[, step] ->: `a` the hidden slots, `b` 1 when a step is
    /// given.
    for_num_init,
    /// `a` the hidden slots, `b` the exit, `c` the loop's slot.
    for_num_iter,
    /// `a` the hidden slots, `b` the loop's head, `c` its exit.
    for_num_next,
    /// list ->: `a` the hidden slots, `b` the exit, `c` the statement's
    /// position (`Code.positions`).
    for_list_init,
    /// `a` the hidden slots, `b` the exit, `c` the loop's slot.
    for_list_iter,
};

pub const Op = struct {
    tag: Tag,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    pos: ast.Pos,
    /// The walker's enters before this op's work: `Code.enters[enter..][0..enters]`.
    enter: u32 = 0,
    enters: u32 = 0,
    /// The deepest of them, from the frame's walk.
    deepest: u32 = 0,
};

/// One node the walker enters: where, and how deep in its function.
pub const Enter = struct { pos: ast.Pos, depth: u32 };

pub const Func = struct {
    name: []const u8,
    pos: ast.Pos,
    entry: u32,
    /// Its slots, the hidden ones the loops keep included.
    frame: u32,
    /// The most its operands stand on the stack at once.
    operands: u32,
};

pub const Code = struct {
    ops: []const Op,
    enters: []const Enter,
    ints: []const i64,
    strings: []const []const u8,
    positions: []const ast.Pos,
    functions: []const Func,
    main: Func,
};

pub const Error = error{OutOfMemory};

/// A loop's jumps still to be pointed: its `break`s, and its `continue`s
/// where the target comes later (a numeric `for`'s next).
const Loop = struct {
    breaks: std.ArrayList(u32) = .empty,
    continues: std.ArrayList(u32) = .empty,
    /// The `continue` target, when it is already placed.
    head: ?u32 = null,
};

const Compiler = struct {
    a: std.mem.Allocator,
    /// The most arguments a builtin takes (`builtins.most_args`).
    most_args: usize,
    ops: std.ArrayList(Op) = .empty,
    enters: std.ArrayList(Enter) = .empty,
    ints: std.ArrayList(i64) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    positions: std.ArrayList(ast.Pos) = .empty,
    /// The first enter not yet hung on an op.
    pending: u32 = 0,
    // The function being compiled:
    hidden: u32 = 0,
    frame: u32 = 0,
    operands: u32 = 0,
    operands_most: u32 = 0,
    loops: std.ArrayList(Loop) = .empty,

    fn enter(c: *Compiler, pos: ast.Pos, depth: u32) Error!void {
        try c.enters.append(c.a, .{ .pos = pos, .depth = depth });
    }

    /// An op, the pending enters hung on it; its index.
    fn emit(c: *Compiler, op: Op) Error!u32 {
        var o = op;
        const n: u32 = @intCast(c.enters.items.len);
        o.enter = c.pending;
        o.enters = n - c.pending;
        o.deepest = 0;
        for (c.enters.items[c.pending..n]) |e| o.deepest = @max(o.deepest, e.depth);
        c.pending = n;
        try c.ops.append(c.a, o);
        return @intCast(c.ops.items.len - 1);
    }

    /// The pending enters on a `nop`, so what follows can be a target.
    fn flush(c: *Compiler) Error!void {
        if (c.pending == c.enters.items.len) return;
        _ = try c.emit(.{ .tag = .nop, .pos = c.enters.items[c.enters.items.len - 1].pos });
    }

    /// The next op's index, as a jump's target.
    fn label(c: *Compiler) Error!u32 {
        try c.flush();
        return @intCast(c.ops.items.len);
    }

    fn patch(c: *Compiler, at: u32, target: u32) void {
        switch (c.ops.items[at].tag) {
            .jump, .jump_false, .and_jump, .or_jump => c.ops.items[at].a = target,
            .for_num_iter, .for_list_iter, .for_list_init => c.ops.items[at].b = target,
            .for_num_next => c.ops.items[at].c = target,
            else => unreachable,
        }
    }

    fn push(c: *Compiler, n: u32) void {
        c.operands += n;
        c.operands_most = @max(c.operands_most, c.operands);
    }

    fn pop(c: *Compiler, n: u32) void {
        c.operands -= n;
    }

    fn position(c: *Compiler, pos: ast.Pos) Error!u32 {
        try c.positions.append(c.a, pos);
        return @intCast(c.positions.items.len - 1);
    }

    fn takeHidden(c: *Compiler, n: u32) u32 {
        const h = c.hidden;
        c.hidden += n;
        c.frame = @max(c.frame, c.hidden);
        return h;
    }

    fn function(c: *Compiler, f: *const ast.Function) Error!Func {
        c.hidden = f.frame;
        c.frame = f.frame;
        c.operands = 0;
        c.operands_most = 0;
        const entry: u32 = @intCast(c.ops.items.len);
        try c.block(f.body, 0);
        _ = try c.emit(.{ .tag = .ret_nil, .pos = f.pos });
        std.debug.assert(c.operands == 0);
        return .{ .name = f.name, .pos = f.pos, .entry = entry, .frame = c.frame, .operands = c.operands_most };
    }

    fn block(c: *Compiler, stmts: []const ast.Stmt, depth: u32) Error!void {
        for (stmts) |*s| try c.stmt(s, depth);
    }

    fn stmt(c: *Compiler, s: *const ast.Stmt, d: u32) Error!void {
        try c.enter(s.pos, d);
        switch (s.kind) {
            .local => |l| {
                if (l.value) |e| try c.expr(e, d + 1) else {
                    _ = try c.emit(.{ .tag = .push_nil, .pos = s.pos });
                    c.push(1);
                }
                _ = try c.emit(.{ .tag = .store_local, .a = l.slot, .pos = s.pos });
                c.pop(1);
            },
            .constant => |k| {
                try c.expr(k.value, d + 1);
                _ = try c.emit(.{ .tag = .store_const, .a = k.slot, .b = k.index, .pos = s.pos });
                c.pop(1);
            },
            .assign => |as| {
                try c.expr(as.value, d + 1);
                switch (as.target.kind) {
                    .local => |sl| {
                        _ = try c.emit(.{ .tag = .store_local, .a = sl, .pos = s.pos });
                        c.pop(1);
                    },
                    .index => |ix| {
                        try c.expr(ix.obj, d + 1);
                        try c.expr(ix.key, d + 1);
                        _ = try c.emit(.{ .tag = .index_set, .pos = as.target.pos });
                        c.pop(3);
                    },
                    else => unreachable, // the parser takes only these
                }
            },
            .call => |e| {
                try c.expr(e, d + 1);
                _ = try c.emit(.{ .tag = .pop, .pos = s.pos });
                c.pop(1);
            },
            .@"if" => |i| {
                var ends: std.ArrayList(u32) = .empty;
                for (i.arms) |arm| {
                    try c.expr(arm.cond, d + 1);
                    const skip = try c.emit(.{ .tag = .jump_false, .pos = arm.cond.pos });
                    c.pop(1);
                    try c.block(arm.body, d + 1);
                    try ends.append(c.a, try c.emit(.{ .tag = .jump, .pos = s.pos }));
                    c.patch(skip, try c.label());
                }
                if (i.otherwise) |o| try c.block(o, d + 1);
                const end = try c.label();
                for (ends.items) |j| c.patch(j, end);
            },
            .@"while" => |w| {
                const head = try c.label();
                try c.expr(w.cond, d + 1);
                const exit = try c.emit(.{ .tag = .jump_false, .pos = w.cond.pos });
                c.pop(1);
                try c.loops.append(c.a, .{ .head = head });
                try c.block(w.body, d + 1);
                _ = try c.emit(.{ .tag = .jump, .a = head, .pos = s.pos });
                const end = try c.label();
                c.patch(exit, end);
                var loop = c.loops.pop().?;
                for (loop.breaks.items) |j| c.patch(j, end);
                loop.breaks.deinit(c.a);
            },
            .numeric_for => |f| {
                try c.expr(f.from, d + 1);
                _ = try c.emit(.{ .tag = .for_int, .a = 0, .pos = f.from.pos });
                try c.expr(f.to, d + 1);
                _ = try c.emit(.{ .tag = .for_int, .a = 1, .pos = f.to.pos });
                if (f.step) |e| {
                    try c.expr(e, d + 1);
                    _ = try c.emit(.{ .tag = .for_int, .a = 2, .pos = e.pos });
                }
                const h = c.takeHidden(3);
                _ = try c.emit(.{ .tag = .for_num_init, .a = h, .b = @intFromBool(f.step != null), .pos = s.pos });
                c.pop(if (f.step != null) 3 else 2);
                const head = try c.label();
                const iter = try c.emit(.{ .tag = .for_num_iter, .a = h, .c = f.slot, .pos = s.pos });
                try c.loops.append(c.a, .{});
                try c.block(f.body, d + 1);
                const next = try c.label();
                const step = try c.emit(.{ .tag = .for_num_next, .a = h, .b = head, .pos = s.pos });
                const end = try c.label();
                c.patch(iter, end);
                c.patch(step, end);
                var loop = c.loops.pop().?;
                for (loop.breaks.items) |j| c.patch(j, end);
                for (loop.continues.items) |j| c.patch(j, next);
                loop.breaks.deinit(c.a);
                loop.continues.deinit(c.a);
                c.hidden -= 3;
            },
            .list_for => |f| {
                try c.expr(f.list, d + 1);
                const h = c.takeHidden(3);
                const init = try c.emit(.{ .tag = .for_list_init, .a = h, .c = try c.position(s.pos), .pos = f.list.pos });
                c.pop(1);
                const head = try c.label();
                const iter = try c.emit(.{ .tag = .for_list_iter, .a = h, .c = f.slot, .pos = s.pos });
                try c.loops.append(c.a, .{ .head = head });
                try c.block(f.body, d + 1);
                _ = try c.emit(.{ .tag = .jump, .a = head, .pos = s.pos });
                const end = try c.label();
                c.patch(init, end);
                c.patch(iter, end);
                var loop = c.loops.pop().?;
                for (loop.breaks.items) |j| c.patch(j, end);
                loop.breaks.deinit(c.a);
                c.hidden -= 3;
            },
            .@"return" => |r| {
                if (r) |e| {
                    try c.expr(e, d + 1);
                    _ = try c.emit(.{ .tag = .ret, .pos = s.pos });
                    c.pop(1);
                } else _ = try c.emit(.{ .tag = .ret_nil, .pos = s.pos });
            },
            .@"break" => {
                const j = try c.emit(.{ .tag = .jump, .pos = s.pos });
                const loop = &c.loops.items[c.loops.items.len - 1];
                try loop.breaks.append(c.a, j);
            },
            .@"continue" => {
                const loop = &c.loops.items[c.loops.items.len - 1];
                const j = try c.emit(.{ .tag = .jump, .a = loop.head orelse 0, .pos = s.pos });
                if (loop.head == null) try loop.continues.append(c.a, j);
            },
            .do => |b| try c.block(b, d + 1),
        }
    }

    fn expr(c: *Compiler, e: *const ast.Expr, d: u32) Error!void {
        try c.enter(e.pos, d);
        switch (e.kind) {
            .nil => {
                _ = try c.emit(.{ .tag = .push_nil, .pos = e.pos });
                c.push(1);
            },
            .boolean => |b| {
                _ = try c.emit(.{ .tag = .push_bool, .a = @intFromBool(b), .pos = e.pos });
                c.push(1);
            },
            .int => |i| {
                try c.ints.append(c.a, i);
                _ = try c.emit(.{ .tag = .push_int, .a = @intCast(c.ints.items.len - 1), .pos = e.pos });
                c.push(1);
            },
            .string => |s| {
                try c.strings.append(c.a, s);
                _ = try c.emit(.{ .tag = .push_string, .a = @intCast(c.strings.items.len - 1), .pos = e.pos });
                c.push(1);
            },
            .local => |sl| {
                _ = try c.emit(.{ .tag = .push_local, .a = sl, .pos = e.pos });
                c.push(1);
            },
            .constant => |i| {
                _ = try c.emit(.{ .tag = .push_const, .a = i, .pos = e.pos });
                c.push(1);
            },
            .index => |ix| {
                try c.expr(ix.obj, d + 1);
                try c.expr(ix.key, d + 1);
                _ = try c.emit(.{ .tag = .index_get, .pos = e.pos });
                c.pop(1);
            },
            .call => |*call| try c.callExpr(e.pos, call, d),
            .unary => |u| {
                try c.expr(u.operand, d + 1);
                _ = try c.emit(.{ .tag = .unary, .a = @intFromEnum(u.op), .pos = e.pos });
            },
            .binary => |b| switch (b.op) {
                .@"and", .@"or" => {
                    try c.expr(b.left, d + 1);
                    const j = try c.emit(.{ .tag = if (b.op == .@"and") .and_jump else .or_jump, .pos = e.pos });
                    c.pop(1);
                    try c.expr(b.right, d + 1);
                    c.patch(j, try c.label());
                },
                .concat => try c.concat(e.pos, b.left, b.right, d),
                else => {
                    try c.expr(b.left, d + 1);
                    try c.expr(b.right, d + 1);
                    _ = try c.emit(.{ .tag = .binary, .a = @intFromEnum(b.op), .pos = e.pos });
                    c.pop(1);
                },
            },
            .list => |items| {
                _ = try c.emit(.{ .tag = .list_begin, .a = @intCast(items.len), .pos = e.pos });
                c.push(1);
                for (items) |it| {
                    try c.expr(it, d + 1);
                    _ = try c.emit(.{ .tag = .list_item, .pos = it.pos });
                    c.pop(1);
                }
            },
            .map => |entries| {
                _ = try c.emit(.{ .tag = .map_begin, .pos = e.pos });
                c.push(1);
                const at = try c.position(e.pos);
                for (entries) |en| {
                    try c.expr(en.value, d + 1);
                    try c.strings.append(c.a, en.key);
                    _ = try c.emit(.{ .tag = .map_entry, .a = @intCast(c.strings.items.len - 1), .b = at, .pos = en.pos });
                    c.pop(1);
                }
            },
            .empty_table => {
                _ = try c.emit(.{ .tag = .new_table, .pos = e.pos });
                c.push(1);
            },
        }
    }

    /// **A `..` CHAIN** as the walker's `concatChain` takes it: the chain's
    /// inner `..` nodes are not entered, every part is, one deeper than
    /// the chain; part k is checked at the `..` whose left it is, the last
    /// at the innermost's.
    fn concat(c: *Compiler, pos: ast.Pos, le: *const ast.Expr, re: *const ast.Expr, d: u32) Error!void {
        const first: u32 = @intCast(c.positions.items.len);
        try c.positions.append(c.a, pos);
        try c.expr(le, d + 1);
        var n: u32 = 1;
        var r = re;
        while (r.kind == .binary and r.kind.binary.op == .concat) : (r = r.kind.binary.right) {
            try c.positions.append(c.a, r.pos);
            try c.expr(r.kind.binary.left, d + 1);
            n += 1;
        }
        try c.positions.append(c.a, c.positions.items[c.positions.items.len - 1]);
        try c.expr(r, d + 1);
        n += 1;
        _ = try c.emit(.{ .tag = .concat, .a = n, .b = first, .pos = pos });
        c.pop(n - 1);
    }

    fn callExpr(c: *Compiler, pos: ast.Pos, call: *const ast.Call, d: u32) Error!void {
        const argc: u32 = @intCast(call.args.len);
        switch (call.target) {
            .builtin => |b| {
                if (b == .print) {
                    const at: u32 = @intCast(c.positions.items.len);
                    for (call.args) |a| try c.positions.append(c.a, a.pos);
                    for (call.args) |a| try c.expr(a, d + 1);
                    _ = try c.emit(.{ .tag = .print, .a = argc, .b = at, .pos = pos });
                    c.pop(argc);
                    c.push(1);
                    return;
                }
                if (argc > c.most_args) {
                    _ = try c.emit(.{ .tag = .too_many, .a = @intFromEnum(b), .pos = pos });
                    c.push(1);
                    return;
                }
                for (call.args) |a| try c.expr(a, d + 1);
                _ = try c.emit(.{ .tag = .builtin, .a = @intFromEnum(b), .b = argc, .pos = pos });
                c.pop(argc);
                c.push(1);
            },
            .function => |index| {
                _ = try c.emit(.{ .tag = .call_prep, .a = index, .pos = pos });
                for (call.args) |a| try c.expr(a, d + 1);
                _ = try c.emit(.{ .tag = .call, .a = index, .b = argc, .c = d + 1, .pos = pos });
                c.pop(argc);
                c.push(1);
            },
            .attempt => |index| {
                for (call.args) |a| try c.expr(a, d + 1);
                _ = try c.emit(.{ .tag = .attempt, .a = index, .b = argc, .c = d + 1, .pos = pos });
                c.pop(argc);
                c.push(1);
            },
        }
    }
};

/// The program's code, in `a`: **NEVER THE RUN'S ARENA**, which holds
/// only what the script makes, so a compiled run and a walked one take the
/// same arena (`interp.Run.machine`).
pub fn compile(a: std.mem.Allocator, program: *const ast.Program, most_args: usize) Error!Code {
    var c: Compiler = .{ .a = a, .most_args = most_args };
    const funcs = try a.alloc(Func, program.functions.len);
    for (program.functions, funcs) |*f, *out| out.* = try c.function(f);
    const main = try c.function(&program.main);
    return .{
        .ops = c.ops.items,
        .enters = c.enters.items,
        .ints = c.ints.items,
        .strings = c.strings.items,
        .positions = c.positions.items,
        .functions = funcs,
        .main = main,
    };
}
