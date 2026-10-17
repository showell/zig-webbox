//! **THE STORE'S BUILTINS: THE WALK** (split from builtins_store.zig,
//! metal-vmm QUEUE 232): every entry under a folder, a part at a time,
//! resumed where the last part ended.

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
const modifiedSeconds = hub.modifiedSeconds;
const Path = hub.Path;
const pathArg = hub.pathArg;
const storeFailed = hub.storeFailed;
const countRead = hub.countRead;

pub const specs = [_]bi.Spec{
    spec(.walk, 1, 2, walk),
};

/// What a folder holds, its names sorted, charged as `ls` is: an entry a
/// step and the sort's bound. The read is the caller's to count.
pub fn sortedEntries(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error![]store.Entry {
    const entries = try hub.viewList(run, pos, b, full, rel);
    return sortEntries(run, pos, entries);
}

/// `sortedEntries`, or null for a folder gone in a background run, which
/// reads while others write.
fn sortedEntriesOrGone(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error!?[]store.Entry {
    const entries = switch (try hub.viewListOrError(run, pos, b, full, rel)) {
        .entries => |en| en,
        .failed => |e| {
            if (run.read_only and e == error.FileNotFound) return null;
            return storeFailed(run, pos, b, rel, e);
        },
    };
    return try sortEntries(run, pos, entries);
}

fn sortEntries(run: *Run, pos: ast.Pos, entries: []store.Entry) Error![]store.Entry {
    var name_bytes: u64 = 0;
    for (entries) |en| name_bytes += en.name.len;
    try run.charge(pos, entries.len + bi.sortBound(entries.len, name_bytes));
    var ctx: bi.SortContext = .{};
    std.sort.pdq(store.Entry, entries, &ctx, struct {
        fn lt(c: *bi.SortContext, x: store.Entry, y: store.Entry) bool {
            c.comparisons += 1;
            c.bytes += @min(x.name.len, y.name.len);
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    run.tally(entries.len + ctx.comparisons + ctx.bytes);
    return entries;
}

/// A test's own moment between a folder's listing and an entry's stat
/// (an entry removed there is one gone under a background run).
pub var between_list_and_stat_for_test: ?*const fn () void = null;

/// A folder the walk is in: its entries, and the next to take.
const Level = struct { rel: []const u8, entries: []store.Entry, at: usize = 0, depth: u64 };

/// **THE WALK PUT BACK WHERE `after` LEFT IT**: each folder on `after`'s
/// path listed again, and its next entry the first name past `after`'s
/// part, so a walk in parts takes each entry once, whatever came or went
/// in between. `after` is a path the walk returned, under `p`; "" or `p`
/// itself is the start.
fn walkResume(run: *Run, pos: ast.Pos, p: Path, o: WalkOptions, after: []const u8, levels: *std.ArrayList(Level)) Error!void {
    if (after.len == 0 or std.mem.eql(u8, after, p.rel)) return;
    const rest = if (p.rel.len == 0) after else if (after.len > p.rel.len and std.mem.startsWith(u8, after, p.rel) and after[p.rel.len] == '/') after[p.rel.len + 1 ..] else return run.fail(pos, .argument, "`walk`: `after` is \"{s}\", which is not under \"{s}\": it is a path an earlier walk of it returned", .{ after, p.rel });
    var parts = std.mem.splitScalar(u8, rest, '/');
    while (parts.next()) |part| {
        const top = &levels.items[levels.items.len - 1];
        var i: usize = 0;
        while (i < top.entries.len and std.mem.lessThan(u8, top.entries[i].name, part)) i += 1;
        try run.charge(pos, i + 1);
        run.tally(i + 1);
        if (i == top.entries.len or !std.mem.eql(u8, top.entries[i].name, part)) {
            top.at = i;
            return;
        }
        top.at = i + 1;
        const en = top.entries[i];
        if (en.kind != .directory or (o.depth != null and top.depth >= o.depth.?)) return;
        const rel = if (top.rel.len == 0) en.name else std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ top.rel, en.name }) catch return run.oom(pos);
        const full = std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ run.root, rel }) catch return run.oom(pos);
        try countRead(run, pos);
        const entries = (try sortedEntriesOrGone(run, pos, .walk, full, rel)) orelse return;
        const depth = top.depth + 1;
        levels.append(run.alloc, .{ .rel = rel, .entries = entries, .depth = depth }) catch return run.oom(pos);
    }
}

/// What `walk`'s second argument asks: how deep, and which entries.
const WalkOptions = struct {
    /// 1 lists only the folder's own entries.
    depth: ?u64 = null,
    /// The entries whose names match (`like`); folders are walked into
    /// whether they match or not.
    like: ?[]const u8 = null,
    kind: ?store.Kind = null,
    /// Where an earlier call stopped: the walk goes on after this path, in
    /// its order, whether the path is still there or not.
    after: ?[]const u8 = null,
    /// Names passed by, files and folders alike, a folder never entered
    /// (`like`'s patterns): `.*` leaves out `.git`, `.zig-cache` and every
    /// other hidden name (QUEUE 229, chunk 4).
    skip: ?[]const u8 = null,
    /// **THE READS TO KEEP** (metal-vmm QUEUE 229, chunk 2): the part ends,
    /// with its `more` entry, before an entry could take the run's reads
    /// left below this, so a script that walks as far as its budget allows
    /// still has the reads to say what it found. Counts only: deterministic.
    keep_reads: ?u64 = null,
};

/// The most reads one entry of a walk takes: its stat, and its listing if
/// it is a folder walked into.
const entry_reads = 2;

fn walkOptions(run: *Run, pos: ast.Pos, v: Value) Error!WalkOptions {
    const m = try bi.mapArg(run, pos, .walk, v);
    var o: WalkOptions = .{};
    for (m.map.keys(), m.map.values()) |k, x| {
        if (std.mem.eql(u8, k, "depth")) {
            const d = try bi.intArg(run, pos, .walk, x, "its depth");
            if (d < 1) return run.fail(pos, .argument, "`walk`: a depth of {d}: 1 is the folder's own entries", .{d});
            o.depth = @intCast(d);
        } else if (std.mem.eql(u8, k, "like")) {
            o.like = try bi.stringArg(run, pos, .walk, x, "its `like`");
        } else if (std.mem.eql(u8, k, "after")) {
            o.after = try bi.stringArg(run, pos, .walk, x, "its `after`");
        } else if (std.mem.eql(u8, k, "skip")) {
            o.skip = try bi.stringArg(run, pos, .walk, x, "its `skip`");
        } else if (std.mem.eql(u8, k, "keep_reads")) {
            const n = try bi.intArg(run, pos, .walk, x, "its `keep_reads`");
            if (n < 0) return run.fail(pos, .argument, "`walk`: `keep_reads` of {d}: it is a count of reads", .{n});
            o.keep_reads = @intCast(n);
        } else if (std.mem.eql(u8, k, "kind")) {
            const s = try bi.stringArg(run, pos, .walk, x, "its `kind`");
            o.kind = std.meta.stringToEnum(store.Kind, s) orelse return run.fail(pos, .argument, "`walk`: a kind of \"{s}\": \"file\", \"directory\" or \"other\"", .{s});
        } else return run.fail(pos, .argument, "`walk` takes `depth`, `like`, `kind`, `skip`, `after` and `keep_reads`, not `{s}`", .{k});
    }
    return o;
}

/// **`walk(p[, {depth, like, kind}])`** (QUEUE 206, 208(b)): every entry
/// under `p`, depth first, each folder's names sorted and a folder before
/// what it holds, as `{path, size, kind, modified}` with `path` relative to
/// the root. **ONE READ A FOLDER LISTED**, not one an entry: what a walk
/// of the whole root costs is its folders. A folder's size is 0 (the hosts
/// disagree on it). `depth` stops it (1: the folder's own entries, which
/// is `ls` with each one's stat); `like` and `kind` keep only the entries
/// that match, and an entry left out is never stat'ed. Kept on a stack of
/// its own, not the Zig stack: a tree's depth is the store's.
fn walk(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .walk, args[0], true);
    const o: WalkOptions = if (args.len > 1) try walkOptions(run, pos, args[1]) else .{};
    const a = run.alloc;
    // **NO ROOM TO START** (`keep_reads`): the walk's own stat and listing,
    // the listings that put it back where `after` left it, and one entry,
    // past what is kept: none of it is read, and the part is its `more`
    // entry alone, where it was.
    if (o.keep_reads) |keep| {
        const head = 2 + if (o.after) |after| std.mem.count(u8, after, "/") + 1 else 0;
        if (run.budgets.reads -| run.reads < keep +| head +| entry_reads) {
            const out = try run.newTable(pos);
            out.kind = .list;
            out.list.append(a, try moreEntry(run, pos, o.after orelse "")) catch return run.oom(pos);
            return .{ .table = out };
        }
    }
    try countRead(run, pos);
    const st = (hub.viewStatOrNull(run, p.full) catch |e| return storeFailed(run, pos, .walk, p.rel, e)) orelse return storeFailed(run, pos, .walk, p.rel, error.FileNotFound);
    if (st.kind != .directory) return storeFailed(run, pos, .walk, p.rel, error.NotDir);
    var levels: std.ArrayList(Level) = .empty;
    levels.append(a, .{ .rel = p.rel, .entries = try sortedEntries(run, pos, .walk, p.full, p.rel), .depth = 1 }) catch return run.oom(pos);
    if (o.after) |after| try walkResume(run, pos, p, o, after, &levels);
    const out = try run.newTable(pos);
    out.kind = .list;
    var considered: u64 = 0;
    var last: []const u8 = "";
    while (levels.items.len > 0) {
        const top = &levels.items[levels.items.len - 1];
        if (top.at == top.entries.len) {
            _ = levels.pop();
            continue;
        }
        // **AT MOST `call_entries` A CALL** (QUEUE 211, the caps), and no
        // entry past the reads it is to keep (`keep_reads`): with more to
        // come, the list ends with where to go on from.
        const kept_back = if (o.keep_reads) |keep| run.budgets.reads -| run.reads < keep +| entry_reads else false;
        if (considered == run.budgets.call_entries or kept_back) {
            out.list.append(a, try moreEntry(run, pos, if (considered == 0) o.after orelse "" else last)) catch return run.oom(pos);
            break;
        }
        considered += 1;
        const en = top.entries[top.at];
        top.at += 1;
        if (o.skip) |pat| if (try text.likeCharged(run, pos, en.name, pat)) {
            last = if (top.rel.len == 0) en.name else std.fmt.allocPrint(a, "{s}/{s}", .{ top.rel, en.name }) catch return run.oom(pos);
            continue;
        };
        const depth = top.depth;
        const rel = if (top.rel.len == 0) en.name else std.fmt.allocPrint(a, "{s}/{s}", .{ top.rel, en.name }) catch return run.oom(pos);
        last = rel;
        try run.charge(pos, rel.len);
        run.tally(rel.len);
        const into = en.kind == .directory and (o.depth == null or depth < o.depth.?);
        const full: ?[]const u8 = if (en.kind != .other or into) std.fmt.allocPrint(a, "{s}/{s}", .{ run.root, rel }) catch return run.oom(pos) else null;
        var keep = o.kind == null or o.kind.? == en.kind;
        if (keep) if (o.like) |pat| {
            keep = try text.likeCharged(run, pos, en.name, pat);
        };
        if (keep) {
            // **THE LISTING'S KIND, NEVER A STAT'S**: a stat follows a
            // link, so a symlink inside the root to `/` would walk the
            // host's files, and a link loop would recurse. The listing
            // names a link `other`; it is reported, not stat'ed, and never
            // entered. (Metal's FAT has no links, so both hosts walk the
            // same tree.)
            // **EACH STAT A READ** (QUEUE 211, the caps): it is a store call,
            // a disk command on metal, as `stat(p)` is.
            const es: ?store.Stat = if (en.kind == .other) null else stat: {
                try countRead(run, pos);
                if (between_list_and_stat_for_test) |hook| hook();
                break :stat hub.viewStat(run, full.?) catch |e| {
                    // **A BACKGROUND RUN READS WHILE OTHERS WRITE**: an
                    // entry gone since its folder was listed is passed by.
                    if (run.read_only and e == error.FileNotFound) continue;
                    return storeFailed(run, pos, .walk, rel, e);
                };
            };
            const m = try run.newTable(pos);
            m.map.put(a, "path", .{ .string = rel }) catch return run.oom(pos);
            m.map.put(a, "kind", .{ .string = @tagName(en.kind) }) catch return run.oom(pos);
            if (es == null) {
                m.map.put(a, "size", .{ .int = 0 }) catch return run.oom(pos);
                m.map.put(a, "modified", .{ .int = 0 }) catch return run.oom(pos);
            } else {
                const st_e = es.?;
                m.map.put(a, "size", .{ .int = if (en.kind == .directory) 0 else @intCast(st_e.size) }) catch return run.oom(pos);
                m.map.put(a, "modified", .{ .int = modifiedSeconds(st_e.mtime) }) catch return run.oom(pos);
            }
            m.kind = .map;
            out.list.append(a, .{ .table = m }) catch return run.oom(pos);
        }
        if (into) {
            try countRead(run, pos);
            // A folder gone since it was listed, in a background run, too.
            const entries = (try sortedEntriesOrGone(run, pos, .walk, full.?, rel)) orelse continue;
            levels.append(a, .{ .rel = rel, .entries = entries, .depth = depth + 1 }) catch return run.oom(pos);
        }
    }
    return .{ .table = out };
}

/// A walk's last entry when there is more: `{path, kind = "more"}`, where
/// the next part goes on after.
fn moreEntry(run: *Run, pos: ast.Pos, path: []const u8) Error!Value {
    const a = run.alloc;
    const m = try run.newTable(pos);
    m.map.put(a, "path", .{ .string = path }) catch return run.oom(pos);
    m.map.put(a, "kind", .{ .string = "more" }) catch return run.oom(pos);
    m.map.put(a, "size", .{ .int = 0 }) catch return run.oom(pos);
    m.map.put(a, "modified", .{ .int = 0 }) catch return run.oom(pos);
    m.kind = .map;
    return .{ .table = m };
}

// ── an edit, with its diff (QUEUE 229, chunk 4) ─────────────────────────
