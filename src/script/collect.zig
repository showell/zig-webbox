//! **COPY AT A YIELD** (metal-vmm QUEUE 211, M1): the values a run still
//! reaches, copied out of its arena into a fresh one of the same budget,
//! and the old arena freed whole. Whatever the script made and let go of
//! goes with it, so a run that yields every minute for a month holds what
//! it keeps, not what it ever made.
//!
//! - **What is kept:** the roots the VM hands over (its frames' slots, its
//!   operands, `attempt`'s answers being made), the top-level `const`s,
//!   and the effects log. Nothing else in the arena is reachable at a
//!   yield: the code and its literals live in the parse's own arena, and
//!   a builtin's buffers (`Run.scan_buf`) are made again when next needed.
//! - **Shared stays shared:** a table reached twice is copied once, and
//!   both references go to the copy. A string (a start and a length)
//!   reached twice is copied once, too: strings have no identity a script
//!   can see, but a copy of each reference would multiply what is kept.
//! - **No recursion:** a table's contents are copied from a worklist, so a
//!   list nested a million deep is copied in a loop.
//! - **Charged and capped:** a step for each value copied and each 16 bytes
//!   of string, and past `Budgets.kept_bytes` the run stops (`budget
//!   kept`).

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");

const Run = interp.Run;
const Value = value.Value;
const Table = value.Table;
const Error = interp.Error;

const Copier = struct {
    r: *Run,
    pos: ast.Pos,
    /// Old table -> its copy.
    seen: std.AutoHashMapUnmanaged(*Table, *Table) = .empty,
    /// **A STRING REACHED TWICE IS COPIED ONCE** (the box's review of M1: a
    /// 160 KB string in a list 200 times was copied 200 times, past the
    /// kept budget): by where it starts and how long it is.
    strings: std.AutoHashMapUnmanaged(struct { ptr: usize, len: usize }, []const u8) = .empty,
    /// Copies whose contents still point into the old arena.
    todo: std.ArrayList(struct { old: *Table, new: *Table }) = .empty,
    values: u64 = 0,
    bytes: u64 = 0,

    fn deinit(c: *Copier) void {
        c.seen.deinit(c.r.machine);
        c.strings.deinit(c.r.machine);
        c.todo.deinit(c.r.machine);
    }

    fn string(c: *Copier, s: []const u8) Error![]const u8 {
        const g = c.strings.getOrPut(c.r.machine, .{ .ptr = @intFromPtr(s.ptr), .len = s.len }) catch return c.r.oom(c.pos);
        if (g.found_existing) return g.value_ptr.*;
        c.bytes += s.len;
        g.value_ptr.* = c.r.alloc.dupe(u8, s) catch {
            _ = c.strings.remove(.{ .ptr = @intFromPtr(s.ptr), .len = s.len });
            return c.r.budgetStop(c.pos, .kept);
        };
        return g.value_ptr.*;
    }

    /// `v` in the fresh arena; a table's contents follow from `todo`.
    fn copy(c: *Copier, v: Value) Error!Value {
        c.values += 1;
        return switch (v) {
            .nil, .boolean, .int => v,
            .string => |s| .{ .string = try c.string(s) },
            .table => |t| .{ .table = try c.table(t) },
        };
    }

    fn table(c: *Copier, old: *Table) Error!*Table {
        const g = c.seen.getOrPut(c.r.machine, old) catch return c.r.oom(c.pos);
        if (g.found_existing) return g.value_ptr.*;
        const new = c.r.alloc.create(Table) catch return c.r.budgetStop(c.pos, .kept);
        new.* = .{ .kind = old.kind };
        g.value_ptr.* = new;
        c.todo.append(c.r.machine, .{ .old = old, .new = new }) catch return c.r.oom(c.pos);
        return new;
    }

    /// Every table's contents copied, the worklist emptied.
    fn drain(c: *Copier) Error!void {
        const a = c.r.alloc;
        while (c.todo.pop()) |job| {
            const old = job.old;
            const new = job.new;
            // **THE ROOM KEPT TOO**: a list literal half built when its
            // item's call yielded has reserved room for the rest (the box's
            // review of M1: a copy with only what it held, and the next item
            // appended into room that wasn't there).
            new.list.ensureTotalCapacity(a, old.list.capacity) catch return c.r.budgetStop(c.pos, .kept);
            for (old.list.items) |item| new.list.appendAssumeCapacity(try c.copy(item));
            new.map.ensureTotalCapacity(a, old.map.count()) catch return c.r.budgetStop(c.pos, .kept);
            var it = old.map.iterator();
            while (it.next()) |e| {
                const k = try c.string(e.key_ptr.*);
                new.map.putAssumeCapacity(k, try c.copy(e.value_ptr.*));
            }
        }
    }
};

/// **THE ARENA TRADED FOR A FRESH ONE** holding only what `slots` (every
/// slice of values the caller still reaches) and `tables` (single tables
/// it holds) reach, with the run's consts and effects. The slices and
/// tables are updated in place to the copies.
pub fn collect(r: *Run, pos: ast.Pos, slots: []const []Value, tables: []const *?*Table) Error!void {
    var old = r.budgeted.*;
    r.budgeted.* = .{ .backing = old.backing, .limit = old.limit };
    var c: Copier = .{ .r = r, .pos = pos };
    defer c.deinit();
    // **THE EFFECTS FIRST**: the run reports them however it ends. Should
    // even they not fit, the old arena is put back, and the run stops
    // with what it had.
    var effects: std.ArrayList(interp.Effect) = .empty;
    copyEffects(&c, &effects) catch |e| {
        r.budgeted.deinit();
        r.budgeted.* = old;
        return if (e == error.OutOfMemory) e else r.budgetStop(pos, .kept);
    };
    r.effects = effects;
    // From here the fresh arena holds what the run reports (the effects,
    // a stop's message), and the old one goes, however this ends.
    defer old.deinit();
    for (slots) |sl| for (sl) |*v| {
        v.* = try c.copy(v.*);
    };
    for (tables) |t| if (t.*) |old_t| {
        t.* = try c.table(old_t);
    };
    const consts = r.alloc.alloc(?Value, r.consts.len) catch return r.budgetStop(pos, .kept);
    for (r.consts, consts) |k, *out| out.* = if (k) |v| try c.copy(v) else null;
    r.consts = consts;
    try c.drain();
    // What the old arena held that no copy reaches is gone with it.
    r.tail_ptr = null;
    r.tail_used = 0;
    r.tail_cap = 0;
    r.scan_buf = &.{};
    r.tally(c.values + c.bytes);
    try r.charge(pos, c.values + (c.bytes + bi.bytes_per_step - 1) / bi.bytes_per_step);
    if (r.budgeted.held > r.budgets.kept_bytes) return r.budgetStop(pos, .kept);
}

fn copyEffects(c: *Copier, effects: *std.ArrayList(interp.Effect)) Error!void {
    const r = c.r;
    effects.ensureTotalCapacity(r.alloc, r.effects.items.len) catch return error.Stop;
    for (r.effects.items) |e| {
        c.bytes += e.path.len;
        const path = r.alloc.dupe(u8, e.path) catch return error.Stop;
        effects.appendAssumeCapacity(.{ .op = e.op, .path = path, .outcome = e.outcome });
    }
}
