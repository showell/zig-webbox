//! **REGULAR EXPRESSIONS' BUILTINS** (metal-vmm QUEUE 230, chunk 2):
//! `re_find` and `re_match`, over regex.zig's linear-time subset. A pattern
//! is compiled once a run (the run's cache, in the machine's memory), its
//! compile a step a byte; a search is charged a step a byte of the string
//! (and one for its end) times the pattern's instructions, so what a
//! budget allows is what it says, whatever the pattern.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");
const regex = @import("regex.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;
const spec = bi.spec;

pub const specs = [_]bi.Spec{
    spec(.re_find, 2, 2, reFind),
    spec(.re_match, 2, 2, reMatch),
};

/// The pattern's compiled program: the run's, or compiled now and kept.
fn program(run: *Run, pos: ast.Pos, b: B, pattern: []const u8) Error!*regex.Cached {
    if (run.patterns.get(pattern)) |got| return got;
    if (pattern.len > regex.pattern_most) return run.fail(pos, .argument, "`{s}`'s pattern is {d} bytes, and one may be at most {d}", .{ @tagName(b), pattern.len, regex.pattern_most });
    try run.charge(pos, pattern.len + 1);
    run.tally(pattern.len + 1);
    var refused: regex.Refusal = undefined;
    return run.patterns.put(run.machine, pattern, &refused) catch |e| switch (e) {
        error.OutOfMemory => run.machineOom(pos),
        error.Refused => run.fail(pos, .argument, "`{s}`'s pattern, at its byte {d}: {s}", .{ @tagName(b), refused.at + 1, refused.message }),
    };
}

/// The search, charged as it goes: when the steps left would not cover
/// the whole of it, it stops where they run out.
fn searched(run: *Run, pos: ast.Pos, b: B, s: []const u8, pattern: []const u8) Error!struct { ?regex.Found, *regex.Cached } {
    const c = try program(run, pos, b, pattern);
    const per: u64 = c.program.insts.len;
    const most = (run.budgets.steps -| run.steps) / per + 1;
    const r = regex.search(&c.program, &c.scratch, s, most);
    run.tally(r.work);
    try run.charge(pos, r.positions * per);
    std.debug.assert(r.finished);
    return .{ r.found, c };
}

/// **`re_find(s, pattern)`**: the leftmost match of `pattern` in `s`, the
/// one a backtracking matcher would find first, as `{at, text}` (`at`
/// 1-based) with `group`, the capture group's text ("" where the match did
/// not go through it), when the pattern has one; nil when there is none.
fn reFind(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const s = try bi.stringArg(run, pos, .re_find, args[0], "its first argument");
    const pattern = try bi.stringArg(run, pos, .re_find, args[1], "its pattern");
    const found, const c = try searched(run, pos, .re_find, s, pattern);
    const f = found orelse return .nil;
    const a = run.alloc;
    const m = try run.newTable(pos);
    m.kind = .map;
    m.map.put(a, "at", .{ .int = @intCast(f.start + 1) }) catch return run.oom(pos);
    m.map.put(a, "text", .{ .string = s[f.start..f.end] }) catch return run.oom(pos);
    if (c.program.group) m.map.put(a, "group", .{ .string = if (f.group) |g| s[g[0]..g[1]] else "" }) catch return run.oom(pos);
    return .{ .table = m };
}

/// **`re_match(s, pattern)`**: whether `s` holds a match of `pattern`,
/// anywhere, as `grep` would say of a line: `^` and `$` pin it to the
/// whole.
fn reMatch(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const s = try bi.stringArg(run, pos, .re_match, args[0], "its first argument");
    const pattern = try bi.stringArg(run, pos, .re_match, args[1], "its pattern");
    const found, _ = try searched(run, pos, .re_match, s, pattern);
    return .{ .boolean = found != null };
}
