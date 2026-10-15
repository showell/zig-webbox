//! **THE STORE'S BUILTINS**: what a script reads of the data root and what
//! it changes there, every path confined to the root, every read counted
//! against the read budgets and every change logged (README, "The store").
//! Only through webbox's `store`, so a script does the same on Linux and on
//! metal.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");

const store = @import("../store.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;
const spec = bi.spec;

pub const specs = [_]bi.Spec{
    spec(.ls, 1, 1, ls),
    spec(.stat, 1, 1, stat),
    spec(.exists, 1, 1, exists),
    spec(.is_dir, 1, 1, isDir),
    spec(.read, 1, 1, read),
    spec(.walk, 1, 1, walk),
    spec(.replace, 2, 2, change(.replace)),
    spec(.append, 2, 2, change(.append)),
    spec(.mkdir, 1, 1, change(.mkdir)),
    spec(.remove, 1, 1, change(.remove)),
    spec(.remove_tree, 1, 1, change(.remove_tree)),
};

// ── paths ────────────────────────────────────────────────────────────────

/// **A SCRIPT'S PATH, CONFINED TO THE ROOT** (README, "Paths"): every part
/// a name FAT holds (so `.`, `..` and empty parts are refused, and a
/// leading `/`), joined to the root. `""` is the root, for the calls that
/// only look (`allow_root`); every change needs at least one part.
const Path = struct { full: []const u8, rel: []const u8 };

fn pathArg(run: *Run, pos: ast.Pos, b: B, v: Value, allow_root: bool) Error!Path {
    const rel = try bi.stringArg(run, pos, b, v, "its path");
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

/// The store's modification time, in whole seconds since the epoch (the
/// floor: a time before 1970 stays before it).
pub fn modifiedSeconds(mtime_ns: i96) i64 {
    return @intCast(@divFloor(mtime_ns, 1_000_000_000));
}

// ── reading ──────────────────────────────────────────────────────────────

/// **`ls(p)`**: the names in a folder, sorted. The store lists a missing
/// folder as empty; a script's `ls` of one is an error (README, "The
/// store").
fn ls(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .ls, args[0], true);
    try countRead(run, pos);
    const a = run.alloc;
    const st = (store.statOrNull(run.io, a, p.full) catch |e| return storeFailed(run, pos, .ls, p.rel, e)) orelse return storeFailed(run, pos, .ls, p.rel, error.FileNotFound);
    if (st.kind != .directory) return storeFailed(run, pos, .ls, p.rel, error.NotDir);
    const entries = try sortedEntries(run, pos, .ls, p.full, p.rel);
    const out = try run.newTable(pos);
    out.list.ensureTotalCapacity(a, entries.len) catch return run.oom(pos);
    for (entries) |en| out.list.appendAssumeCapacity(.{ .string = en.name });
    out.kind = .list;
    return .{ .table = out };
}

/// **`stat(p)`**: `{size, kind, modified}`.
fn stat(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .stat, args[0], true);
    try countRead(run, pos);
    const a = run.alloc;
    const st = store.stat(run.io, a, p.full) catch |e| return storeFailed(run, pos, .stat, p.rel, e);
    const out = try run.newTable(pos);
    out.map.put(a, "size", .{ .int = @intCast(st.size) }) catch return run.oom(pos);
    out.map.put(a, "kind", .{ .string = @tagName(st.kind) }) catch return run.oom(pos);
    out.map.put(a, "modified", .{ .int = modifiedSeconds(st.mtime) }) catch return run.oom(pos);
    out.kind = .map;
    return .{ .table = out };
}

fn exists(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .exists, args[0], true);
    try countRead(run, pos);
    return .{ .boolean = store.has(run.io, run.alloc, p.full) catch |e| return storeFailed(run, pos, .exists, p.rel, e) };
}

fn isDir(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .is_dir, args[0], false);
    try countRead(run, pos);
    const st = store.statOrNull(run.io, run.alloc, p.full) catch |e| return storeFailed(run, pos, .is_dir, p.rel, e);
    return .{ .boolean = if (st) |x| x.kind == .directory else false };
}

/// **`read(p)`**: the whole file. The read budget's rest is the read's
/// limit (README, "Budgets").
fn read(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .read, args[0], false);
    try countRead(run, pos);
    const left = run.budgets.read_bytes -| run.read_bytes;
    const bytes = store.read(run.io, run.alloc, p.full, .limited(@intCast(@min(left, std.math.maxInt(usize))))) catch |e| switch (e) {
        error.StreamTooLong => return run.budgetStop(pos, .read_bytes),
        else => return storeFailed(run, pos, .read, p.rel, e),
    };
    run.read_bytes += bytes.len;
    try run.charge(pos, bytes.len);
    return .{ .string = bytes };
}

/// What a folder holds, its names sorted, charged as `ls` is: an entry a
/// step and the sort's bound. The read is the caller's to count.
fn sortedEntries(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error![]store.Entry {
    const entries = store.list(run.io, run.alloc, full) catch |e| return storeFailed(run, pos, b, rel, e);
    var name_bytes: u64 = 0;
    for (entries) |en| name_bytes += en.name.len;
    try run.charge(pos, entries.len + bi.sortBound(entries.len, name_bytes));
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
fn walk(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .walk, args[0], true);
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
        // **THE LISTING'S KIND, NEVER A STAT'S**: a stat follows a link, so
        // a symlink inside the root to `/` would walk the host's files, and
        // a link loop would recurse. The listing names a link `other`; it
        // is reported, not stat'ed, and never entered. (Metal's FAT has no
        // links, so both hosts walk the same tree.)
        const m = try run.newTable(pos);
        m.map.put(a, "path", .{ .string = rel }) catch return run.oom(pos);
        m.map.put(a, "kind", .{ .string = @tagName(en.kind) }) catch return run.oom(pos);
        if (en.kind == .other) {
            m.map.put(a, "size", .{ .int = 0 }) catch return run.oom(pos);
            m.map.put(a, "modified", .{ .int = 0 }) catch return run.oom(pos);
        } else {
            const es = store.stat(run.io, a, full) catch |e| return storeFailed(run, pos, .walk, rel, e);
            m.map.put(a, "size", .{ .int = if (en.kind == .directory) 0 else @intCast(es.size) }) catch return run.oom(pos);
            m.map.put(a, "modified", .{ .int = modifiedSeconds(es.mtime) }) catch return run.oom(pos);
        }
        m.kind = .map;
        out.list.append(a, .{ .table = m }) catch return run.oom(pos);
        if (en.kind == .directory) {
            try countRead(run, pos);
            const entries = try sortedEntries(run, pos, .walk, full, rel);
            levels.append(a, .{ .rel = rel, .entries = entries }) catch return run.oom(pos);
        }
    }
    return .{ .table = out };
}

// ── changing ─────────────────────────────────────────────────────────────

const Change = enum { replace, append, mkdir, remove, remove_tree };

/// A change's builtin, one for each kind.
fn change(comptime c: Change) bi.Impl {
    return struct {
        fn f(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
            return storeChange(run, pos, c, args);
        }
    }.f;
}

/// **A CHANGE**: counted against the change budgets, made, and logged with
/// its outcome, whatever it is.
fn storeChange(run: *Run, pos: ast.Pos, c: Change, args: []const Value) Error!Value {
    const b: B = switch (c) {
        inline else => |t| @field(B, @tagName(t)),
    };
    const p = try pathArg(run, pos, b, args[0], false);
    const data: []const u8 = switch (c) {
        .replace, .append => try bi.stringArg(run, pos, b, args[1], "what it writes"),
        else => "",
    };
    if (run.changes >= run.budgets.changes) return run.budgetStop(pos, .changes);
    if (data.len > run.budgets.change_bytes -| run.change_bytes) return run.budgetStop(pos, .change_bytes);
    run.changes += 1;
    run.change_bytes += data.len;
    try run.charge(pos, data.len);
    const io = run.io;
    const a = run.alloc;
    // **ITS LOG ENTRY'S ROOM FIRST**: a change made and then not logged
    // (the arena full) would be on the disk but missing from `effects`,
    // which is how a host knows to rebuild what it remembers.
    run.effects.ensureUnusedCapacity(a, 1) catch return run.oom(pos);
    // The store takes removing what is not there as done; a script's
    // removal of a missing path is an error, logged (README, "The store").
    const missing: bool = switch (c) {
        .remove, .remove_tree => (store.statOrNull(io, a, p.full) catch null) == null,
        else => false,
    };
    const outcome: ?anyerror = if (missing) error.FileNotFound else switch (c) {
        .replace => if (store.replace(io, a, p.full, data, .{})) |_| null else |e| e,
        .append => if (store.append(io, a, p.full, data)) |_| null else |e| e,
        .mkdir => if (store.makeDir(io, a, p.full)) |_| null else |e| e,
        .remove => if (store.remove(io, a, p.full)) |_| null else |e| e,
        .remove_tree => if (store.removeTree(io, a, p.full)) |_| null else |e| e,
    };
    // **EVERY CHANGE ATTEMPTED IS LOGGED**, its outcome with it: a failed
    // one is also why the run stopped.
    run.effects.appendAssumeCapacity(.{ .op = @tagName(b), .path = p.rel, .outcome = if (outcome) |e| @errorName(e) else "ok" });
    if (outcome) |e| return storeFailed(run, pos, b, p.rel, e);
    return .nil;
}
