//! **TEXT'S BUILTINS**: splitting and joining, looking for text, cutting
//! and changing it, `like`'s patterns, and text to and from integers. Plain
//! text everywhere: not Lua's patterns. Each charges a step a byte it looks
//! at.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;
const spec = bi.spec;

pub const specs = [_]bi.Spec{
    spec(.split, 2, 2, split),
    spec(.join, 2, 2, join),
    spec(.lines, 1, 1, lines),
    spec(.words, 1, 1, words),
    spec(.starts_with, 2, 2, looks(.starts_with)),
    spec(.ends_with, 2, 2, looks(.ends_with)),
    spec(.contains, 2, 2, looks(.contains)),
    spec(.find, 2, 2, find),
    spec(.sub, 2, 3, sub),
    spec(.trim, 1, 1, trim),
    spec(.upper, 1, 1, cased(.upper)),
    spec(.lower, 1, 1, cased(.lower)),
    spec(.like, 2, 2, like),
    spec(.tostring, 1, 1, tostring),
    spec(.tonumber, 1, 1, tonumber),
};

fn split(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .split, args[0], "its string");
    const sep = try bi.stringArg(run, pos, .split, args[1], "its separator");
    if (sep.len == 0) return run.fail(pos, .argument, "`split` by \"\" is an error: there is no empty separator", .{});
    try run.charge(pos, str.len);
    const out = try run.newTable(pos);
    var it = std.mem.splitSequence(u8, str, sep);
    while (it.next()) |part| out.list.append(run.alloc, .{ .string = part }) catch return run.oom(pos);
    out.kind = .list;
    return .{ .table = out };
}

fn join(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const t = try bi.listArg(run, pos, .join, args[0]);
    const sep = try bi.stringArg(run, pos, .join, args[1], "its separator");
    var buf: std.ArrayList(u8) = .empty;
    for (t.list.items, 0..) |item, i| {
        if (i > 0) buf.appendSlice(run.alloc, sep) catch return run.oom(pos);
        var nb: [24]u8 = undefined;
        const piece = switch (item) {
            .string => |x| x,
            .int => |n| std.fmt.bufPrint(&nb, "{d}", .{n}) catch unreachable,
            else => return run.fail(pos, .type, "`join` takes strings and integers, and item {d} is {s}", .{ i + 1, item.typeName() }),
        };
        try run.charge(pos, piece.len + sep.len);
        buf.appendSlice(run.alloc, piece) catch return run.oom(pos);
    }
    return .{ .string = buf.items };
}

/// **`lines(s)`**: `s` split at each `\n`, with no last empty piece after a
/// final newline (`#lines("a\nb\n")` is 2).
fn lines(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .lines, args[0], "its string");
    try run.charge(pos, str.len);
    const out = try run.newTable(pos);
    out.kind = .list;
    var rest = str;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        out.list.append(run.alloc, .{ .string = line }) catch return run.oom(pos);
        rest = if (nl) |i| rest[i + 1 ..] else "";
    }
    return .{ .table = out };
}

/// **`words(s)`**: the runs between ASCII whitespace, none empty.
fn words(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .words, args[0], "its string");
    try run.charge(pos, str.len);
    const out = try run.newTable(pos);
    out.kind = .list;
    var it = std.mem.tokenizeAny(u8, str, " \t\r\n\x0b\x0c");
    while (it.next()) |w| out.list.append(run.alloc, .{ .string = w }) catch return run.oom(pos);
    return .{ .table = out };
}

const Look = enum { starts_with, ends_with, contains };

fn looks(comptime l: Look) bi.Impl {
    return struct {
        fn f(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
            const b: B = switch (l) {
                inline else => |t| @field(B, @tagName(t)),
            };
            const str = try bi.stringArg(run, pos, b, args[0], "its string");
            const sub_s = try bi.stringArg(run, pos, b, args[1], "what it looks for");
            try run.charge(pos, str.len);
            return .{ .boolean = switch (l) {
                .starts_with => std.mem.startsWith(u8, str, sub_s),
                .ends_with => std.mem.endsWith(u8, str, sub_s),
                .contains => std.mem.indexOf(u8, str, sub_s) != null,
            } };
        }
    }.f;
}

/// **`find(s, t)`**: where `t` first is in `s`, 1-based; nil when absent.
fn find(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .find, args[0], "its string");
    const sub_s = try bi.stringArg(run, pos, .find, args[1], "what it looks for");
    try run.charge(pos, str.len);
    const at = std.mem.indexOf(u8, str, sub_s) orelse return .nil;
    return .{ .int = @intCast(at + 1) };
}

fn sub(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .sub, args[0], "its string");
    const i = try bi.intArg(run, pos, .sub, args[1], "its start");
    const j = if (args.len > 2) try bi.intArg(run, pos, .sub, args[2], "its end") else -1;
    const r = subRange(str.len, i, j);
    try run.charge(pos, r.len);
    return .{ .string = str[r.start..][0..r.len] };
}

/// Lua's `string.sub` range: 1-based, inclusive, negatives from the end,
/// clamped to the string.
pub fn subRange(len: usize, i: i64, j: i64) struct { start: usize, len: usize } {
    const n: i64 = @intCast(len);
    var a: i64 = if (i < 0) @max(n + i + 1, 1) else if (i == 0) 1 else i;
    var z: i64 = if (j < 0) n + j + 1 else @min(j, n);
    if (a < 1) a = 1;
    if (z > n) z = n;
    if (a > z) return .{ .start = 0, .len = 0 };
    return .{ .start = @intCast(a - 1), .len = @intCast(z - a + 1) };
}

fn trim(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .trim, args[0], "its string");
    try run.charge(pos, str.len);
    return .{ .string = std.mem.trim(u8, str, " \t\r\n") };
}

const Case = enum { upper, lower };

fn cased(comptime c: Case) bi.Impl {
    return struct {
        fn f(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
            const b: B = if (c == .upper) .upper else .lower;
            const str = try bi.stringArg(run, pos, b, args[0], "its string");
            try run.charge(pos, str.len);
            const out = run.alloc.alloc(u8, str.len) catch return run.oom(pos);
            for (str, out) |ch, *o| o.* = if (c == .upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
            return .{ .string = out };
        }
    }.f;
}

fn tostring(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    var buf: [24]u8 = undefined;
    const t = try bi.scalarText(run, pos, args[0], &buf, "tostring");
    try run.charge(pos, t.len);
    return .{ .string = run.alloc.dupe(u8, t) catch return run.oom(pos) };
}

fn tonumber(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const str = try bi.stringArg(run, pos, .tonumber, args[0], "its string");
    try run.charge(pos, str.len);
    return .{ .int = bi.parseInteger(str) orelse return run.fail(pos, .argument, "`tonumber`: \"{s}\" is not an integer (an optional `-`, then decimal digits)", .{str[0..@min(str.len, 40)]}) };
}

/// **`like(s, pattern)`**: whether the whole of `s` matches `pattern`, where
/// `*` is any run of bytes (none included), `?` is one byte, and every other
/// byte is itself. No classes, no escapes: not Lua's patterns.
fn like(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const s = try bi.stringArg(run, pos, .like, args[0], "its string");
    const p = try bi.stringArg(run, pos, .like, args[1], "its pattern");
    return .{ .boolean = try likeCharged(run, pos, s, p) };
}

/// `like`'s match: the classic walk that goes back only to the last `*`.
/// Every byte it looks at is a step, so a pattern that backtracks a long
/// string runs out of steps.
pub fn likeCharged(run: *Run, pos: ast.Pos, s: []const u8, p: []const u8) Error!bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    var looked: u64 = 0;
    while (si < s.len) {
        looked += 1;
        if (looked == 1024) {
            try run.charge(pos, looked);
            looked = 0;
        }
        if (pi < p.len and (p[pi] == '?' or (p[pi] != '*' and p[pi] == s[si]))) {
            si += 1;
            pi += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            mark = si;
            pi += 1;
        } else if (star) |st| {
            pi = st + 1;
            mark += 1;
            si = mark;
        } else {
            try run.charge(pos, looked);
            return false;
        }
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    try run.charge(pos, looked + p.len);
    return pi == p.len;
}
