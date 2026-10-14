//! **THE BUILTINS**: the store, strings, lists and maps, the host's `now`,
//! and `print` (the interpreter's own, since it takes any number). Each
//! charges steps in proportion to the work it does.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");

const store = @import("../store.zig");

const v31 = @import("builtins_v31.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;

/// How many arguments each takes: `at_least` to `at_most`.
fn arity(b: B) struct { at_least: u8, at_most: u8 } {
    return switch (b) {
        .now, .budget => .{ .at_least = 0, .at_most = 0 },
        .ls, .stat, .exists, .is_dir, .read, .mkdir, .remove, .remove_tree, .walk, .trim, .upper, .lower, .tostring, .tonumber, .keys, .count, .lines, .words, .reverse, .date, .seconds, .human => .{ .at_least = 1, .at_most = 1 },
        .replace, .append, .split, .join, .starts_with, .ends_with, .contains, .find, .push, .has_key, .like, .pad, .table => .{ .at_least = 2, .at_most = 2 },
        .sort => .{ .at_least = 1, .at_most = 2 },
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
        // A map's entries, or a list's length (`#l` too).
        .count => {
            const t = switch (args[0]) {
                .table => |t| t,
                else => return run.fail(pos, .type, "`count` takes a map or a list, not {s}", .{args[0].typeName()}),
            };
            return .{ .int = @intCast(if (t.kind == .list) t.list.items.len else t.map.count()) };
        },
        .has_key => {
            const t = try mapArg(run, pos, b, args[0]);
            const k = try stringArg(run, pos, b, args[1], "its key");
            try run.charge(pos, k.len);
            return .{ .boolean = t.map.contains(k) };
        },
        // ── the store ──
        .ls, .stat, .exists, .is_dir, .read => return storeRead(run, pos, b, args),
        .walk => return walk(run, pos, args[0]),
        .budget => return budgetLeft(run, pos),
        .lines, .words => return v31.splitText(run, pos, b, args[0]),
        .like => return v31.like(run, pos, args[0], args[1]),
        .date => return v31.date(run, pos, args[0]),
        .seconds => return v31.seconds(run, pos, args[0]),
        .human => return v31.human(run, pos, args[0]),
        .pad => return v31.pad(run, pos, args[0], args[1]),
        .table => return v31.table(run, pos, args[0], args[1]),
        .reverse => {
            const t = try listArg(run, pos, b, args[0]);
            try run.charge(pos, t.list.items.len);
            std.mem.reverse(Value, t.list.items);
            return .nil;
        },
        .replace, .append, .mkdir, .remove, .remove_tree => return storeChange(run, pos, b, args),
        // ── strings ──
        .split => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            const sep = try stringArg(run, pos, b, args[1], "its separator");
            if (sep.len == 0) return run.fail(pos, .argument, "`split` by \"\" is an error: there is no empty separator", .{});
            try run.charge(pos, str.len);
            const out = try run.newTable(pos);
            var it = std.mem.splitSequence(u8, str, sep);
            while (it.next()) |part| out.list.append(run.alloc, .{ .string = part }) catch return run.oom(pos);
            out.kind = .list;
            return .{ .table = out };
        },
        .join => {
            const t = try listArg(run, pos, b, args[0]);
            const sep = try stringArg(run, pos, b, args[1], "its separator");
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
        },
        .starts_with, .ends_with, .contains => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            const sub_s = try stringArg(run, pos, b, args[1], "what it looks for");
            try run.charge(pos, str.len);
            return .{ .boolean = switch (b) {
                .starts_with => std.mem.startsWith(u8, str, sub_s),
                .ends_with => std.mem.endsWith(u8, str, sub_s),
                else => std.mem.indexOf(u8, str, sub_s) != null,
            } };
        },
        .find => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            const sub_s = try stringArg(run, pos, b, args[1], "what it looks for");
            try run.charge(pos, str.len);
            const at = std.mem.indexOf(u8, str, sub_s) orelse return .nil;
            return .{ .int = @intCast(at + 1) };
        },
        .sub => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            const i = try intArg(run, pos, b, args[1], "its start");
            const j = if (args.len > 2) try intArg(run, pos, b, args[2], "its end") else -1;
            const r = subRange(str.len, i, j);
            try run.charge(pos, r.len);
            return .{ .string = str[r.start..][0..r.len] };
        },
        .trim => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            try run.charge(pos, str.len);
            return .{ .string = std.mem.trim(u8, str, " \t\r\n") };
        },
        .upper, .lower => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            try run.charge(pos, str.len);
            const out = run.alloc.alloc(u8, str.len) catch return run.oom(pos);
            for (str, out) |c, *o| o.* = if (b == .upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
            return .{ .string = out };
        },
        .tonumber => {
            const str = try stringArg(run, pos, b, args[0], "its string");
            try run.charge(pos, str.len);
            return .{ .int = parseInteger(str) orelse return run.fail(pos, .argument, "`tonumber`: \"{s}\" is not an integer (an optional `-`, then decimal digits)", .{str[0..@min(str.len, 40)]}) };
        },
        // ── lists ──
        .sort => {
            const t = try listArg(run, pos, b, args[0]);
            if (args.len > 1) return v31.sortByKey(run, pos, t, args[1]);
            const items = t.list.items;
            if (items.len == 0) return .nil;
            const kind = std.meta.activeTag(items[0]);
            for (items, 0..) |item, i| {
                if (std.meta.activeTag(item) != kind or (kind != .int and kind != .string))
                    return run.fail(pos, .type, "`sort` takes all integers or all strings, and item {d} is {s}", .{ i + 1, item.typeName() });
            }
            // **CHARGED BEFORE IT RUNS**, its bound: a step a comparison
            // and a step a byte, every byte compared at most once a pass.
            var bytes: u64 = 0;
            if (kind == .string) for (items) |item| {
                bytes += item.string.len;
            };
            try run.charge(pos, sortBound(items.len, bytes));
            var ctx: SortContext = .{};
            std.sort.pdq(Value, items, &ctx, SortContext.lessThan);
            return .nil;
        },
        .print => unreachable, // the interpreter's own
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

/// An optional `-`, then decimal digits, within 64 bits; null otherwise.
pub fn parseInteger(s: []const u8) ?i64 {
    const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

// ── the store ────────────────────────────────────────────────────────────

/// **A SCRIPT'S PATH, CONFINED TO THE ROOT** (README, "Paths"): every part
/// a name FAT holds (so `.`, `..` and empty parts are refused, and a
/// leading `/`), joined to the root. `""` is the root, for the calls that
/// only look (`allow_root`); every change needs at least one part.
const Path = struct { full: []const u8, rel: []const u8 };

fn pathArg(run: *Run, pos: ast.Pos, b: B, v: Value, allow_root: bool) Error!Path {
    const rel = try stringArg(run, pos, b, v, "its path");
    try run.charge(pos, rel.len);
    if (rel.len == 0) {
        if (!allow_root) return run.fail(pos, .argument, "`{s}(\"\")` would act on the whole root: a change needs a path of at least one part", .{@tagName(b)});
        return .{ .full = run.root, .rel = "" };
    }
    if (rel[0] == '/') return run.fail(pos, .argument, "`{s}`: \"{s}\" is absolute: paths are relative to the data root", .{ @tagName(b), rel });
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (!store.fatName(part)) return run.fail(pos, .argument, "`{s}`: \"{s}\" has a part (\"{s}\") that is not a name: no `.`, `..`, empty parts or characters FAT refuses", .{ @tagName(b), rel, part });
    }
    const full = std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ run.root, rel }) catch return run.oom(pos);
    return .{ .full = full, .rel = rel };
}

fn storeFailed(run: *Run, pos: ast.Pos, b: B, rel: []const u8, e: anyerror) Error {
    if (e == error.OutOfMemory) return run.oom(pos);
    return run.fail(pos, .store, "`{s}(\"{s}\")`: {s}", .{ @tagName(b), rel, @errorName(e) });
}

fn countRead(run: *Run, pos: ast.Pos) Error!void {
    if (run.reads >= run.budgets.reads) return run.budgetStop(pos, .reads);
    run.reads += 1;
}

fn storeRead(run: *Run, pos: ast.Pos, b: B, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, b, args[0], b == .ls or b == .stat or b == .exists);
    try countRead(run, pos);
    const io = run.io;
    const a = run.alloc;
    switch (b) {
        .ls => {
            // The store lists a missing folder as empty; a script's `ls` of
            // one is an error (README, "The store").
            const st = (store.statOrNull(io, a, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e)) orelse return storeFailed(run, pos, b, p.rel, error.FileNotFound);
            if (st.kind != .directory) return storeFailed(run, pos, b, p.rel, error.NotDir);
            const entries = store.list(io, a, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e);
            const names = a.alloc([]const u8, entries.len) catch return run.oom(pos);
            for (entries, names) |en, *n| n.* = en.name;
            var name_bytes: u64 = 0;
            for (names) |n| name_bytes += n.len;
            try run.charge(pos, entries.len + sortBound(names.len, name_bytes));
            var ctx: SortContext = .{};
            std.sort.pdq([]const u8, names, &ctx, struct {
                fn lt(c: *SortContext, x: []const u8, y: []const u8) bool {
                    c.comparisons += 1;
                    c.bytes += @min(x.len, y.len);
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            const out = try run.newTable(pos);
            out.list.ensureTotalCapacity(a, names.len) catch return run.oom(pos);
            for (names) |n| out.list.appendAssumeCapacity(.{ .string = n });
            out.kind = .list;
            return .{ .table = out };
        },
        .stat => {
            const st = store.stat(io, a, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e);
            const out = try run.newTable(pos);
            out.map.put(a, "size", .{ .int = @intCast(st.size) }) catch return run.oom(pos);
            out.map.put(a, "kind", .{ .string = @tagName(st.kind) }) catch return run.oom(pos);
            out.map.put(a, "modified", .{ .int = modifiedSeconds(st.mtime) }) catch return run.oom(pos);
            out.kind = .map;
            return .{ .table = out };
        },
        .exists => return .{ .boolean = store.has(io, a, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e) },
        .is_dir => {
            const st = store.statOrNull(io, a, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e);
            return .{ .boolean = if (st) |x| x.kind == .directory else false };
        },
        .read => {
            // The read budget's rest is the read's limit (README, "Budgets").
            const left = run.budgets.read_bytes -| run.read_bytes;
            const bytes = store.read(io, a, p.full, .limited(@intCast(@min(left, std.math.maxInt(usize))))) catch |e| switch (e) {
                error.StreamTooLong => return run.budgetStop(pos, .read_bytes),
                else => return storeFailed(run, pos, b, p.rel, e),
            };
            run.read_bytes += bytes.len;
            try run.charge(pos, bytes.len);
            return .{ .string = bytes };
        },
        else => unreachable,
    }
}

fn storeChange(run: *Run, pos: ast.Pos, b: B, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, b, args[0], false);
    const data: []const u8 = switch (b) {
        .replace, .append => try stringArg(run, pos, b, args[1], "what it writes"),
        else => "",
    };
    if (run.changes >= run.budgets.changes) return run.budgetStop(pos, .changes);
    if (data.len > run.budgets.change_bytes -| run.change_bytes) return run.budgetStop(pos, .change_bytes);
    run.changes += 1;
    run.change_bytes += data.len;
    try run.charge(pos, data.len);
    const io = run.io;
    const a = run.alloc;
    const op: []const u8 = @tagName(b);
    // **ITS LOG ENTRY'S ROOM FIRST**: a change made and then not logged
    // (the arena full) would be on the disk but missing from `effects`,
    // which is how a host knows to rebuild what it remembers.
    run.effects.ensureUnusedCapacity(a, 1) catch return run.oom(pos);
    // The store takes removing what is not there as done; a script's
    // removal of a missing path is an error, logged (README, "The store").
    const missing: bool = switch (b) {
        .remove, .remove_tree => (store.statOrNull(io, a, p.full) catch null) == null,
        else => false,
    };
    const outcome: ?anyerror = if (missing) error.FileNotFound else switch (b) {
        .replace => if (store.replace(io, a, p.full, data, .{})) |_| null else |e| e,
        .append => if (store.append(io, a, p.full, data)) |_| null else |e| e,
        .mkdir => if (store.makeDir(io, a, p.full)) |_| null else |e| e,
        .remove => if (store.remove(io, a, p.full)) |_| null else |e| e,
        .remove_tree => if (store.removeTree(io, a, p.full)) |_| null else |e| e,
        else => unreachable,
    };
    // **EVERY CHANGE ATTEMPTED IS LOGGED**, its outcome with it: a failed
    // one is also why the run stopped.
    run.effects.appendAssumeCapacity(.{ .op = op, .path = p.rel, .outcome = if (outcome) |e| @errorName(e) else "ok" });
    if (outcome) |e| return storeFailed(run, pos, b, p.rel, e);
    return .nil;
}

/// The most a sort of `n` items, `bytes` of them in all, can cost: n log n
/// comparisons (pdq's bound, doubled for its worst case) and every byte in
/// each of log n passes.
pub fn sortBound(n: usize, bytes: u64) u64 {
    if (n < 2) return 1;
    const lg: u64 = std.math.log2_int_ceil(usize, n);
    return 2 * @as(u64, n) * lg + bytes * lg;
}

/// The store's modification time, in whole seconds since the epoch (the
/// floor: a time before 1970 stays before it).
pub fn modifiedSeconds(mtime_ns: i96) i64 {
    return @intCast(@divFloor(mtime_ns, 1_000_000_000));
}

/// What a folder holds, its names sorted, charged as `ls` is: an entry a
/// step and the sort's bound. The read is the caller's to count.
fn sortedEntries(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error![]store.Entry {
    const entries = store.list(run.io, run.alloc, full) catch |e| return storeFailed(run, pos, b, rel, e);
    var name_bytes: u64 = 0;
    for (entries) |en| name_bytes += en.name.len;
    try run.charge(pos, entries.len + sortBound(entries.len, name_bytes));
    std.sort.pdq(store.Entry, entries, {}, struct {
        fn lt(_: void, x: store.Entry, y: store.Entry) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return entries;
}

/// **`walk(p)`** (QUEUE 206): every entry under `p`, depth first, each
/// folder's names sorted and a folder before what it holds, as `{path,
/// size, kind, modified}` with `path` relative to the root. **ONE READ A
/// FOLDER LISTED**, not one an entry: what a walk of the whole root costs
/// is its folders. A folder's size is 0 (the hosts disagree on it). Kept on
/// a stack of its own, not the Zig stack: a tree's depth is the store's.
fn walk(run: *Run, pos: ast.Pos, arg: Value) Error!Value {
    const p = try pathArg(run, pos, .walk, arg, true);
    const a = run.alloc;
    try countRead(run, pos);
    const st = (store.statOrNull(run.io, a, p.full) catch |e| return storeFailed(run, pos, .walk, p.rel, e)) orelse return storeFailed(run, pos, .walk, p.rel, error.FileNotFound);
    if (st.kind != .directory) return storeFailed(run, pos, .walk, p.rel, error.NotDir);
    const Level = struct { rel: []const u8, entries: []store.Entry, at: usize = 0 };
    var levels: std.ArrayList(Level) = .empty;
    levels.append(a, .{ .rel = p.rel, .entries = try sortedEntries(run, pos, .walk, p.full, p.rel) }) catch return run.oom(pos);
    const out = try run.newTable(pos);
    out.kind = .list;
    while (levels.items.len > 0) {
        const top = &levels.items[levels.items.len - 1];
        if (top.at == top.entries.len) {
            _ = levels.pop();
            continue;
        }
        const en = top.entries[top.at];
        top.at += 1;
        const rel = if (top.rel.len == 0) en.name else std.fmt.allocPrint(a, "{s}/{s}", .{ top.rel, en.name }) catch return run.oom(pos);
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ run.root, rel }) catch return run.oom(pos);
        try run.charge(pos, rel.len);
        const es = store.stat(run.io, a, full) catch |e| return storeFailed(run, pos, .walk, rel, e);
        const m = try run.newTable(pos);
        m.map.put(a, "path", .{ .string = rel }) catch return run.oom(pos);
        m.map.put(a, "size", .{ .int = if (es.kind == .directory) 0 else @intCast(es.size) }) catch return run.oom(pos);
        m.map.put(a, "kind", .{ .string = @tagName(es.kind) }) catch return run.oom(pos);
        m.map.put(a, "modified", .{ .int = modifiedSeconds(es.mtime) }) catch return run.oom(pos);
        m.kind = .map;
        out.list.append(a, .{ .table = m }) catch return run.oom(pos);
        if (es.kind == .directory) {
            try countRead(run, pos);
            const entries = try sortedEntries(run, pos, .walk, full, rel);
            levels.append(a, .{ .rel = rel, .entries = entries }) catch return run.oom(pos);
        }
    }
    return .{ .table = out };
}

/// **`budget()`** (QUEUE 206): what is left of each budget a script spends
/// as it runs, so it can stop at a point of its own.
fn budgetLeft(run: *Run, pos: ast.Pos) Error!Value {
    const a = run.alloc;
    const out = try run.newTable(pos);
    const left = [_]struct { []const u8, u64 }{
        .{ "steps", run.budgets.steps -| run.steps },
        .{ "reads", run.budgets.reads -| run.reads },
        .{ "read_bytes", run.budgets.read_bytes -| run.read_bytes },
        .{ "changes", run.budgets.changes -| run.changes },
        .{ "change_bytes", run.budgets.change_bytes -| run.change_bytes },
        .{ "output", run.out_cap -| run.out_len },
    };
    for (left) |kv| out.map.put(a, kv[0], .{ .int = @intCast(@min(kv[1], std.math.maxInt(i64))) }) catch return run.oom(pos);
    out.kind = .map;
    return .{ .table = out };
}
