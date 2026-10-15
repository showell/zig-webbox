//! **LISTS' AND MAPS' BUILTINS**: growing a list, sorting it (by value, or
//! a list of maps by a key), reversing it, and a map's keys and size. Each
//! charges a step an element it touches; a sort is charged its bound
//! before it runs.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const spec = bi.spec;

pub const specs = [_]bi.Spec{
    spec(.push, 2, 2, push),
    spec(.sort, 1, 2, sort),
    spec(.reverse, 1, 1, reverse),
    spec(.keys, 1, 1, keys),
    spec(.has_key, 2, 2, hasKey),
    spec(.count, 1, 1, count),
};

fn push(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.listArg(run, pos, .push, args[0]);
    if (args[1] == .nil) return run.fail(pos, .type, "a list cannot hold nil", .{});
    t.list.append(run.alloc, args[1]) catch return run.oom(pos);
    t.kind = .list;
    return .nil;
}

fn reverse(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.listArg(run, pos, .reverse, args[0]);
    try run.charge(pos, t.list.items.len);
    std.mem.reverse(Value, t.list.items);
    return .nil;
}

/// **`keys(m)`**: a map's keys, in the order they were first set.
fn keys(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.mapArg(run, pos, .keys, args[0]);
    const out = try run.newTable(pos);
    try run.charge(pos, t.map.count());
    out.list.ensureTotalCapacity(run.alloc, t.map.count()) catch return run.oom(pos);
    for (t.map.keys()) |k| out.list.appendAssumeCapacity(.{ .string = k });
    out.kind = .list;
    return .{ .table = out };
}

fn hasKey(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.mapArg(run, pos, .has_key, args[0]);
    const k = try bi.stringArg(run, pos, .has_key, args[1], "its key");
    try run.charge(pos, k.len);
    return .{ .boolean = t.map.contains(k) };
}

/// **`count(t)`**: a map's entries, or a list's length (`#l` too).
fn count(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = switch (args[0]) {
        .table => |t| t,
        else => return run.fail(pos, .type, "`count` takes a map or a list, not {s}", .{args[0].typeName()}),
    };
    return .{ .int = @intCast(if (t.kind == .list) t.list.items.len else t.map.count()) };
}

/// **`sort(l)`**: in place, all integers or all strings. **`sort(rows,
/// key)`**: by a key (`sortByKey`).
fn sort(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.listArg(run, pos, .sort, args[0]);
    if (args.len > 1) return sortByKey(run, pos, t, args[1]);
    const items = t.list.items;
    if (items.len == 0) return .nil;
    const kind = std.meta.activeTag(items[0]);
    for (items, 0..) |item, i| {
        if (std.meta.activeTag(item) != kind or (kind != .int and kind != .string))
            return run.fail(pos, .type, "`sort` takes all integers or all strings, and item {d} is {s}", .{ i + 1, item.typeName() });
    }
    // **CHARGED BEFORE IT RUNS**, its bound: a step a comparison and a
    // step a byte, every byte compared at most once a pass.
    var bytes: u64 = 0;
    if (kind == .string) for (items) |item| {
        bytes += item.string.len;
    };
    try run.charge(pos, bi.sortBound(items.len, bytes));
    var ctx: bi.SortContext = .{};
    std.sort.pdq(Value, items, &ctx, bi.SortContext.lessThan);
    return .nil;
}

const KeyContext = struct {
    key: []const u8,
    inner: bi.SortContext = .{},

    fn lessThan(ctx: *KeyContext, x: Value, y: Value) bool {
        return ctx.inner.lessThan(x.table.map.get(ctx.key).?, y.table.map.get(ctx.key).?);
    }
};

/// **`sort(rows, key)`**: a list of maps, in place, by each one's `key`,
/// all integers or all strings. **STABLE**: rows with equal keys keep
/// their order, so a sort by one key then another orders by both.
fn sortByKey(run: *Run, pos: ast.Pos, t: *value.Table, key_arg: Value) Error!Value {
    const key = try bi.stringArg(run, pos, .sort, key_arg, "its key");
    const items = t.list.items;
    if (items.len == 0) return .nil;
    var kind: ?std.meta.Tag(Value) = null;
    var bytes: u64 = 0;
    for (items, 0..) |item, i| {
        const m = switch (item) {
            .table => |m| if (m.kind == .map) m else return run.fail(pos, .type, "`sort` by a key takes a list of maps, and item {d} is {s}", .{ i + 1, item.typeName() }),
            else => return run.fail(pos, .type, "`sort` by a key takes a list of maps, and item {d} is {s}", .{ i + 1, item.typeName() }),
        };
        const v = m.map.get(key) orelse return run.fail(pos, .index, "`sort`: item {d} has no \"{s}\"", .{ i + 1, key });
        const k = std.meta.activeTag(v);
        if ((k != .int and k != .string) or (kind != null and kind.? != k))
            return run.fail(pos, .type, "`sort` by \"{s}\" takes all integers or all strings, and item {d}'s is {s}", .{ key, i + 1, v.typeName() });
        kind = k;
        if (k == .string) bytes += v.string.len;
    }
    try run.charge(pos, bi.sortBound(items.len, bytes));
    var ctx: KeyContext = .{ .key = key };
    std.sort.block(Value, items, &ctx, KeyContext.lessThan);
    return .nil;
}
