//! **THE VM** (metal-vmm QUEUE 211): a script's compiled ops (`compile.zig`)
//! run on the walker's own `interp.Run`: its slots, budgets, output,
//! effects and every semantic helper, so a run here is the walker's run,
//! step for step. What is its own: the operand stack, the frames
//! (`Frame`), and a loop that never recurses, so a run's state is data a
//! later yield can keep (QUEUE 211, M1).
//!
//! **`attempt`** is a frame marked with its answer (`Frame.out`): an error
//! that is not a budget unwinds to the innermost such frame, and the
//! answer says what it was, as the walker's `attempt` catches it.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const builtins = @import("builtins.zig");
const compile = @import("compile.zig");
const collect = @import("collect.zig");

const Run = interp.Run;
const Value = value.Value;
const Table = value.Table;
const Error = interp.Error;
const Code = compile.Code;
const Op = compile.Op;

const Frame = struct {
    func: *const compile.Func,
    /// Where the caller goes on.
    ret_pc: u32,
    /// Its slots in `Run.stack`.
    base: u32,
    /// The walk's depth where its body starts (the walker's `Run.walk`).
    walk: u32,
    /// The operand stack's height below its call.
    sp: u32,
    /// The caller's function name, put back when it ends.
    caller: []const u8,
    /// `attempt`'s answer, for a frame an `attempt` called; where it was.
    out: ?*Table = null,
    at: ast.Pos = .{ .line = 0, .column = 0 },
};

const Machine = struct {
    r: *Run,
    code: *const Code,
    operands: std.ArrayList(Value) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    pc: u32 = 0,
    /// The top frame's `walk`, kept here for every op's enters.
    walk: u32 = 0,
    /// **WHERE THE SLICE ENDS** (`Task.step`): at the first op boundary
    /// with the run's steps at or past it; never, for a run in one piece.
    slice_end: u64 = std.math.maxInt(u64),
    /// Whether a `yield` ends the slice (a task's) or only collects (a
    /// one-shot run's), and the seconds the last one asked for.
    yield_returns: bool = false,
    yielded: u64 = 0,

    fn deinit(m: *Machine) void {
        m.operands.deinit(m.r.machine);
        m.frames.deinit(m.r.machine);
    }

    inline fn push(m: *Machine, v: Value) void {
        m.operands.appendAssumeCapacity(v);
    }

    inline fn pop(m: *Machine) Value {
        return m.operands.pop().?;
    }

    inline fn top(m: *Machine) *Value {
        return &m.operands.items[m.operands.items.len - 1];
    }

    inline fn slot(m: *Machine, s: u32) *Value {
        return &m.r.stack.items[m.r.base + s];
    }

    fn frame(m: *Machine) *Frame {
        return &m.frames.items[m.frames.items.len - 1];
    }

    /// **THE WALKER'S ENTERS** before an op's work: a step each, the steps
    /// budget then the depth budget checked at each node, as `Run.enter`
    /// does; all at once when the run fits both.
    inline fn enters(m: *Machine, op: *const Op) Error!void {
        const r = m.r;
        const walk = m.walk;
        if (op.enters <= r.budgets.steps -| r.steps and walk + op.deepest < r.budgets.depth) {
            r.steps += op.enters;
            return;
        }
        for (m.code.enters[op.enter..][0..op.enters]) |e| {
            r.steps += 1;
            if (r.steps > r.budgets.steps) return r.budgetStop(e.pos, .steps);
            if (walk + e.depth >= r.budgets.depth) return r.budgetStop(e.pos, .depth);
        }
    }

    /// A frame for function `func` with `argc` arguments on the operand
    /// stack, `walk` deeper than the caller's frame begins.
    fn enterFrame(m: *Machine, op: *const Op, func: *const compile.Func, argc: u32, out: ?*Table) Error!void {
        const r = m.r;
        const base = r.stack.items.len;
        r.stack.appendNTimes(r.machine, .nil, func.frame) catch return r.oom(op.pos);
        const args = m.operands.items[m.operands.items.len - argc ..];
        @memcpy(r.stack.items[base..][0..argc], args);
        m.operands.shrinkRetainingCapacity(m.operands.items.len - argc);
        m.operands.ensureUnusedCapacity(r.machine, func.operands + 1) catch return r.oom(op.pos);
        const caller = m.frame();
        m.frames.append(r.machine, .{
            .func = func,
            .ret_pc = m.pc,
            .base = @intCast(base),
            .walk = caller.walk + op.c,
            .sp = @intCast(m.operands.items.len),
            .caller = r.function,
            .out = out,
            .at = op.pos,
        }) catch return r.oom(op.pos);
        r.base = base;
        r.function = func.name;
        r.depth += 1;
        m.pc = func.entry;
        m.walk = m.frame().walk;
    }

    /// The frame ends with `v`; false when it was the script's top level.
    fn leave(m: *Machine, v: Value) Error!bool {
        const r = m.r;
        const f = m.frames.pop().?;
        if (m.frames.items.len == 0) return false;
        r.stack.shrinkRetainingCapacity(f.base);
        r.base = m.frame().base;
        m.walk = m.frame().walk;
        r.function = f.caller;
        r.depth -= 1;
        m.operands.shrinkRetainingCapacity(f.sp);
        m.pc = f.ret_pc;
        m.push(if (f.out) |out| try r.attemptReturned(f.at, out, v) else v);
        return true;
    }

    /// **AN ERROR, CAUGHT** by the innermost `attempt` below it, when it is
    /// not a budget's: true when the run goes on.
    fn caught(m: *Machine) Error!bool {
        const r = m.r;
        const s = r.stop.?;
        if (s.class == .budget) return false;
        var i = m.frames.items.len;
        while (i > 1) {
            i -= 1;
            const f = m.frames.items[i];
            const out = f.out orelse continue;
            m.frames.shrinkRetainingCapacity(i);
            r.stack.shrinkRetainingCapacity(f.base);
            r.base = m.frame().base;
            m.walk = m.frame().walk;
            r.function = f.caller;
            r.depth = @intCast(i - 1);
            m.operands.shrinkRetainingCapacity(f.sp);
            m.pc = f.ret_pc;
            r.stop = null;
            r.ret = .nil;
            m.push(try r.attemptFailed(f.at, out, s));
            return true;
        }
        return false;
    }

    /// **A YIELD**: what the run still reaches, copied into a fresh arena
    /// (`collect.zig`); every value the machine holds is a root.
    fn yieldHere(m: *Machine, pos: ast.Pos) Error!void {
        const r = m.r;
        var outs: std.ArrayList(*?*Table) = .empty;
        defer outs.deinit(r.machine);
        for (m.frames.items) |*f| if (f.out != null) {
            outs.append(r.machine, &f.out) catch return r.oom(pos);
        };
        try collect.collect(r, pos, &.{ r.stack.items, m.operands.items }, outs.items);
    }

    const Exit = enum { finished, paused, yielded };

    fn run(m: *Machine) Error!Exit {
        while (true) {
            return m.ops() catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.Stop => if (try m.caught()) continue else return e,
            };
        }
    }

    /// Runs ops until the top level ends, the slice does, a yield that
    /// ends it, or an error.
    fn ops(m: *Machine) Error!Exit {
        const r = m.r;
        const code = m.code;
        while (true) {
            if (r.steps >= m.slice_end) return .paused;
            const op = &code.ops[m.pc];
            m.pc += 1;
            if (op.enters != 0) try m.enters(op);
            switch (op.tag) {
                .nop => {},
                .push_nil => m.push(.nil),
                .push_bool => m.push(.{ .boolean = op.a != 0 }),
                .push_int => m.push(.{ .int = code.ints[op.a] }),
                .push_string => m.push(.{ .string = code.strings[op.a] }),
                .push_local => m.push(m.slot(op.a).*),
                .push_const => m.push(r.consts[op.a] orelse return r.constUnset(op.pos, @intCast(op.a))),
                .pop => _ = m.pop(),
                .store_local => m.slot(op.a).* = m.pop(),
                .store_const => {
                    const v = m.pop();
                    m.slot(op.a).* = v;
                    r.consts[op.b] = v;
                },
                .index_get => {
                    const key = m.pop();
                    const obj = m.pop();
                    m.push(try r.getIndex(op.pos, obj, key));
                },
                .index_set => {
                    const key = m.pop();
                    const obj = m.pop();
                    const v = m.pop();
                    try r.setIndex(op.pos, obj, key, v);
                },
                .new_table => m.push(.{ .table = try r.newTable(op.pos) }),
                .list_begin => {
                    const t = try r.newTable(op.pos);
                    t.list.ensureTotalCapacity(r.alloc, op.a) catch return r.oom(op.pos);
                    t.kind = .list;
                    m.push(.{ .table = t });
                },
                .list_item => {
                    const v = m.pop();
                    if (v == .nil) return r.fail(op.pos, .type, "a list cannot hold nil", .{});
                    m.top().table.list.appendAssumeCapacity(v);
                },
                .map_begin => {
                    const t = try r.newTable(op.pos);
                    t.kind = .map;
                    m.push(.{ .table = t });
                },
                .map_entry => {
                    const v = m.pop();
                    if (v == .nil) return r.fail(op.pos, .type, "a map cannot hold nil", .{});
                    const at = code.positions[op.b];
                    const key = code.strings[op.a];
                    try r.charge(at, key.len);
                    m.top().table.map.put(r.alloc, key, v) catch return r.oom(at);
                },
                .unary => {
                    const v = m.pop();
                    m.push(try r.unaryOp(op.pos, @enumFromInt(op.a), v));
                },
                .binary => {
                    const rv = m.pop();
                    const lv = m.pop();
                    const bop: ast.BinOp = @enumFromInt(op.a);
                    m.push(switch (bop) {
                        .add, .sub, .mul, .idiv, .mod => try r.arith(op.pos, bop, lv, rv),
                        .eq, .ne => .{ .boolean = (try r.equal(op.pos, lv, rv)) == (bop == .eq) },
                        .lt, .le, .gt, .ge => try r.compare(op.pos, bop, lv, rv),
                        .concat, .@"and", .@"or" => unreachable,
                    });
                },
                .concat => {
                    const parts = m.operands.items[m.operands.items.len - op.a ..];
                    const v = try r.joinChain(op.pos, parts, code.positions[op.b..][0..op.a]);
                    m.operands.shrinkRetainingCapacity(m.operands.items.len - op.a);
                    m.push(v);
                },
                .jump => m.pc = op.a,
                .jump_false => if (!m.pop().truthy()) {
                    m.pc = op.a;
                },
                .and_jump => if (!m.top().truthy()) {
                    m.pc = op.a;
                } else {
                    _ = m.pop();
                },
                .or_jump => if (m.top().truthy()) {
                    m.pc = op.a;
                } else {
                    _ = m.pop();
                },
                .builtin => {
                    const args = m.operands.items[m.operands.items.len - op.b ..];
                    const v = try builtins.call(r, op.pos, @enumFromInt(op.a), args);
                    // `yield`'s seconds, read before its arguments go.
                    const seconds: u64 = if (op.b > 0 and args[0] == .int) @intCast(@max(args[0].int, 0)) else 0;
                    m.operands.shrinkRetainingCapacity(m.operands.items.len - op.b);
                    if (op.a == @intFromEnum(ast.Builtin.yield)) {
                        try m.yieldHere(op.pos);
                        if (m.yield_returns) {
                            m.yielded = seconds;
                            m.push(v);
                            return .yielded;
                        }
                    }
                    m.push(v);
                },
                .print => {
                    const vals = m.operands.items[m.operands.items.len - op.a ..];
                    for (vals, code.positions[op.b..][0..op.a], 0..) |v, at, i| {
                        if (i > 0) try r.write(op.pos, "\t");
                        var buf: [24]u8 = undefined;
                        try r.write(at, try builtins.scalarText(r, at, v, &buf, "print"));
                    }
                    try r.write(op.pos, "\n");
                    m.operands.shrinkRetainingCapacity(m.operands.items.len - op.a);
                    m.push(.nil);
                },
                .too_many => return builtins.tooMany(r, op.pos, @enumFromInt(op.a)),
                .call_prep => if (r.depth >= r.budgets.call_depth) return r.budgetStop(op.pos, .call_depth),
                .call => try m.enterFrame(op, &code.functions[op.a], op.b, null),
                .attempt => {
                    const out = try r.attemptTable(op.pos);
                    if (r.depth >= r.budgets.call_depth) return r.budgetStop(op.pos, .call_depth);
                    try m.enterFrame(op, &code.functions[op.a], op.b, out);
                },
                .ret => if (!try m.leave(m.pop())) return .finished,
                .ret_nil => if (!try m.leave(.nil)) return .finished,
                .for_int => _ = try r.intOf(op.pos, m.top().*, switch (op.a) {
                    0 => "a `for`'s start",
                    1 => "a `for`'s end",
                    else => "a `for`'s step",
                }),
                .for_num_init => {
                    const step: i64 = if (op.b != 0) m.pop().int else 1;
                    const to = m.pop().int;
                    const from = m.pop().int;
                    if (step == 0) return r.fail(op.pos, .argument, "a `for` with a step of 0 never ends", .{});
                    m.slot(op.a).* = .{ .int = from };
                    m.slot(op.a + 1).* = .{ .int = to };
                    m.slot(op.a + 2).* = .{ .int = step };
                },
                .for_num_iter => {
                    const i = m.slot(op.a).int;
                    const to = m.slot(op.a + 1).int;
                    const step = m.slot(op.a + 2).int;
                    if (!(if (step > 0) i <= to else i >= to)) {
                        m.pc = op.b;
                        continue;
                    }
                    try r.charge(op.pos, 1);
                    m.slot(op.c).* = .{ .int = i };
                },
                .for_num_next => {
                    const i = m.slot(op.a).int;
                    const step = m.slot(op.a + 2).int;
                    // The last step of a loop that ends at maxint is not
                    // taken past it.
                    if (std.math.add(i64, i, step)) |next| {
                        m.slot(op.a).* = .{ .int = next };
                        m.pc = op.b;
                    } else |_| m.pc = op.c;
                },
                .for_list_init => {
                    const t = try r.listToWalk(op.pos, m.pop()) orelse {
                        m.pc = op.b;
                        continue;
                    };
                    const n = t.list.items.len;
                    try r.charge(code.positions[op.c], n);
                    m.slot(op.a).* = .{ .table = t };
                    m.slot(op.a + 1).* = .{ .int = @intCast(n) };
                    m.slot(op.a + 2).* = .{ .int = 0 };
                },
                .for_list_iter => {
                    const i = m.slot(op.a + 2).int;
                    if (i >= m.slot(op.a + 1).int) {
                        m.pc = op.b;
                        continue;
                    }
                    try r.charge(op.pos, 1);
                    // A list never shrinks, so the item is there.
                    m.slot(op.c).* = m.slot(op.a).table.list.items[@intCast(i)];
                    m.slot(op.a + 2).* = .{ .int = i + 1 };
                },
            }
        }
    }
};

/// **A RUN IN SLICES** (metal-vmm QUEUE 211; docs/SHALE-TASKS.md): the
/// machine kept between them, so a slice ends at any op boundary and the
/// next goes on from there. The VM never recurses, so nothing of the run is
/// on the Zig stack between slices.
pub const Task = struct {
    m: Machine,

    pub const Outcome = union(enum) {
        finished,
        /// The run stopped (`Run.stop` says where and why): for good.
        stopped,
        /// The slice's steps ran out, and the run goes on in the next.
        paused,
        /// A `yield`, with the seconds it asked for.
        yielded: u64,
    };

    pub const Slice = struct {
        /// The most steps the slice may take, checked between ops: an op
        /// that starts inside it finishes.
        steps: u64 = std.math.maxInt(u64),
        /// Whether a `yield` ends the slice (a task) or only collects.
        yield_returns: bool = false,
    };

    /// The script's top level, ready to run, as the walker's `Run.main`
    /// starts it: the consts first, then the main frame at the stack's foot.
    pub fn init(r: *Run, code: *const Code) Error!Task {
        r.consts = r.alloc.alloc(?Value, r.program.const_names.len) catch return r.oom(r.program.main.pos);
        @memset(r.consts, null);
        r.stack.appendNTimes(r.machine, .nil, code.main.frame) catch return r.oom(r.program.main.pos);
        r.base = 0;
        var t: Task = .{ .m = .{ .r = r, .code = code, .pc = code.main.entry } };
        errdefer t.deinit();
        t.m.operands.ensureUnusedCapacity(r.machine, code.main.operands + 1) catch return r.oom(r.program.main.pos);
        t.m.frames.append(r.machine, .{ .func = &code.main, .ret_pc = 0, .base = 0, .walk = 0, .sp = 0, .caller = "" }) catch return r.oom(r.program.main.pos);
        return t;
    }

    pub fn deinit(t: *Task) void {
        t.m.deinit();
    }

    /// One slice. An allocation the host refused is the arena's stop.
    pub fn step(t: *Task, slice: Slice) Outcome {
        const r = t.m.r;
        t.m.slice_end = r.steps +| slice.steps;
        t.m.yield_returns = slice.yield_returns;
        const exit = t.m.run() catch |e| {
            if (e == error.OutOfMemory) r.stop = .{ .line = 1, .column = 1, .class = .budget, .budget = .arena, .message = "the arena budget ran out" };
            return .stopped;
        };
        return switch (exit) {
            .finished => .finished,
            .paused => .paused,
            .yielded => .{ .yielded = t.m.yielded },
        };
    }
};

/// **THE SCRIPT'S TOP LEVEL, RUN** in one piece, its yields only
/// collecting.
pub fn main(r: *Run, code: *const Code) Error!void {
    var t = try Task.init(r, code);
    defer t.deinit();
    switch (t.step(.{})) {
        .finished => {},
        .stopped => return if (r.stop != null) error.Stop else error.OutOfMemory,
        .paused, .yielded => unreachable,
    }
}
