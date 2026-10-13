//! **THE BUILTINS**: the store, strings, lists and maps, the host's `now`,
//! and `print` (the interpreter's own, since it takes any number). Each
//! charges steps in proportion to the work it does.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;

/// How many arguments each takes: `at_least` to `at_most`.
fn arity(b: B) struct { at_least: u8, at_most: u8 } {
    return switch (b) {
        .now => .{ .at_least = 0, .at_most = 0 },
        .ls, .stat, .exists, .is_dir, .read, .mkdir, .remove, .remove_tree, .trim, .upper, .lower, .tostring, .tonumber, .sort, .keys, .count => .{ .at_least = 1, .at_most = 1 },
        .replace, .append, .split, .join, .starts_with, .ends_with, .contains, .find, .push, .has_key => .{ .at_least = 2, .at_most = 2 },
        .sub => .{ .at_least = 2, .at_most = 3 },
        .print => .{ .at_least = 0, .at_most = 255 },
    };
}

pub fn tooMany(run: *Run, pos: ast.Pos, b: B) Error {
    const a = arity(b);
    return run.fail(pos, .argument, "`{s}` takes at most {d} arguments", .{ @tagName(b), a.at_most });
}

/// A scalar as `print` and `tostring` write it: nil, true, false, the
/// integer, the string. A table is an error.
pub fn scalarText(run: *Run, pos: ast.Pos, v: Value, buf: *[24]u8, what: []const u8) Error![]const u8 {
    return switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .string => |s| s,
        .table => run.fail(pos, .type, "`{s}` takes scalars, not {s}: walk it", .{ what, v.typeName() }),
    };
}

pub fn call(run: *Run, pos: ast.Pos, b: B, args: []const Value) Error!Value {
    const a = arity(b);
    if (args.len < a.at_least or args.len > a.at_most) {
        if (a.at_least == a.at_most) return run.fail(pos, .argument, "`{s}` takes {d} arguments, given {d}", .{ @tagName(b), a.at_least, args.len });
        return run.fail(pos, .argument, "`{s}` takes {d} to {d} arguments, given {d}", .{ @tagName(b), a.at_least, a.at_most, args.len });
    }
    switch (b) {
        .now => return .{ .int = run.now },
        .tostring => {
            var buf: [24]u8 = undefined;
            const t = try scalarText(run, pos, args[0], &buf, "tostring");
            try run.charge(pos, t.len);
            return .{ .string = run.alloc.dupe(u8, t) catch return run.oom(pos) };
        },
        .push => {
            const t = try listArg(run, pos, b, args[0]);
            if (args[1] == .nil) return run.fail(pos, .type, "a list cannot hold nil", .{});
            t.list.append(run.alloc, args[1]) catch return run.oom(pos);
            t.kind = .list;
            return .nil;
        },
        .keys => {
            const t = try mapArg(run, pos, b, args[0]);
            const out = try run.newTable(pos);
            try run.charge(pos, t.map.count());
            out.list.ensureTotalCapacity(run.alloc, t.map.count()) catch return run.oom(pos);
            for (t.map.keys()) |k| out.list.appendAssumeCapacity(.{ .string = k });
            out.kind = .list;
            return .{ .table = out };
        },
        .count => {
            const t = try mapArg(run, pos, b, args[0]);
            return .{ .int = @intCast(t.map.count()) };
        },
        .has_key => {
            const t = try mapArg(run, pos, b, args[0]);
            const k = try stringArg(run, pos, b, args[1], "its key");
            try run.charge(pos, k.len);
            return .{ .boolean = t.map.contains(k) };
        },
        else => return run.fail(pos, .argument, "`{s}` is not built yet", .{@tagName(b)}),
    }
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
