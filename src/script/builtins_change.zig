//! **THE STORE'S BUILTINS: CHANGES** (split from builtins_store.zig,
//! metal-vmm QUEUE 232): a file written, added to or removed, a folder made
//! or removed, and `edit`, a literal replaced with its diff printed; each
//! counted against the change budgets and logged.

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
const hub = @import("builtins_store.zig");
const rd = @import("builtins_read.zig");
const fileSize = rd.fileSize;
const readSized = rd.readSized;
const Path = hub.Path;
const pathArg = hub.pathArg;
const storeFailed = hub.storeFailed;
const countRead = hub.countRead;

pub const specs = [_]bi.Spec{
    spec(.replace, 2, 2, change(.replace)),
    spec(.append, 2, 2, change(.append)),
    spec(.mkdir, 1, 1, change(.mkdir)),
    spec(.remove, 1, 1, change(.remove)),
    spec(.remove_tree, 1, 1, change(.remove_tree)),
    spec(.edit, 3, 4, editFile),
};

/// What `edit`'s fourth argument asks.
const EditOptions = struct {
    /// Every occurrence, where one alone is required unset.
    all: bool = false,
    /// Only where `old` is a whole word: no letter, digit or `_` on either
    /// side, as a symbol's rename wants.
    word: bool = false,
};

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// **`edit(p, old, new[, {all, word}])`**: the file with `old` replaced by
/// `new`, **its diff printed first**, as a unified diff's hunks of the
/// lines it changes. `old` must be in the file exactly once, unless
/// `all`; `word` takes only whole words. The change is `replace`'s, logged
/// as `edit`: in a dry run (the Linux tool without `--write`) the diff is
/// all it does. The file is read whole: at most the call-bytes cap. The
/// number of occurrences replaced.
fn editFile(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const b: B = .edit;
    const p = try pathArg(run, pos, b, args[0], false);
    const old = try bi.stringArg(run, pos, b, args[1], "what it replaces");
    const new = try bi.stringArg(run, pos, b, args[2], "what it writes");
    if (old.len == 0) return run.fail(pos, .argument, "`edit` of \"\" is an error: there is nothing to replace", .{});
    var o: EditOptions = .{};
    if (args.len > 3) {
        const m = try bi.mapArg(run, pos, b, args[3]);
        for (m.map.keys(), m.map.values()) |k, x| {
            const on = switch (x) {
                .boolean => |v| v,
                else => return run.fail(pos, .type, "`edit`: its `{s}` must be true or false, not {s}", .{ k, x.typeName() }),
            };
            if (std.mem.eql(u8, k, "all")) o.all = on else if (std.mem.eql(u8, k, "word")) o.word = on else return run.fail(pos, .argument, "`edit` takes `all` and `word`, not `{s}`", .{k});
        }
    }
    try countRead(run, pos);
    const size = try fileSize(run, pos, b, p);
    const was = (try readSized(run, pos, b, p, size, 0, null)).string;
    const a = run.alloc;
    // Where `old` is, none overlapping.
    var at: std.ArrayList(usize) = .empty;
    // The search is bulk work over the file: a step for 16 bytes, as a scan.
    try bi.chargeBytes(run, pos, was.len);
    run.tally(was.len);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, was, from, old)) |i| {
        from = i + old.len;
        if (o.word and ((i > 0 and wordByte(was[i - 1])) or (from < was.len and wordByte(was[from])))) {
            from = i + 1;
            continue;
        }
        at.append(a, i) catch return run.oom(pos);
    }
    const shown = old[0..@min(old.len, 40)];
    if (at.items.len == 0) return run.fail(pos, .argument, "`edit`: \"{s}\" is not in {s}{s}", .{ shown, p.rel, if (o.word) " as a whole word" else "" });
    if (at.items.len > 1 and !o.all) return run.fail(pos, .argument, "`edit`: \"{s}\" is in {s} {d} times: a longer `old` picks one, or `{{all = true}}` changes every one", .{ shown, p.rel, at.items.len });
    // The new file.
    var now_text: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    for (at.items) |i| {
        now_text.appendSlice(a, was[last..i]) catch return run.oom(pos);
        now_text.appendSlice(a, new) catch return run.oom(pos);
        last = i + old.len;
    }
    now_text.appendSlice(a, was[last..]) catch return run.oom(pos);
    try bi.chargeBytes(run, pos, now_text.items.len);
    try writeDiff(run, pos, p.rel, was, old.len, new, at.items);
    _ = try changeAt(run, pos, b, .replace, p, now_text.items);
    return .{ .int = @intCast(at.items.len) };
}

/// **THE DIFF**, unified: `--- a/p`, `+++ b/p`, then a hunk for each run of
/// lines an occurrence touches (occurrences on lines that meet share one),
/// its old lines `-` and its new ones `+`, numbered as the files have them.
fn writeDiff(run: *Run, pos: ast.Pos, rel: []const u8, was: []const u8, old_len: usize, new: []const u8, at: []const usize) Error!void {
    const a = run.alloc;
    try run.write(pos, std.fmt.allocPrint(a, "--- a/{s}\n+++ b/{s}\n", .{ rel, rel }) catch return run.oom(pos));
    var k: usize = 0;
    // How many more lines the new file has than the old, before this hunk.
    var shift: i64 = 0;
    // The line `counted` starts, counted once across the hunks.
    var line: i64 = 1;
    var counted: usize = 0;
    while (k < at.len) {
        // The hunk: from the line the first occurrence starts in to the
        // end of the line the last one that meets it ends in.
        const start = if (std.mem.lastIndexOfScalar(u8, was[0..at[k]], '\n')) |i| i + 1 else 0;
        var end = lineEnd(was, at[k] + old_len);
        var j = k + 1;
        while (j < at.len and at[j] <= end) : (j += 1) end = lineEnd(was, at[j] + old_len);
        var after: std.ArrayList(u8) = .empty;
        var last = start;
        for (at[k..j]) |i| {
            after.appendSlice(a, was[last..i]) catch return run.oom(pos);
            after.appendSlice(a, new) catch return run.oom(pos);
            last = i + old_len;
        }
        after.appendSlice(a, was[last..end]) catch return run.oom(pos);
        const before_text = was[start..end];
        line += @intCast(std.mem.count(u8, was[counted..start], "\n"));
        try bi.chargeBytes(run, pos, start - counted);
        counted = start;
        const n_old: i64 = @intCast(std.mem.count(u8, before_text, "\n") + 1);
        const n_new: i64 = @intCast(std.mem.count(u8, after.items, "\n") + 1);
        try run.charge(pos, before_text.len + after.items.len);
        try run.write(pos, std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@\n", .{ line, n_old, line + shift, n_new }) catch return run.oom(pos));
        try writeLines(run, pos, "-", before_text);
        try writeLines(run, pos, "+", after.items);
        shift += n_new - n_old;
        k = j;
    }
}

/// The offset of the newline that ends the line `i` is in, or the end.
fn lineEnd(s: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, s, @min(i, s.len), '\n') orelse s.len;
}

fn writeLines(run: *Run, pos: ast.Pos, mark: []const u8, s: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        try run.write(pos, mark);
        try run.write(pos, l);
        try run.write(pos, "\n");
    }
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
    return changeAt(run, pos, b, c, p, data);
}

/// A change to `p` with `data`, logged under `b`'s name.
fn changeAt(run: *Run, pos: ast.Pos, b: B, c: Change, p: Path, data: []const u8) Error!Value {
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
    // removal of a missing path is an error, logged (docs/SHALE.md, "The store").
    // **ONLY WHAT ISN'T THERE IS MISSING** (209(a)): any other failure to
    // look is the store's own, named, logged, and why the run stopped.
    const looked: ?anyerror = switch (c) {
        .remove, .remove_tree => if (store.statOrNull(io, a, p.full)) |st| (if (st == null) error.FileNotFound else null) else |e| e,
        else => null,
    };
    // **A DRY RUN**: checked and counted as made, logged, not made. What it
    // cannot know without making it (a folder missing for a `replace`, the
    // disk full) it does not say.
    if (looked == null and run.dry_run) {
        run.effects.appendAssumeCapacity(.{ .op = @tagName(b), .path = p.rel, .outcome = "dry run" });
        return .nil;
    }
    const outcome: ?anyerror = if (looked) |e| e else switch (c) {
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
