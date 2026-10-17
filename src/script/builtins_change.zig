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
const overlay = @import("overlay.zig");
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
    spec(.edit, 2, 4, editFile),
};

/// One edit: `old` replaced by `new`, as `edit`'s arguments or one entry of
/// its list form ask.
const Edit = struct {
    old: []const u8,
    new: []const u8,
    /// Every occurrence, where one alone is required unset.
    all: bool = false,
    /// Only where `old` is a whole word: no letter, digit or `_` on either
    /// side, as a symbol's rename wants.
    word: bool = false,
};

/// The most edits one call of the list form makes (the design's cap):
/// each is a pass over the file.
const edits_most = 64;

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn boolOption(run: *Run, pos: ast.Pos, k: []const u8, x: Value) Error!bool {
    return switch (x) {
        .boolean => |v| v,
        else => run.fail(pos, .type, "`edit`: its `{s}` must be true or false, not {s}", .{ k, x.typeName() }),
    };
}

/// The edits `edit` was given: `(p, old, new[, {all, word}])`, one; or
/// `(p, {{old = ..., new = ...[, all][, word]}, ...})`, its list form
/// (metal-vmm QUEUE 232).
fn editsArg(run: *Run, pos: ast.Pos, args: []const Value) Error![]Edit {
    const b: B = .edit;
    const a = run.alloc;
    if (args.len == 2) {
        const l = switch (args[1]) {
            .table => |t| if (t.kind == .map) return run.fail(pos, .type, "`edit`'s second argument is a list of edits, `{{{{old = ..., new = ...}}, ...}}`, not a map", .{}) else t,
            else => return run.fail(pos, .type, "`edit` of two arguments takes a list of edits, `{{{{old = ..., new = ...}}, ...}}`, not {s}: or `edit(p, old, new)`", .{args[1].typeName()}),
        };
        if (l.kind == .empty or l.list.items.len == 0) return run.fail(pos, .argument, "`edit` of no edits: the list is empty", .{});
        if (l.list.items.len > edits_most) return run.fail(pos, .argument, "`edit` takes at most {d} edits a call, given {d}: call it again for the rest", .{ edits_most, l.list.items.len });
        const edits = a.alloc(Edit, l.list.items.len) catch return run.oom(pos);
        for (l.list.items, edits, 1..) |v, *e, n| {
            const m = switch (v) {
                .table => |t| if (t.kind == .map) t else null,
                else => null,
            } orelse return run.fail(pos, .type, "`edit`: edit {d} must be a map, `{{old = ..., new = ...}}`, not {s}", .{ n, v.typeName() });
            var got: Edit = .{ .old = "", .new = "" };
            var has_old = false;
            var has_new = false;
            for (m.map.keys(), m.map.values()) |k, x| {
                if (std.mem.eql(u8, k, "old")) {
                    got.old = try bi.stringArg(run, pos, b, x, "an edit's `old`");
                    has_old = true;
                } else if (std.mem.eql(u8, k, "new")) {
                    got.new = try bi.stringArg(run, pos, b, x, "an edit's `new`");
                    has_new = true;
                } else if (std.mem.eql(u8, k, "all")) {
                    got.all = try boolOption(run, pos, k, x);
                } else if (std.mem.eql(u8, k, "word")) {
                    got.word = try boolOption(run, pos, k, x);
                } else return run.fail(pos, .argument, "`edit`: edit {d} takes `old`, `new`, `all` and `word`, not `{s}`", .{ n, k });
            }
            if (!has_old or !has_new) return run.fail(pos, .argument, "`edit`: edit {d} has no `{s}`", .{ n, if (has_old) "new" else "old" });
            e.* = got;
        }
        return edits;
    }
    if (args.len < 3) return run.fail(pos, .argument, "`edit` takes `(p, old, new[, opts])` or `(p, {{edits}})`", .{});
    var e: Edit = .{
        .old = try bi.stringArg(run, pos, b, args[1], "what it replaces"),
        .new = try bi.stringArg(run, pos, b, args[2], "what it writes"),
    };
    if (args.len > 3) {
        const m = try bi.mapArg(run, pos, b, args[3]);
        for (m.map.keys(), m.map.values()) |k, x| {
            const on = try boolOption(run, pos, k, x);
            if (std.mem.eql(u8, k, "all")) e.all = on else if (std.mem.eql(u8, k, "word")) e.word = on else return run.fail(pos, .argument, "`edit` takes `all` and `word`, not `{s}`", .{k});
        }
    }
    const one = a.alloc(Edit, 1) catch return run.oom(pos);
    one[0] = e;
    return one;
}

/// **WHAT THE EDITS CHANGED, AS SPANS** of the file as it was and as it is
/// now: `was[o0..o1]` became `now[c0..c1]`; outside every span the two are
/// the same bytes. In order and apart, so the diff is the file as it was
/// against the file as the last edit left it, however the edits met.
pub const Span = struct { o0: usize, o1: usize, c0: usize, c1: usize };

/// `now[i..i + len]` replaced by `n` bytes: the spans it meets (or touches)
/// become one, which spans the old text they and the bytes between them
/// stood for; the spans after it move by the change in length.
fn replaced(run: *Run, pos: ast.Pos, spans: *std.ArrayList(Span), i: usize, len: usize, n: usize) Error!void {
    const end = i + len;
    // The spans wholly before; the first one met.
    var first: usize = 0;
    var shift: i64 = 0;
    while (first < spans.items.len and spans.items[first].c1 < i) : (first += 1) {
        const s = spans.items[first];
        shift += @as(i64, @intCast(s.c1 - s.c0)) - @as(i64, @intCast(s.o1 - s.o0));
    }
    var last = first;
    var inner: i64 = 0;
    while (last < spans.items.len and spans.items[last].c0 <= end) : (last += 1) {
        const s = spans.items[last];
        inner += @as(i64, @intCast(s.c1 - s.c0)) - @as(i64, @intCast(s.o1 - s.o0));
    }
    const met = spans.items[first..last];
    const c0 = if (met.len > 0) @min(i, met[0].c0) else i;
    const c1 = if (met.len > 0) @max(end, met[met.len - 1].c1) else end;
    const o0: usize = if (met.len > 0 and met[0].c0 <= i) met[0].o0 else @intCast(@as(i64, @intCast(i)) - shift);
    const o1: usize = if (met.len > 0 and met[met.len - 1].c1 >= end) met[met.len - 1].o1 else @intCast(@as(i64, @intCast(end)) - shift - inner);
    const grown: i64 = @as(i64, @intCast(n)) - @as(i64, @intCast(len));
    const merged: Span = .{ .o0 = o0, .o1 = o1, .c0 = c0, .c1 = @intCast(@as(i64, @intCast(c1)) + grown) };
    spans.replaceRange(run.alloc, first, met.len, &.{merged}) catch return run.oom(pos);
    for (spans.items[first + 1 ..]) |*s| {
        s.c0 = @intCast(@as(i64, @intCast(s.c0)) + grown);
        s.c1 = @intCast(@as(i64, @intCast(s.c1)) + grown);
    }
}

/// **`edit(p, old, new[, {all, word}])`**: the file with `old` replaced by
/// `new`, **its diff printed first**, as a unified diff's hunks of the
/// lines it changes. `old` must be in the file exactly once, unless
/// `all`; `word` takes only whole words. **`edit(p, {{old = ..., new =
/// ...}, ...})`** (QUEUE 232): the edits in sequence, each to the file as
/// the one before left it and held to the same rules, one diff and one
/// write; an edit that fails stops the run before anything is printed or
/// written. The change is `replace`'s, logged as `edit`: in a dry run (the
/// Linux tool without `--write`) the diff is all it does. The file is read
/// whole: at most the call-bytes cap. The number of occurrences replaced.
fn editFile(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const b: B = .edit;
    const p = try pathArg(run, pos, b, args[0], false);
    const edits = try editsArg(run, pos, args);
    try countRead(run, pos);
    const size = try fileSize(run, pos, b, p);
    const was = (try readSized(run, pos, b, p, size, 0, null)).string;
    const a = run.alloc;
    var spans: std.ArrayList(Span) = .empty;
    var now: []const u8 = was;
    var replaced_n: usize = 0;
    for (edits, 1..) |e, n| {
        const which = if (edits.len > 1) std.fmt.allocPrint(a, " (edit {d} of {d}; none is made)", .{ n, edits.len }) catch return run.oom(pos) else "";
        if (e.old.len == 0) return run.fail(pos, .argument, "`edit` of \"\" is an error: there is nothing to replace{s}", .{which});
        // Where `old` is, none overlapping.
        var at: std.ArrayList(usize) = .empty;
        // The search is bulk work over the file: a step for 16 bytes, as a scan.
        try bi.chargeBytes(run, pos, now.len);
        run.tally(now.len);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, now, from, e.old)) |i| {
            from = i + e.old.len;
            if (e.word and ((i > 0 and wordByte(now[i - 1])) or (from < now.len and wordByte(now[from])))) {
                from = i + 1;
                continue;
            }
            at.append(a, i) catch return run.oom(pos);
        }
        const shown = e.old[0..@min(e.old.len, 40)];
        if (at.items.len == 0) return run.fail(pos, .argument, "`edit`: \"{s}\" is not in {s}{s}{s}", .{ shown, p.rel, if (e.word) " as a whole word" else "", which });
        if (at.items.len > 1 and !e.all) return run.fail(pos, .argument, "`edit`: \"{s}\" is in {s} {d} times: a longer `old` picks one, or `{{all = true}}` changes every one{s}", .{ shown, p.rel, at.items.len, which });
        // The file after this edit, and the spans, from the last
        // occurrence back so each one's place is the text's as it was.
        var next: std.ArrayList(u8) = .empty;
        var last: usize = 0;
        for (at.items) |i| {
            next.appendSlice(a, now[last..i]) catch return run.oom(pos);
            next.appendSlice(a, e.new) catch return run.oom(pos);
            last = i + e.old.len;
        }
        next.appendSlice(a, now[last..]) catch return run.oom(pos);
        try bi.chargeBytes(run, pos, next.items.len);
        var k = at.items.len;
        while (k > 0) {
            k -= 1;
            try replaced(run, pos, &spans, at.items[k], e.old.len, e.new.len);
        }
        now = next.items;
        replaced_n += at.items.len;
    }
    // `rewrite`'s two lines, here again: so `rewrite` is unreferenced on
    // metal, and metal's image does not move (80 bytes, measured).
    try writeDiff(run, pos, p.rel, was, now, spans.items);
    _ = try changeAt(run, pos, b, .replace, p, now);
    return .{ .int = @intCast(replaced_n) };
}

/// **A FILE REWRITTEN BY SPANS** (metal-vmm QUEUE 234, 3): `was` became
/// `now`, `spans` saying where. Its diff (by the run's `diffs` setting),
/// then the change, logged as an `edit`: a dry run's, its overlay's and
/// its budgets' as every change is: `edit`'s own tail, for the Linux
/// host's `zig_rename`.
pub fn rewrite(run: *Run, pos: ast.Pos, p: Path, was: []const u8, now: []const u8, spans: []const Span) Error!void {
    try writeDiff(run, pos, p.rel, was, now, spans);
    _ = try changeAt(run, pos, .edit, .replace, p, now);
}

/// Whether this host prints a diff as one line (`Diffs.summary`): metal's
/// `host_io` does not say so, and its image compiles none of it.
const summary_on = @hasDecl(@import("host_io"), "shale_diff_summary") and @import("host_io").shale_diff_summary;

/// **THE DIFF**, unified: `--- a/p`, `+++ b/p`, then a hunk for each run of
/// lines a span touches (spans on lines that meet share one), its old lines
/// `-` and its new ones `+`, numbered as the files have them. **In
/// `summary`** (metal-vmm QUEUE 234) the same walk, charged the same, and
/// one line for all of it: `edit p: N hunks, -O +N lines`.
fn writeDiff(run: *Run, pos: ast.Pos, rel: []const u8, was: []const u8, now: []const u8, spans: []const Span) Error!void {
    const a = run.alloc;
    const summary = summary_on and run.diffs == .summary;
    var hunks: usize = 0;
    var lines_old: i64 = 0;
    var lines_new: i64 = 0;
    if (!summary) try run.write(pos, std.fmt.allocPrint(a, "--- a/{s}\n+++ b/{s}\n", .{ rel, rel }) catch return run.oom(pos));
    var k: usize = 0;
    // How many more lines the new file has than the old, before this hunk.
    var shift: i64 = 0;
    // The line `counted` starts, counted once across the hunks.
    var line: i64 = 1;
    var counted: usize = 0;
    while (k < spans.len) {
        // The hunk: from the line the first span starts in to the end of
        // the line the last one that meets it ends in, in both files (the
        // bytes around a span are the same in each).
        const s = spans[k];
        const start = if (std.mem.lastIndexOfScalar(u8, was[0..s.o0], '\n')) |i| i + 1 else 0;
        const now_start = s.c0 - (s.o0 - start);
        var end = hunkEnd(was, now, s);
        var now_end = (s.c1 + end) - s.o1;
        var j = k + 1;
        while (j < spans.len and spans[j].o0 <= end) : (j += 1) {
            end = hunkEnd(was, now, spans[j]);
            now_end = (spans[j].c1 + end) - spans[j].o1;
        }
        const before_text = was[start..end];
        const after_text = now[now_start..now_end];
        line += @intCast(std.mem.count(u8, was[counted..start], "\n"));
        try bi.chargeBytes(run, pos, start - counted);
        counted = start;
        const n_old: i64 = @intCast(std.mem.count(u8, before_text, "\n") + 1);
        const n_new: i64 = @intCast(std.mem.count(u8, after_text, "\n") + 1);
        try run.charge(pos, before_text.len + after_text.len);
        if (summary) {
            hunks += 1;
            lines_old += n_old;
            lines_new += n_new;
        } else {
            try run.write(pos, std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@\n", .{ line, n_old, line + shift, n_new }) catch return run.oom(pos));
            try writeLines(run, pos, "-", before_text);
            try writeLines(run, pos, "+", after_text);
        }
        shift += n_new - n_old;
        k = j;
    }
    if (summary) try run.write(pos, std.fmt.allocPrint(a, "edit {s}: {d} hunk{s}, -{d} +{d} lines\n", .{ rel, hunks, if (hunks == 1) "" else "s", lines_old, lines_new }) catch return run.oom(pos));
}

/// Where a span's hunk ends in the old file: the newline that ends the
/// line its end is in; or, when its old and new text both end with a
/// newline, that newline, so the untouched line after it stays out of the
/// hunk.
fn hunkEnd(was: []const u8, now: []const u8, s: Span) usize {
    if (s.o1 > s.o0 and was[s.o1 - 1] == '\n' and s.c1 > s.c0 and now[s.c1 - 1] == '\n') return s.o1 - 1;
    return lineEnd(was, s.o1);
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
        .remove, .remove_tree => if (hub.viewStatOrNull(run, p.full)) |st| (if (st == null) error.FileNotFound else null) else |e| e,
        else => null,
    };
    // **A DRY RUN**: checked and counted as made, logged, not made. What it
    // cannot know without making it (a folder missing for a `replace`, the
    // disk full) it does not say.
    if (looked == null and run.dry_run) {
        run.effects.appendAssumeCapacity(.{ .op = @tagName(b), .path = p.rel, .outcome = "dry run" });
        // **AND HELD**, so the reads after it see it (metal-vmm QUEUE 234).
        if (comptime overlay.on) overlay.record(&run.overlay, a, switch (c) {
            inline else => |t| @field(overlay.Change, @tagName(t)),
        }, p.full, data) catch return run.oom(pos);
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
