//! **A RUN, AS THE HOST SEES IT: THE CONTRACT** (metal-vmm QUEUE 211, Steve's
//! model): a script's whole run behind a handful of calls, so a host (the
//! Linux one, metal's kernel) treats the VM as an opaque box. Nothing of
//! its frames, arenas or ops crosses this file:
//!
//!     start(...)    -> *Process   parse, compile, ready to run
//!     step(limits)  -> paused | finished | stopped
//!     output()      -> what it has printed
//!     status()      -> its state, steps, slices, effects, its stop
//!     kill()        -> everything it holds, given back
//!
//! **IT OWNS ALL IT HOLDS**, from the allocator `start` is handed (never a
//! request's heap), under the run's budgets: the values' arena, the
//! machine's memory (its own copy of the source, which the tree's names
//! and strings point into; the tree, the code, the frames, the operands)
//! and its output. So it may outlive what started it: a background run
//! outlives its request (a crash on Dog Park's host, before it kept its
//! source). `kill` gives every byte of it back.
//!
//! **TWO MODES:** an `atomic` run is today's, whole inside one handler, and
//! may change the store; a `background` run is stepped in slices between
//! handlers and **only reads**: a change is an `argument` error naming
//! `atomic` (Steve: a script that finds and then deletes is a background
//! run to find, then an atomic one to act).

const std = @import("std");
const Io = @import("host_io").Io;
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const value = @import("value.zig");
const interp = @import("interp.zig");
const builtins = @import("builtins.zig");
const compile = @import("compile.zig");
const vm = @import("vm.zig");

pub const Budgets = interp.Budgets;
pub const Stop = diag.Stop;

/// `dry_run` (QUEUE 229, chunk 4): an atomic run whose changes are logged
/// and not made, as the Linux tool runs a script unless told `--write`.
pub const Mode = enum { atomic, background, dry_run };

/// **WHAT A RUN IS GIVEN BESIDE ITS SOURCE**: its mode, and its values by
/// name (`arg`), which the caller keeps alive as long as the run.
pub const Options = struct {
    mode: Mode = .atomic,
    args: []const interp.Arg = &.{},
    /// The host's door, `host(name, ...)` (metal-vmm QUEUE 233): none on
    /// metal, where `host` stops with class `host`.
    host: ?interp.Host = null,
    /// The host's hook on paths, called first when set: none on metal.
    path_hook: ?interp.PathHook = null,
};

pub const State = enum { running, finished, stopped };

/// One slice's limits.
pub const Limits = struct {
    /// The most steps the slice may take, checked between ops.
    steps: u64 = std.math.maxInt(u64),
    /// The host's clock at the slice's start: `now()` is per slice, not
    /// frozen at the run's start. Null keeps the last.
    now: ?i64 = null,
};

pub const Outcome = enum { paused, finished, stopped };

pub const Status = struct {
    state: State,
    steps: u64,
    slices: u64,
    effects: usize,
    stop: ?Stop,
};

/// The machine's budgeted memory, and the tree's arena over it.
pub const MachineMemory = struct {
    budget: value.Budgeted,
    tree: std.heap.ArenaAllocator,
};

pub const Process = struct {
    backing: std.mem.Allocator,
    values: value.Budgeted,
    machine: *MachineMemory,
    run: interp.Run,
    code_arena: std.heap.ArenaAllocator,
    code: compile.Code = undefined,
    task: vm.Task = undefined,
    /// Whether `task` was made (a run stopped before it was has none).
    tasked: bool = false,
    /// Whether `code` was made, its lists the machine's to give back.
    coded: bool = false,
    out: []u8,
    state: State = .running,
    slices: u64 = 0,
    /// The Zig stack the parse took.
    parse_stack: usize = 0,

    /// **A RUN, READY.** Parsed and compiled; a source that doesn't parse or
    /// doesn't fit is a process already stopped, saying why. Fails only
    /// when the host can't hold the process at all.
    pub fn start(io: Io, backing: std.mem.Allocator, root: []const u8, source: []const u8, mode: Mode, budgets: Budgets, now: i64, output_most: usize) error{OutOfMemory}!*Process {
        return startWith(io, backing, root, source, .{ .mode = mode }, budgets, now, output_most);
    }

    /// `start`, with the run's options.
    pub fn startWith(io: Io, backing: std.mem.Allocator, root: []const u8, source: []const u8, options: Options, budgets: Budgets, now: i64, output_most: usize) error{OutOfMemory}!*Process {
        const mode = options.mode;
        const mm = try backing.create(MachineMemory);
        errdefer backing.destroy(mm);
        const out = try backing.alloc(u8, @min(output_most, budgets.output_bytes));
        errdefer backing.free(out);
        const p = try backing.create(Process);
        mm.* = .{ .budget = .{ .backing = backing, .limit = budgets.machine_bytes }, .tree = undefined };
        mm.tree = .init(mm.budget.allocator());
        p.* = .{
            .backing = backing,
            .values = .{ .backing = backing, .limit = budgets.arena_bytes },
            .machine = mm,
            .run = undefined,
            .code_arena = .init(mm.budget.allocator()),
            .out = out,
        };
        p.run = .{
            .io = io,
            .alloc = p.values.allocator(),
            .machine = mm.budget.allocator(),
            .budgeted = &p.values,
            .budgets = budgets,
            .root = root,
            .now = now,
            .program = undefined,
            .out = out,
            .out_cap = out.len,
            .read_only = mode == .background,
            .dry_run = mode == .dry_run,
            .args = options.args,
            .host = options.host,
            .path_hook = options.path_hook,
        };
        p.ready(source) catch {};
        return p;
    }

    fn ready(p: *Process, source: []const u8) error{Stop}!void {
        const budgets = p.run.budgets;
        if (source.len > budgets.source_bytes) return p.stopWith(.{ .line = 1, .column = 1, .class = .budget, .budget = .source, .message = "the source is larger than the source budget" });
        const machine_stop: Stop = .{ .line = 1, .column = 1, .class = .budget, .budget = .machine, .message = "the machine's memory (the code, the frames, the operands) is past its budget" };
        const tree = p.machine.tree.allocator();
        // **ITS OWN SOURCE**: the tree points into it (above).
        const own = tree.dupe(u8, source) catch return p.stopWith(machine_stop);
        const program = tree.create(ast.Program) catch return p.stopWith(machine_stop);
        var stop: ?Stop = null;
        program.* = parse.parseMeasured(tree, p.machine.budget.allocator(), own, budgets.nesting, &stop, &p.parse_stack) catch |e| return p.stopWith(switch (e) {
            error.Parse => stop.?,
            error.OutOfMemory => machine_stop,
        });
        p.run.program = program;
        p.code = compile.compile(p.code_arena.allocator(), p.machine.budget.allocator(), program, builtins.most_args, budgets.depth) catch return p.stopWith(machine_stop);
        p.coded = true;
        p.task = vm.Task.init(&p.run, &p.code) catch {
            if (p.run.stop == null) p.run.stop = machine_stop;
            p.state = .stopped;
            return error.Stop;
        };
        p.tasked = true;
    }

    fn stopWith(p: *Process, s: Stop) error{Stop} {
        p.run.stop = s;
        p.state = .stopped;
        return error.Stop;
    }

    /// **ONE SLICE**: at most `limits.steps` (an op that starts inside the
    /// slice finishes). A run that has ended says so again and runs nothing.
    pub fn step(p: *Process, limits: Limits) Outcome {
        switch (p.state) {
            .finished => return .finished,
            .stopped => return .stopped,
            .running => {},
        }
        if (limits.now) |n| p.run.now = n;
        p.slices += 1;
        return switch (p.task.step(.{ .steps = limits.steps })) {
            .paused => .paused,
            .finished => blk: {
                p.state = .finished;
                break :blk .finished;
            },
            .stopped => blk: {
                p.state = .stopped;
                break :blk .stopped;
            },
        };
    }

    /// What the run has printed so far.
    pub fn output(p: *const Process) []const u8 {
        return p.out[0..p.run.out_len];
    }

    pub fn status(p: *const Process) Status {
        return .{ .state = p.state, .steps = p.run.steps, .slices = p.slices, .effects = p.run.effects.items.len, .stop = p.run.stop };
    }

    /// The effects so far, in order (owned by the process).
    pub fn effects(p: *const Process) []const interp.Effect {
        return p.run.effects.items;
    }

    /// **EVERYTHING IT HOLDS, GIVEN BACK**, whatever state it is in; the
    /// process is gone.
    pub fn kill(p: *Process) void {
        p.release();
        p.values.deinit();
        p.machine.tree.deinit();
        p.machine.budget.deinit();
        p.backing.destroy(p.machine);
        p.backing.free(p.out);
        p.backing.destroy(p);
    }

    /// The machine's working state: the task, the run's own lists, the code.
    fn release(p: *Process) void {
        if (p.tasked) p.task.deinit();
        p.tasked = false;
        if (p.coded) p.code.deinit(p.machine.budget.allocator());
        p.coded = false;
        p.run.deinit();
        p.code_arena.deinit();
    }

    /// **THE RUN'S VALUES AND TREE HANDED ON** to a one-shot caller's
    /// `script.Result` (which then owns and frees them), the output copied
    /// into `into`; the rest is given back and the process is gone.
    pub fn intoResult(p: *Process, comptime R: type, into: []u8) R {
        const n = p.run.out_len;
        @memcpy(into[0..n], p.out[0..n]);
        var r: R = .{
            .arena = p.values,
            .machine = p.machine,
            .stop = p.run.stop,
            .output = into[0..n],
            .effects = p.run.effects.items,
            .steps = p.run.steps,
            .reads = p.run.reads,
            .read_bytes = p.run.read_bytes,
            .changes = p.run.changes,
            .collections = p.run.collections,
            .tried_change = p.run.tried_change,
            .work = p.run.work,
            .stack_bytes = p.parse_stack,
            .arena_bytes = p.values.held,
        };
        _ = &r;
        p.release();
        p.backing.free(p.out);
        p.backing.destroy(p);
        return r;
    }
};
