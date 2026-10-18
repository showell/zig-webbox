//! **THE STORE'S BUILTINS**: what a script reads of the data root and what
//! it changes there, every path confined to the root, every read counted
//! against the read budgets and every change logged (docs/SHALE.md, "The store").
//! Only through webbox's `store`, so a script does the same on Linux and on
//! metal. Here: the paths, a failure's words, and `ls`, `stat`, `exists` and
//! `is_dir`; reading files is builtins_read.zig, the walk builtins_walk.zig,
//! the changes builtins_change.zig (split by concern, metal-vmm QUEUE 232),
//! and every one's `Spec` is gathered here, so `touches_store` is all of them.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");
const text = @import("builtins_text.zig");

const store = @import("../store.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;
const spec = bi.spec;
const read = @import("builtins_read.zig");
const walk = @import("builtins_walk.zig");
const change = @import("builtins_change.zig");
const sortedEntries = walk.sortedEntries;

pub const specs = [_]bi.Spec{
    spec(.ls, 1, 1, ls),
    spec(.stat, 1, 1, stat),
    spec(.exists, 1, 1, exists),
    spec(.is_dir, 1, 1, isDir),
} ++ read.specs ++ walk.specs ++ change.specs;

// ── paths ────────────────────────────────────────────────────────────────

/// **A SCRIPT'S PATH, CONFINED TO THE ROOT** (docs/SHALE.md, "The store"): every part
/// a name FAT holds (so `.`, `..` and empty parts are refused, and a
/// leading `/`), joined to the root. `""` is the root, and so is `"."`, for
/// the calls that only look (`allow_root`); every change needs at least
/// one part.
pub const Path = struct { full: []const u8, rel: []const u8 };

pub fn pathArg(run: *Run, pos: ast.Pos, b: B, v: Value, allow_root: bool) Error!Path {
    const given = try bi.stringArg(run, pos, b, v, "its path");
    const rel = if (std.mem.eql(u8, given, ".")) "" else given;
    try run.charge(pos, given.len);
    // **THE HOST'S HOOK, WHEN IT HAS ONE** (metal-vmm QUEUE 233): a path it
    // resolves (a mount's, on Linux) is its; any other, the root's rules.
    if (run.path_hook) |h| if (try h.resolve(h.ctx, run, pos, rel)) |full| return .{ .full = full, .rel = rel };
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

/// A store error in plain words; its name follows in parentheses.
pub fn storeWords(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "not found",
        error.NotDir => "a part of the path is a file, not a folder",
        error.IsDir => "a folder, not a file",
        error.NotFile => "not a file",
        error.PathAlreadyExists => "already there",
        error.DirNotEmpty => "the folder is not empty",
        error.AccessDenied, error.PermissionDenied => "the store refuses it",
        error.NoSpaceLeft => "the store is full",
        error.SymLinkLoop => "a link loop",
        error.NameTooLong => "the name is too long",
        else => "the store failed",
    };
}

/// What to do about it, when there is something.
pub fn storeHint(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => ": `exists(p)` asks first",
        error.NotDir, error.IsDir, error.NotFile => ": `is_dir(p)` asks first",
        error.PathAlreadyExists => ": `exists(p)` asks first",
        error.DirNotEmpty => ": `remove_tree(p)` removes a folder and what is in it",
        else => "",
    };
}

pub fn storeFailed(run: *Run, pos: ast.Pos, b: B, rel: []const u8, e: anyerror) Error {
    if (e == error.OutOfMemory) return run.oom(pos);
    return run.fail(pos, .store, "`{s}(\"{s}\")`: {s} ({s}){s}", .{ @tagName(b), rel, storeWords(e), @errorName(e), storeHint(e) });
}

pub fn countRead(run: *Run, pos: ast.Pos) Error!void {
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
/// folder as empty; a script's `ls` of one is an error (docs/SHALE.md, "The
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
