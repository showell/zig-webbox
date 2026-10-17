//! **THE BUILTINS, DECLARED IN ONE PLACE** (metal-vmm QUEUE 208(a)): each
//! topic's file lists its builtins as `Spec`s (the name, how many
//! arguments, the function), and this file gathers them into one table,
//! checked at compile time to name every builtin exactly once. The
//! arguments' helpers every topic shares are here too.
//!
//! The topics: the store (`builtins_store.zig`), text
//! (`builtins_text.zig`), lists and maps (`builtins_lists.zig`), time and
//! the host (`builtins_time.zig`), formatting (`builtins_format.zig`), and
//! numbers (`builtins_numbers.zig`).
//! Every builtin charges steps in proportion to the work it does.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;

/// A builtin's arguments, evaluated and counted against its `Spec`.
pub const Impl = *const fn (run: *Run, pos: ast.Pos, args: []const Value) Error!Value;

/// **A BUILTIN'S DECLARATION**: its name, how many arguments it takes
/// (`at_least` to `at_most`), and the function.
pub const Spec = struct {
    name: B,
    at_least: u8,
    at_most: u8,
    impl: Impl,
};

/// A declaration, as each topic writes it: `spec(.split, 2, 2, split)`.
pub fn spec(name: B, at_least: u8, at_most: u8, impl: Impl) Spec {
    return .{ .name = name, .at_least = at_least, .at_most = at_most, .impl = impl };
}

const topics = .{
    @import("builtins_store.zig"),
    @import("builtins_text.zig"),
    @import("builtins_lists.zig"),
    @import("builtins_time.zig"),
    @import("builtins_format.zig"),
    @import("builtins_numbers.zig"),
    @import("builtins_regex.zig"),
};

/// The most arguments any builtin but `print` takes: the interpreter
/// evaluates them into a buffer this long.
pub const most_args = 4;

/// **THE BUILTINS THAT CALL THE STORE** (metal-vmm QUEUE 211, Steve's
/// model): a slice ends after each, so a host can let a request in between
/// a run's I/O (`vm.zig`'s `.builtin`).
pub const touches_store: std.EnumSet(B) = blk: {
    @setEvalBranchQuota(10_000);
    var set: std.EnumSet(B) = .initEmpty();
    for (@import("builtins_store.zig").specs) |s| set.insert(s.name);
    break :blk set;
};

/// The builtins that change the store: what a background run refuses.
pub const changes_store: std.EnumSet(B) = .initMany(&.{ .replace, .append, .mkdir, .remove, .remove_tree, .edit });

/// Every builtin's `Spec`, by name.
pub const specs: std.EnumArray(B, Spec) = blk: {
    @setEvalBranchQuota(10_000);
    var found: std.EnumArray(B, ?Spec) = .initFill(null);
    for (topics) |t| for (t.specs) |s| {
        if (found.get(s.name) != null) @compileError("the builtin `" ++ @tagName(s.name) ++ "` is declared twice");
        if (s.at_most > most_args) @compileError("the builtin `" ++ @tagName(s.name) ++ "` takes more than most_args");
        found.set(s.name, s);
    };
    // `print` takes any number, and is the interpreter's own.
    found.set(.print, spec(.print, 0, 255, printIsTheInterpreters));
    var all: std.EnumArray(B, Spec) = undefined;
    for (std.enums.values(B)) |b| all.set(b, found.get(b) orelse @compileError("the builtin `" ++ @tagName(b) ++ "` has no declaration"));
    break :blk all;
};

fn printIsTheInterpreters(_: *Run, _: ast.Pos, _: []const Value) Error!Value {
    unreachable;
}

/// "s" after a count that is not 1.
pub fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub fn tooMany(run: *Run, pos: ast.Pos, b: B) Error {
    return run.fail(pos, .argument, "`{s}` takes at most {d} arguments", .{ @tagName(b), specs.get(b).at_most });
}

/// **A CALL**: its arguments counted against the declaration, then the
/// builtin.
pub fn call(run: *Run, pos: ast.Pos, b: B, args: []const Value) Error!Value {
    const s = specs.get(b);
    if (changes_store.contains(b)) {
        run.tried_change = true;
        // **A BACKGROUND RUN ONLY READS** (metal-vmm QUEUE 211, Steve's
        // model), refused before its arguments or its path are looked at.
        if (run.read_only) return run.fail(pos, .argument, "`{s}` changes the store, and a background run only reads: send it as an `atomic` run", .{@tagName(b)});
    }
    if (args.len < s.at_least or args.len > s.at_most) {
        if (s.at_least == s.at_most) return run.fail(pos, .argument, "`{s}` takes {d} argument{s}, given {d}", .{ @tagName(b), s.at_least, plural(s.at_least), args.len });
        return run.fail(pos, .argument, "`{s}` takes {d} to {d} arguments, given {d}", .{ @tagName(b), s.at_least, s.at_most, args.len });
    }
    return s.impl(run, pos, args);
}

// ── the arguments' helpers ──────────────────────────────────────────────

/// A scalar as `print` and `tostring` write it: nil, true, false, the
/// integer, the string. A table is an error.
pub fn scalarText(run: *Run, pos: ast.Pos, v: Value, buf: *[24]u8, what: []const u8) Error![]const u8 {
    return switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .string => |s| s,
        .table => run.fail(pos, .type, "`{s}` takes scalars, not {s}: `for x in l do {s}(x) end` takes a list's items one by one", .{ what, v.typeName(), what }),
    };
}

pub fn stringArg(run: *Run, pos: ast.Pos, b: B, v: Value, what: []const u8) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => run.fail(pos, .type, "`{s}`: {s} must be a string, not {s}", .{ @tagName(b), what, v.typeName() }),
    };
}

pub fn intArg(run: *Run, pos: ast.Pos, b: B, v: Value, what: []const u8) Error!i64 {
    return switch (v) {
        .int => |i| i,
        else => run.fail(pos, .type, "`{s}`: {s} must be an integer, not {s}", .{ @tagName(b), what, v.typeName() }),
    };
}

/// A list, or a table still empty (which becomes one).
pub fn listArg(run: *Run, pos: ast.Pos, b: B, v: Value) Error!*value.Table {
    return switch (v) {
        .table => |t| switch (t.kind) {
            .empty, .list => t,
            .map => run.fail(pos, .type, "`{s}` takes a list, given a map", .{@tagName(b)}),
        },
        else => run.fail(pos, .type, "`{s}` takes a list, not {s}", .{ @tagName(b), v.typeName() }),
    };
}

/// A map, or a table still empty.
pub fn mapArg(run: *Run, pos: ast.Pos, b: B, v: Value) Error!*value.Table {
    return switch (v) {
        .table => |t| switch (t.kind) {
            .empty, .map => t,
            .list => run.fail(pos, .type, "`{s}` takes a map, given a list (`#l` is a list's length)", .{@tagName(b)}),
        },
        else => run.fail(pos, .type, "`{s}` takes a map, not {s}", .{ @tagName(b), v.typeName() }),
    };
}

/// A new list of `items`, the run's.
pub fn listOf(run: *Run, pos: ast.Pos, items: []const Value) Error!Value {
    const out = try run.newTable(pos);
    out.list.ensureTotalCapacity(run.alloc, items.len) catch return run.oom(pos);
    out.list.appendSliceAssumeCapacity(items);
    out.kind = .list;
    return .{ .table = out };
}

/// **THE PRICE OF A BYTE OF BULK WORK** (metal-vmm QUEUE 209, Steve): a
/// step for every 16 bytes, or part of 16, that a read brings, a scan looks
/// at or a search runs over. Measured: a byte read whole costs 0.4 ns, a
/// byte scanned 3.7 ns, an interpreted step 7-15 ns. Everything else a
/// builtin touches stays a step a byte.
pub const bytes_per_step = 16;

pub fn chargeBytes(run: *Run, pos: ast.Pos, n: u64) Error!void {
    return run.charge(pos, std.math.divCeil(u64, n, bytes_per_step) catch unreachable);
}

/// An optional `-`, then decimal digits, within 64 bits; null otherwise.
pub fn parseInteger(s: []const u8) ?i64 {
    const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// The most a sort of `n` items, `bytes` of them in all, can cost: n log n
/// comparisons (pdq's bound, doubled for its worst case) and every byte in
/// each of log n passes.
pub fn sortBound(n: usize, bytes: u64) u64 {
    if (n < 2) return 1;
    const lg: u64 = std.math.log2_int_ceil(usize, n);
    return 2 * @as(u64, n) * lg + bytes * lg;
}

pub const SortContext = struct {
    comparisons: u64 = 0,
    bytes: u64 = 0,

    pub fn lessThan(ctx: *SortContext, a: Value, b: Value) bool {
        ctx.comparisons += 1;
        return switch (a) {
            .int => |x| x < b.int,
            .string => |x| blk: {
                ctx.bytes += @min(x.len, b.string.len);
                break :blk std.mem.lessThan(u8, x, b.string);
            },
            else => unreachable,
        };
    }
};

test "every builtin has one declaration, and none takes more than the interpreter's buffer holds" {
    // The table's comptime checks say so; this names the count, so a
    // builtin added or dropped shows here too.
    try std.testing.expectEqual(std.enums.values(B).len, specs.values.len);
    for (std.enums.values(B)) |b| {
        const s = specs.get(b);
        try std.testing.expectEqual(b, s.name);
        try std.testing.expect(s.at_least <= s.at_most);
    }
}
