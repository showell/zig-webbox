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
    pub const default_source_bytes = 64 * 1024;
    pub const default_output_bytes = 256 * 1024;

    steps: u64 = 5_000_000,
    arena_bytes: usize = 16 * 1024 * 1024,
    call_depth: u32 = 64,
    output_bytes: usize = default_output_bytes,
    reads: u64 = 10_000,
    read_bytes: u64 = 64 * 1024 * 1024,
    changes: u64 = 1_000,
    change_bytes: u64 = 16 * 1024 * 1024,
    source_bytes: usize = default_source_bytes,
    nesting: u32 = 200,
    /// **THE WALK'S DEPTH** (docs/SHALE.md, "The Zig stack"): expressions and
    /// statements the walk is inside of at once, across every call. The
    /// call depth times the nesting is 12,800 levels, and at about 1 KB of
    /// Zig stack a level in Debug that is more than a thread has; this
    /// bounds the walk to what the stack holds, whatever the script.
    depth: u32 = 2_000,
    /// **WHAT A YIELD KEEPS** (metal-vmm QUEUE 211, M1): the bytes the
    /// values the VM still reaches take, copied into a fresh arena at each
    /// `yield`; past it, the run stops.
    kept_bytes: usize = 1024 * 1024,
    /// **THE MACHINE'S MEMORY** (the box's review of 211: off the arena, it
    /// was off every budget, and 5,500 parameters 63 calls deep took 14 MB
    /// past an 8 MiB arena): the parse's tree, the compiled code, the
    /// frames' slots, the operand stack, the `..` chains' parts and a
    /// yield's copying, all from one arena of this size beside the values'.
    /// **EVERY SOURCE WITHIN THE SOURCE BUDGET COMPILES IN HALF OF IT** (the
    /// box's re-review, FEEDBACK 1599c8f): the worst shapes, short
    /// statements and list literals, take about 113 bytes of tree and code
    /// a byte of source, 7.4 MB for 64 KiB; the other half is for the
    /// frames and the operands (`process_test.zig` holds both).
    machine_bytes: usize = 16 * 1024 * 1024,
    /// **WHAT ONE CALL BRINGS FROM THE STORE** (metal-vmm QUEUE 211, the
    /// caps: builtins stay atomic, so each one's work is capped): the most
    /// bytes one `read` (or one scan) takes from the store in one call. A
    /// bigger file is read in parts, `read(p, offset, n)`, each a call.
    call_bytes: u64 = 1024 * 1024,
    /// **WHAT ONE `walk` CONSIDERS** (QUEUE 211, the caps): the entries one
    /// call takes from its folders' listings, each a stat if it is kept. A
    /// walk with more ends its list with a `more` entry, and goes on from
    /// it with `walk(p, {after = its path})`.
    call_entries: u64 = 256,
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
    /// **THE MACHINE'S OWN MEMORY** (metal-vmm QUEUE 211): the frames' slots,
    /// the `..` chains' parts, the arguments of a long call, the VM's
    /// operands and frames, outside the values' arena, so a tree-walker and
    /// a VM, whose machinery differs, take the same arena and stop on it at
    /// the same place. **Its own budget bounds it** (`Budgets.machine_bytes`,
    /// with the tree and the code): no value points into it.
    machine: std.mem.Allocator,
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
    /// **THE WORK DONE, COUNTED APART FROM WHAT IS CHARGED** (209(c)): the
    /// bytes, compares, stops and items the builtins' and operators' inner
    /// loops touch, in tests only (`tally`), so a test can hold the work
    /// to a multiple of the steps: an uncharged loop shows.
    work: u64 = 0,
    depth: u32 = 0,
    /// The yields that collected (`collect.zig`): a run's steps and arena
    /// differ from a walker's by them, and by nothing else.
    collections: u64 = 0,
    /// **A BACKGROUND RUN ONLY READS** (`process.Mode`): a change is an
    /// `argument` error naming `atomic`.
    read_only: bool = false,
    /// Whether the run called a builtin that changes the store, refused or
    /// not (the gate cuts a run that did not as a background run).
    tried_change: bool = false,
    /// The copy's bookkeeping, kept from yield to yield (`collect.Books`).
    collecting: @import("collect.zig").Books = .{},
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
    /// The function the walk is in, by name; "" at the top level.
    function: []const u8 = "",
    /// **THE CALLS THE RUN IS IN** (QUEUE 229, chunk 1), outermost first:
    /// where each was made, a stop's trail. Pushed as a call starts and
    /// taken off only as it returns, so a stop finds it whole; an
    /// `attempt` that catches one cuts it back to its own depth. In the
    /// machine's memory, which lives as long as the Result, and never given
    /// back by `deinit`: a stop's `trail` is its items.
    calls: std.ArrayList(diag.Call) = .empty,
    /// **THE LAST STRING A `..` CHAIN BUILT** (`concatChain`): its buffer,
    /// how much of it the string fills, and how big it is.
    tail_ptr: ?[*]u8 = null,
    tail_used: usize = 0,
    tail_cap: usize = 0,
    /// The parts of the `..` chains being joined, one stack for every
    /// chain (a chain inside a part stacks its own above), so a long chain
    /// costs no arena each time it runs.
    chain_parts: std.ArrayList(Value) = .empty,
    chain_ops: std.ArrayList(ast.Pos) = .empty,
    /// The buffer every scan of the file reuses (`count_in`, `find_in`,
    /// `count_lines`).
    scan_buf: []u8 = &.{},
    /// The top-level `const`s, each null until its line has run.
    consts: []?Value = &.{},
    /// The lowest frame address the walk reached: the Zig stack it took,
    /// measured (docs/SHALE.md, "The Zig stack").
    stack_low: usize = std.math.maxInt(usize),

    /// The machine's memory, given back (the arena is the Result's).
    pub fn deinit(self: *Run) void {
        self.stack.deinit(self.machine);
        self.chain_parts.deinit(self.machine);
        self.chain_ops.deinit(self.machine);
        self.collecting.deinit(self.machine);
    }

    pub fn fail(self: *Run, pos: ast.Pos, class: diag.Class, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(self.alloc, fmt, args) catch fmt;
        self.stop = .{ .line = pos.line, .column = pos.column, .class = class, .message = message, .function = self.function, .trail = self.calls.items };
        return error.Stop;
    }

    pub fn budgetStop(self: *Run, pos: ast.Pos, b: diag.Budget) Error {
        self.stop = .{ .line = pos.line, .column = pos.column, .class = .budget, .budget = b, .function = self.function, .trail = self.calls.items, .message = switch (b) {
            .steps => std.fmt.allocPrint(self.alloc, "the step budget ({d} steps) ran out", .{self.budgets.steps}) catch "the step budget ran out",
            .arena => "the arena budget ran out",
            .call_depth => std.fmt.allocPrint(self.alloc, "calls nest deeper than the call-depth budget ({d})", .{self.budgets.call_depth}) catch "calls nest deeper than the call-depth budget",
            .output => "the output budget ran out",
            .reads => "the store-read budget (count) ran out",
            .read_bytes => "the store-read budget (bytes) ran out",
            .changes => "the store-change budget (count) ran out",
            .change_bytes => "the store-change budget (bytes) ran out",
            .source => "the source is larger than the source budget",
            .nesting => "the source nests deeper than the nesting budget",
            .depth => "calls and the expressions inside them nest deeper than the depth budget",
            .machine => std.fmt.allocPrint(self.alloc, "the machine's memory (the code, the frames, the operands) is past its budget ({d} bytes)", .{self.budgets.machine_bytes}) catch "the machine's memory is past its budget",
            .kept => std.fmt.allocPrint(self.alloc, "what the run keeps at a `yield` is past the kept budget ({d} bytes)", .{self.budgets.kept_bytes}) catch "what the run keeps at a `yield` is past the kept budget",
        } };
        return error.Stop;
    }

    /// Work done (see `work`): nothing outside tests.
    pub inline fn tally(self: *Run, n: u64) void {
        if (@import("builtin").is_test) self.work +|= n;
    }

    /// Steps, charged; `n` for a builtin's work in proportion to what it
    /// touches.
    pub fn charge(self: *Run, pos: ast.Pos, n: u64) Error!void {
        // **A CHARGE PAST WHAT IS LEFT STOPS A STEP PAST THE BUDGET**, as a
        // step does: the run never did that work, so its count is not the
        // charge's size (`rep("ab", 2^62)` reported 2^63 steps).
        if (n > self.budgets.steps -| self.steps) {
            self.steps = self.budgets.steps +| 1;
            return self.budgetStop(pos, .steps);
        }
        self.steps += n;
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

    /// A failure of the machine's own memory, read as its budget.
    pub fn machineOom(self: *Run, pos: ast.Pos) Error {
        return self.budgetStop(pos, .machine);
    }

    // ── statements ────────────────────────────────────────────────────────

    const Flow = enum { normal, @"break", @"continue", @"return" };

    fn block(self: *Run, stmts: []const ast.Stmt) Error!Flow {
        for (stmts) |*s| {
            const f = try self.stmt(s);
            if (f != .normal) return f;
        }
        return .normal;
    }

    /// Good only until the stack next grows (a call appends a frame):
    /// evaluate a value before taking the address it goes to.
    fn slot(self: *Run, s: u16) *Value {
        return &self.stack.items[self.base + s];
    }

    /// A dispatcher, its frame small for the reason `eval`'s is.
    fn stmt(self: *Run, s: *const ast.Stmt) Error!Flow {
        try self.enter(s.pos);
        defer self.walk -= 1;
        switch (s.kind) {
            // The value first: a call in it appends a frame, which can move
            // the stack, and a slot's address taken before would be the
            // old memory's.
            .local => |*l| {
                const v = if (l.value) |e| try self.eval(e) else .nil;
                self.slot(l.slot).* = v;
            },
            .constant => |*c| {
                const v = try self.eval(c.value);
                self.slot(c.slot).* = v;
                self.consts[c.index] = v;
            },
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
            .@"continue" => return .@"continue",
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
                .normal, .@"continue" => {},
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
                .normal, .@"continue" => {},
                .@"break" => break,
                .@"return" => return .@"return",
            }
            // The last step of a loop that ends at maxint is not taken
            // past it.
            i = std.math.add(i64, i, step) catch break;
        }
        return .normal;
    }

    /// **`for x in l`**: the first `#l` items, `#l` as it was when the loop
    /// began (an item pushed meanwhile is not visited), each as it is when
    /// the loop reaches it. In place: a loop copies nothing, so a loop over
    /// a list inside another costs no arena (metal-vmm QUEUE 208(a)).
    noinline fn listFor(self: *Run, pos: ast.Pos, f: *const ListFor) Error!Flow {
        const t = try self.listToWalk(f.list.pos, try self.eval(f.list)) orelse return .normal;
        const n = t.list.items.len;
        try self.charge(pos, n);
        for (0..n) |i| {
            try self.charge(pos, 1);
            // A list never shrinks, so the item is there.
            self.slot(f.slot).* = t.list.items[i];
            switch (try self.block(f.body)) {
                .normal, .@"continue" => {},
                .@"break" => break,
                .@"return" => return .@"return",
            }
        }
        return .normal;
    }

    /// **`for x in`'s list**, `pos` its expression's: null for a table
    /// still empty (the loop runs no turn and charges nothing).
    pub fn listToWalk(self: *Run, pos: ast.Pos, l: Value) Error!?*Table {
        return switch (l) {
            .table => |t| switch (t.kind) {
                .empty => null,
                .list => t,
                .map => self.fail(pos, .type, "`for x in` a map: walk `keys(m)` instead", .{}),
            },
            else => self.fail(pos, .type, "`for x in` takes a list, given {s}", .{l.typeName()}),
        };
    }

    fn int(self: *Run, e: *const ast.Expr, what: []const u8) Error!i64 {
        return self.intOf(e.pos, try self.eval(e), what);
    }

    /// A numeric `for`'s start, end or step (`what`), `pos` its expression's.
    pub fn intOf(self: *Run, pos: ast.Pos, v: Value, what: []const u8) Error!i64 {
        return switch (v) {
            .int => |i| i,
            else => self.fail(pos, .type, "{s} must be an integer, not {s}", .{ what, v.typeName() }),
        };
    }

    // ── tables ────────────────────────────────────────────────────────────

    pub fn newTable(self: *Run, pos: ast.Pos) Error!*Table {
        const t = self.alloc.create(Table) catch return self.oom(pos);
        t.* = .{};
        return t;
    }

    pub fn setIndex(self: *Run, pos: ast.Pos, obj: Value, key: Value, v: Value) Error!void {
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
                } else return self.fail(pos, .index, "index {d} is outside the list (length {d}): only index {d} appends, and `push(l, x)` says so", .{ k, len, len + 1 });
            },
            .string => |k| {
                if (t.kind == .list) return self.fail(pos, .type, "a list's keys are integers: this one is a list, indexed by a string", .{});
                if (v == .nil) return self.fail(pos, .type, "a map cannot hold nil (`m.k = nil` is an error: there is no remove)", .{});
                // **A KEY IS HASHED AND COMPARED WHOLE**: a step a byte
                // (209's cold review: a 900 KB key set a million times ran
                // 11 s inside the site's budgets).
                try self.charge(pos, k.len);
                self.tally(k.len);
                const g = t.map.getOrPut(self.alloc, k) catch return self.oom(pos);
                g.value_ptr.* = v;
                t.kind = .map;
            },
            else => return self.fail(pos, .type, "a key must be an integer (a list) or a string (a map), not {s}", .{key.typeName()}),
        }
    }

    pub fn getIndex(self: *Run, pos: ast.Pos, obj: Value, key: Value) Error!Value {
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
                try self.charge(pos, k.len);
                self.tally(k.len);
                return t.map.get(k) orelse self.fail(pos, .index, "no key \"{s}\" in the map (`has_key` asks first)", .{k});
            },
            else => return self.fail(pos, .type, "a key must be an integer (a list) or a string (a map), not {s}", .{key.typeName()}),
        }
    }

    // ── expressions ───────────────────────────────────────────────────────

    /// **THE RECURSION'S FRAME IS KEPT SMALL** (docs/SHALE.md, "The Zig stack"):
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
            .constant => |i| return self.consts[i] orelse self.constUnset(e.pos, i),
            .index => return self.indexExpr(e),
            .call => |*c| return self.call(e.pos, c),
            .unary => return self.unary(e),
            .binary => |*b| return self.binary(e.pos, b.op, b.left, b.right),
            .list => |items| return self.listLiteral(e.pos, items),
            .map => |entries| return self.mapLiteral(e.pos, entries),
            .empty_table => return .{ .table = try self.newTable(e.pos) },
        }
    }

    pub noinline fn constUnset(self: *Run, pos: ast.Pos, i: u16) Error {
        return self.fail(pos, .name, "the `const` {s} is read before its line has run", .{self.program.const_names[i]});
    }

    noinline fn indexExpr(self: *Run, e: *const ast.Expr) Error!Value {
        const obj = try self.eval(e.kind.index.obj);
        const key = try self.eval(e.kind.index.key);
        return self.getIndex(e.pos, obj, key);
    }

    noinline fn unary(self: *Run, e: *const ast.Expr) Error!Value {
        return self.unaryOp(e.pos, e.kind.unary.op, try self.eval(e.kind.unary.operand));
    }

    pub noinline fn unaryOp(self: *Run, pos: ast.Pos, op: ast.UnOp, v: Value) Error!Value {
        switch (op) {
            .not => return .{ .boolean = !v.truthy() },
            .neg => switch (v) {
                .int => |i| return .{ .int = std.math.negate(i) catch return self.fail(pos, .arithmetic, "negating {d} overflows 64 bits", .{i}) },
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
            try self.charge(pos, en.key.len);
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
        if (op == .concat) return self.concatChain(pos, le, re);
        const l = try self.eval(le);
        const r = try self.eval(re);
        return switch (op) {
            .add, .sub, .mul, .idiv, .mod => self.arith(pos, op, l, r),
            .concat => unreachable, // `concatChain`
            .eq, .ne => .{ .boolean = (try self.equal(pos, l, r)) == (op == .eq) },
            .lt, .le, .gt, .ge => self.compare(pos, op, l, r),
            .@"and", .@"or" => unreachable,
        };
    }

    fn toNumberHint(v: Value) []const u8 {
        return if (v == .string) " (`tonumber(s)` reads one from a string)" else "";
    }

    pub noinline fn arith(self: *Run, pos: ast.Pos, op: ast.BinOp, l: Value, r: Value) Error!Value {
        const a = switch (l) {
            .int => |i| i,
            else => return self.fail(pos, .type, "`{s}` takes integers, and its left is {s}{s}", .{ opText(op), l.typeName(), toNumberHint(l) }),
        };
        const b = switch (r) {
            .int => |i| i,
            else => return self.fail(pos, .type, "`{s}` takes integers, and its right is {s}{s}", .{ opText(op), r.typeName(), toNumberHint(r) }),
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

    /// **A CHAIN OF `..`, JOINED ONCE** (metal-vmm QUEUE 208(a)): `a .. b ..
    /// c` (right-associative, so one chain) is every part evaluated left to
    /// right, then one string. When the first part is the string the last
    /// chain built, whole, and its buffer has room, the rest is written
    /// after it in place: `s = s .. x` in a loop is linear, not quadratic,
    /// in time and arena. A buffer outgrown is copied to one twice the
    /// size. A string is never changed: the room is past the end of every
    /// slice of the buffer. Each byte written is a step.
    noinline fn concatChain(self: *Run, pos: ast.Pos, le: *const ast.Expr, re: *const ast.Expr) Error!Value {
        // The parts, and the `..` before each but the first (the first's is
        // its own: the chain's first operator).
        var n: usize = 2;
        var r = re;
        while (r.kind == .binary and r.kind.binary.op == .concat) : (r = r.kind.binary.right) n += 1;
        // On the run's stack of parts: a part's own chain stacks above, and
        // the stack can move as it grows, so the parts are reached by index.
        const base = self.chain_parts.items.len;
        self.chain_parts.appendNTimes(self.machine, .nil, n) catch return self.machineOom(pos);
        self.chain_ops.appendNTimes(self.machine, pos, n) catch return self.machineOom(pos);
        defer {
            self.chain_parts.shrinkRetainingCapacity(base);
            self.chain_ops.shrinkRetainingCapacity(base);
        }
        // `ops[k]` is the `..` whose left is part k (the chain's first for
        // part 0); the last part's is the innermost, as part n - 2's.
        {
            const v = try self.eval(le);
            self.chain_parts.items[base] = v;
        }
        r = re;
        var k: usize = 1;
        while (r.kind == .binary and r.kind.binary.op == .concat) : (r = r.kind.binary.right) {
            const v = try self.eval(r.kind.binary.left);
            self.chain_parts.items[base + k] = v;
            self.chain_ops.items[base + k] = r.pos;
            k += 1;
        }
        {
            const v = try self.eval(r);
            self.chain_parts.items[base + k] = v;
        }
        const parts = self.chain_parts.items[base..][0..n];
        const ops = self.chain_ops.items[base..][0..n];
        ops[n - 1] = ops[n - 2];
        return self.joinChain(pos, parts, ops);
    }

    /// A `..` chain's parts, evaluated, joined (`concatChain`): `ops[k]` is
    /// the `..` part k is checked at.
    pub fn joinChain(self: *Run, pos: ast.Pos, parts: []const Value, ops: []const ast.Pos) Error!Value {
        const n = parts.len;
        // Checked as the nested joins would have: the innermost pair, then
        // outward, each at its own `..`.
        var total: usize = 0;
        var at = n;
        while (at > 0) {
            at -= 1;
            const i = if (at == n - 1) n - 2 else if (at == n - 2) n - 1 else at;
            total += try self.partLen(ops[i], parts[i]);
        }
        const first: []const u8 = switch (parts[0]) {
            .string => |x| x,
            else => "",
        };
        const in_place = parts[0] == .string and first.len > 0 and first.ptr == self.tail_ptr and first.len == self.tail_used and total <= self.tail_cap;
        const buf: [*]u8 = if (in_place) self.tail_ptr.? else blk: {
            // Outgrown: twice the size, so a string built a piece at a time
            // is copied a logarithmic number of times.
            const grow = parts[0] == .string and first.len > 0 and first.ptr == self.tail_ptr and first.len == self.tail_used;
            const cap = if (grow) @max(2 * total, 64) else total;
            const fresh = self.alloc.alloc(u8, cap) catch return self.oom(pos);
            self.tail_cap = cap;
            break :blk fresh.ptr;
        };
        var len: usize = if (in_place) first.len else 0;
        try self.charge(pos, total - len);
        self.tally(total - len);
        for (parts[if (in_place) 1 else 0..]) |v| {
            switch (v) {
                .string => |x| @memcpy(buf[len..][0..x.len], x),
                .int => |i| _ = std.fmt.bufPrint(buf[len..total], "{d}", .{i}) catch unreachable,
                else => unreachable,
            }
            len += textLen(v);
        }
        self.tail_ptr = buf;
        self.tail_used = total;
        return .{ .string = buf[0..total] };
    }

    fn textLen(v: Value) usize {
        return switch (v) {
            .string => |x| x.len,
            .int => |i| std.fmt.count("{d}", .{i}),
            else => unreachable,
        };
    }

    fn partLen(self: *Run, pos: ast.Pos, v: Value) Error!usize {
        return switch (v) {
            .string, .int => textLen(v),
            else => self.fail(pos, .type, "`..` takes strings and integers, not {s}", .{v.typeName()}),
        };
    }

    pub noinline fn compare(self: *Run, pos: ast.Pos, op: ast.BinOp, l: Value, r: Value) Error!Value {
        const order: std.math.Order = switch (l) {
            .int => |a| switch (r) {
                .int => |b| std.math.order(a, b),
                else => return self.fail(pos, .type, "`{s}` compares {s} with {s}", .{ opText(op), l.typeName(), r.typeName() }),
            },
            .string => |a| switch (r) {
                .string => |b| blk: {
                    try self.charge(pos, @min(a.len, b.len));
                    self.tally(@min(a.len, b.len));
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

    pub fn equal(self: *Run, pos: ast.Pos, l: Value, r: Value) Error!bool {
        if (l == .table or r == .table) return self.fail(pos, .type, "`==` on a list or a map is not in this language", .{});
        if (std.meta.activeTag(l) != std.meta.activeTag(r)) return false;
        return switch (l) {
            .nil => true,
            .boolean => |a| a == r.boolean,
            .int => |a| a == r.int,
            .string => |a| blk: {
                try self.charge(pos, @min(a.len, r.string.len));
                self.tally(@min(a.len, r.string.len));
                break :blk std.mem.eql(u8, a, r.string);
            },
            .table => unreachable,
        };
    }

    fn call(self: *Run, pos: ast.Pos, c: *const ast.Call) Error!Value {
        switch (c.target) {
            .builtin => |b| return self.callBuiltin(pos, b, c.args),
            .function => |index| return self.callFunction(pos, index, c.args),
            .attempt => |index| return self.attempt(pos, index, c.args),
        }
    }

    /// **`attempt(f, ...)`** (metal-vmm QUEUE 208(c)): the script's function
    /// `f`, called with the arguments (evaluated first, outside the
    /// attempt, as Lua's `pcall` does), and its error a value instead of
    /// the run's end: `{ok = true, value = v}` (no `value` for nil) or `{ok
    /// = false, error, class, line, column, in_function}`. **A BUDGET IS
    /// NEVER CAUGHT**: it is the run's, not the call's, so a run that runs
    /// out stops wherever it is. Whatever the call did before its error
    /// stays done: its output, and its changes in the effects log.
    noinline fn attempt(self: *Run, pos: ast.Pos, index: u32, arg_exprs: []const *ast.Expr) Error!Value {
        var small: [8]Value = undefined;
        const vals = if (arg_exprs.len <= small.len) small[0..arg_exprs.len] else self.machine.alloc(Value, arg_exprs.len) catch return self.machineOom(pos);
        defer if (arg_exprs.len > small.len) self.machine.free(vals);
        for (arg_exprs, vals) |a, *v| v.* = try self.eval(a);
        const out = try self.attemptTable(pos);
        const calls = self.calls.items.len;
        const got = self.invoke(pos, index, vals) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Stop => {
                const s = self.stop.?;
                if (s.class == .budget) return error.Stop;
                self.stop = null;
                self.ret = .nil;
                const failed = try self.attemptFailed(pos, out, s);
                self.calls.shrinkRetainingCapacity(calls);
                return failed;
            },
        };
        return self.attemptReturned(pos, out, got);
    }

    /// `attempt`'s answer, made before the call (so its arena comes first).
    pub fn attemptTable(self: *Run, pos: ast.Pos) Error!*Table {
        const out = try self.newTable(pos);
        out.kind = .map;
        return out;
    }

    pub fn attemptFailed(self: *Run, pos: ast.Pos, out: *Table, s: diag.Stop) Error!Value {
        const a = self.alloc;
        out.map.put(a, "ok", .{ .boolean = false }) catch return self.oom(pos);
        out.map.put(a, "error", .{ .string = s.message }) catch return self.oom(pos);
        out.map.put(a, "class", .{ .string = @tagName(s.class) }) catch return self.oom(pos);
        out.map.put(a, "line", .{ .int = s.line }) catch return self.oom(pos);
        out.map.put(a, "column", .{ .int = s.column }) catch return self.oom(pos);
        out.map.put(a, "in_function", .{ .string = s.function }) catch return self.oom(pos);
        // The calls, innermost first, as the report says them.
        const trail = try self.newTable(pos);
        trail.list.ensureTotalCapacity(a, s.trail.len) catch return self.oom(pos);
        var k = s.trail.len;
        while (k > 0) {
            k -= 1;
            const c = s.trail[k];
            const site = try self.newTable(pos);
            site.kind = .map;
            site.map.put(a, "in_function", .{ .string = c.function }) catch return self.oom(pos);
            site.map.put(a, "line", .{ .int = c.line }) catch return self.oom(pos);
            site.map.put(a, "column", .{ .int = c.column }) catch return self.oom(pos);
            trail.list.appendAssumeCapacity(.{ .table = site });
        }
        if (s.trail.len > 0) trail.kind = .list;
        out.map.put(a, "trail", .{ .table = trail }) catch return self.oom(pos);
        return .{ .table = out };
    }

    pub fn attemptReturned(self: *Run, pos: ast.Pos, out: *Table, got: Value) Error!Value {
        const a = self.alloc;
        out.map.put(a, "ok", .{ .boolean = true }) catch return self.oom(pos);
        if (got != .nil) out.map.put(a, "value", got) catch return self.oom(pos);
        return .{ .table = out };
    }

    noinline fn callBuiltin(self: *Run, pos: ast.Pos, b: ast.Builtin, arg_exprs: []const *ast.Expr) Error!Value {
        if (b == .print) return self.print(pos, arg_exprs);
        var args: [builtins.most_args]Value = undefined;
        if (arg_exprs.len > args.len) return builtins.tooMany(self, pos, b);
        for (arg_exprs, 0..) |a, i| args[i] = try self.eval(a);
        return builtins.call(self, pos, b, args[0..arg_exprs.len]);
    }

    /// `print` takes any number, all evaluated before any is written (as
    /// Lua's: a call among them that prints, prints first), then joined by
    /// tabs, and a newline.
    fn print(self: *Run, pos: ast.Pos, arg_exprs: []const *ast.Expr) Error!Value {
        var small: [8]Value = undefined;
        const vals = if (arg_exprs.len <= small.len) small[0..arg_exprs.len] else self.machine.alloc(Value, arg_exprs.len) catch return self.machineOom(pos);
        defer if (arg_exprs.len > small.len) self.machine.free(vals);
        for (arg_exprs, vals) |a, *v| v.* = try self.eval(a);
        for (vals, arg_exprs, 0..) |v, a, i| {
            if (i > 0) try self.write(pos, "\t");
            var buf: [24]u8 = undefined;
            try self.write(a.pos, try builtins.scalarText(self, a.pos, v, &buf, "print"));
        }
        try self.write(pos, "\n");
        return .nil;
    }

    noinline fn callFunction(self: *Run, pos: ast.Pos, index: u32, arg_exprs: []const *ast.Expr) Error!Value {
        const f = &self.program.functions[index];
        if (self.depth >= self.budgets.call_depth) return self.budgetStop(pos, .call_depth);
        const new_base = self.stack.items.len;
        self.stack.appendNTimes(self.machine, .nil, f.frame) catch return self.machineOom(pos);
        for (arg_exprs, 0..) |a, i| {
            const v = try self.eval(a);
            self.stack.items[new_base + i] = v;
        }
        return self.enterFunction(pos, f, new_base);
    }

    /// Function `index` with its arguments already evaluated.
    fn invoke(self: *Run, pos: ast.Pos, index: u32, args: []const Value) Error!Value {
        const f = &self.program.functions[index];
        if (self.depth >= self.budgets.call_depth) return self.budgetStop(pos, .call_depth);
        const new_base = self.stack.items.len;
        self.stack.appendNTimes(self.machine, .nil, f.frame) catch return self.machineOom(pos);
        @memcpy(self.stack.items[new_base..][0..args.len], args);
        return self.enterFunction(pos, f, new_base);
    }

    /// The body of `f`, called at `pos`, its frame at `new_base` with its
    /// arguments in it; everything put back as it was however it ends but
    /// the call in `calls`, which only a return takes off.
    fn enterFunction(self: *Run, pos: ast.Pos, f: *const ast.Function, new_base: usize) Error!Value {
        self.calls.append(self.machine, .{ .line = pos.line, .column = pos.column, .function = self.function }) catch return self.machineOom(pos);
        const saved = self.base;
        const saved_function = self.function;
        self.base = new_base;
        self.function = f.name;
        self.depth += 1;
        defer {
            self.depth -= 1;
            self.base = saved;
            self.function = saved_function;
            self.stack.shrinkRetainingCapacity(new_base);
        }
        self.ret = .nil;
        _ = try self.block(f.body);
        const r = self.ret;
        self.ret = .nil;
        self.calls.items.len -= 1;
        return r;
    }

    /// The script's own top level, its frame at the stack's foot.
    pub fn main(self: *Run) Error!void {
        self.consts = self.alloc.alloc(?Value, self.program.const_names.len) catch return self.oom(self.program.main.pos);
        @memset(self.consts, null);
        self.stack.appendNTimes(self.machine, .nil, self.program.main.frame) catch return self.machineOom(self.program.main.pos);
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

pub fn opText(op: ast.BinOp) []const u8 {
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
