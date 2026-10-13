//! **SHALE, A SMALL SCRIPT LANGUAGE FOR A SITE'S OWN DATA** (metal-vmm QUEUE
//! 199): Lua's look, a smaller language's semantics, every effect through
//! webbox's `store`, every run inside its budgets. The language, its
//! builtins and its budgets are zig-webbox's README, "Scripts".
//!
//! Portable as every webbox file is: the host's `Io` from `host_io`, an
//! allocator from the caller, and nothing that names the host
//! (`portable_test.zig` holds that).

pub const diag = @import("diag.zig");
pub const ast = @import("ast.zig");
pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");
pub const value = @import("value.zig");
pub const interp = @import("interp.zig");
pub const builtins = @import("builtins.zig");

const std = @import("std");
const Io = @import("host_io").Io;

pub const Budgets = interp.Budgets;
pub const Effect = interp.Effect;
pub const Stop = diag.Stop;

/// What a run did. It owns the run's arena: every string in it lives there,
/// so the caller reads it, then calls `deinit`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// Null when the script finished; where and why it stopped otherwise.
    stop: ?Stop,
    /// What `print` wrote: a prefix of the caller's `out`.
    output: []const u8,
    /// Every store change the script attempted, in order, finished or
    /// stopped: a run has no rollback, so this says what it changed.
    effects: []const Effect,
    steps: u64,
    /// The most Zig stack the parse or the walk took, in bytes (README,
    /// "The Zig stack").
    stack_bytes: usize = 0,
    /// The arena bytes the run held at its end, never past its budget.
    arena_bytes: usize = 0,

    pub fn finished(r: *const Result) bool {
        return r.stop == null;
    }

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }
};

/// **THE ONE ENTRY**: parse `source` and run it against the store under
/// `root`, inside `budgets`, with `now` the only time it can know. Every
/// value it makes comes from one arena over `backing`; `print` writes into
/// `out`, and the output budget is at most `out.len`. It always returns a
/// Result: a source however hostile ends finished or stopped.
pub fn run(io: Io, backing: std.mem.Allocator, root: []const u8, source: []const u8, budgets: Budgets, now: i64, out: []u8) Result {
    var result: Result = .{ .arena = .init(backing), .stop = null, .output = out[0..0], .effects = &.{}, .steps = 0 };
    var budgeted: value.Budgeted = .{ .child = result.arena.allocator(), .limit = budgets.arena_bytes };
    const alloc = budgeted.allocator();
    if (source.len > budgets.source_bytes) {
        result.stop = .{ .line = 1, .column = 1, .class = .budget, .budget = .source, .message = "the source is larger than the source budget" };
        return result;
    }
    var stop: ?Stop = null;
    const top = @frameAddress();
    const program = alloc.create(ast.Program) catch return arenaStop(&result);
    program.* = parse.parseMeasured(alloc, source, budgets.nesting, &stop, &result.stack_bytes) catch |e| {
        result.stop = switch (e) {
            error.Parse => stop.?,
            error.OutOfMemory => .{ .line = 1, .column = 1, .class = .budget, .budget = .arena, .message = "the arena budget ran out" },
        };
        return result;
    };
    var r: interp.Run = .{
        .io = io,
        .alloc = alloc,
        .budgeted = &budgeted,
        .budgets = budgets,
        .root = root,
        .now = now,
        .program = program,
        .out = out,
        .out_cap = @min(out.len, budgets.output_bytes),
    };
    r.main() catch |e| switch (e) {
        error.Stop => {},
        // An allocation that failed outside a builtin's own check.
        error.OutOfMemory => r.stop = .{ .line = 1, .column = 1, .class = .budget, .budget = .arena, .message = "the arena budget ran out" },
    };
    result.stop = r.stop;
    result.output = out[0..r.out_len];
    result.effects = r.effects.items;
    result.steps = r.steps;
    result.stack_bytes = @max(result.stack_bytes, top -| r.stack_low);
    result.arena_bytes = budgeted.used;
    return result;
}

fn arenaStop(result: *Result) Result {
    result.stop = .{ .line = 1, .column = 1, .class = .budget, .budget = .arena, .message = "the arena budget ran out" };
    return result.*;
}

test {
    _ = lex;
    _ = parse;
    _ = @import("parse_test.zig");
    _ = value;
    _ = @import("interp_test.zig");
    _ = @import("builtins_test.zig");
    _ = @import("examples_test.zig");
    _ = @import("portable_test.zig");
    _ = @import("fuzz_test.zig");
}
