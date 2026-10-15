//! **THE STORE'S BUILTINS**: what a script reads of the data root and what
//! it changes there, every path confined to the root, every read counted
//! against the read budgets and every change logged (docs/SHALE.md, "The store").
//! Only through webbox's `store`, so a script does the same on Linux and on
//! metal.

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

pub const specs = [_]bi.Spec{
    spec(.ls, 1, 1, ls),
    spec(.stat, 1, 1, stat),
    spec(.exists, 1, 1, exists),
    spec(.is_dir, 1, 1, isDir),
    spec(.read, 1, 3, read),
    spec(.count_lines, 1, 3, countLines),
    spec(.count_in, 2, 4, scanner(.count)),
    spec(.find_in, 2, 4, scanner(.find)),
    spec(.walk, 1, 2, walk),
    spec(.replace, 2, 2, change(.replace)),
    spec(.append, 2, 2, change(.append)),
    spec(.mkdir, 1, 1, change(.mkdir)),
    spec(.remove, 1, 1, change(.remove)),
    spec(.remove_tree, 1, 1, change(.remove_tree)),
};

// ── paths ────────────────────────────────────────────────────────────────

/// **A SCRIPT'S PATH, CONFINED TO THE ROOT** (docs/SHALE.md, "The store"): every part
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

/// A store error in plain words; its name follows in parentheses.
fn storeWords(e: anyerror) []const u8 {
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
fn storeHint(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => ": `exists(p)` asks first",
        error.NotDir, error.IsDir, error.NotFile => ": `is_dir(p)` asks first",
        error.PathAlreadyExists => ": `exists(p)` asks first",
        error.DirNotEmpty => ": `remove_tree(p)` removes a folder and what is in it",
        else => "",
    };
}

fn storeFailed(run: *Run, pos: ast.Pos, b: B, rel: []const u8, e: anyerror) Error {
    if (e == error.OutOfMemory) return run.oom(pos);
    return run.fail(pos, .store, "`{s}(\"{s}\")`: {s} ({s}){s}", .{ @tagName(b), rel, storeWords(e), @errorName(e), storeHint(e) });
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

/// **`read(p)`**: the whole file. **`read(p, offset[, n])`**: from byte
/// `offset` (0-based, as the site's own sidecars count), `n` bytes or to
/// the end, fewer where the file ends; "" from its end or past it. Only
/// the bytes asked for are read and counted: a part of a file a
/// hundred megabytes long costs what the part does. The read budget's rest
/// is the read's limit (docs/SHALE.md, "The budgets").
fn read(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .read, args[0], false);
    if (args.len > 1) {
        const offset = try bi.intArg(run, pos, .read, args[1], "its offset");
        if (offset < 0) return run.fail(pos, .argument, "`read`: offset {d} is before the file's start", .{offset});
        const n: ?i64 = if (args.len > 2) try bi.intArg(run, pos, .read, args[2], "its count of bytes") else null;
        if (n != null and n.? < 0) return run.fail(pos, .argument, "`read`: a count of {d} bytes", .{n.?});
        return readPart(run, pos, p, @intCast(offset), if (n) |x| @intCast(x) else null);
    }
    // The whole file is the part from 0 to its end: sized by its stat, one
    // buffer of exactly that, never grown (a buffer grown by doubling cost
    // 4x the time once each big one had a chunk of its own).
    return readPart(run, pos, p, 0, null);
}

/// A file's size, for a read of part of it: one store call, the read's.
fn fileSize(run: *Run, pos: ast.Pos, b: B, p: Path) Error!u64 {
    const st = (store.statOrNull(run.io, run.alloc, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e)) orelse return storeFailed(run, pos, b, p.rel, error.FileNotFound);
    if (st.kind != .file) return storeFailed(run, pos, b, p.rel, error.IsDir);
    return st.size;
}

fn readPart(run: *Run, pos: ast.Pos, p: Path, offset: u64, n: ?u64) Error!Value {
    try countRead(run, pos);
    const size = try fileSize(run, pos, .read, p);
    if (offset >= size) return .{ .string = "" };
    const want = @min(n orelse size - offset, size - offset);
    if (want > run.budgets.call_bytes) return run.fail(pos, .argument, "`read` brings at most {d} bytes in one call, and this would be {d}: read it in parts, `read(p, offset, n)`", .{ run.budgets.call_bytes, want });
    if (want > run.budgets.read_bytes -| run.read_bytes) return run.budgetStop(pos, .read_bytes);
    const buf = run.alloc.alloc(u8, @intCast(want)) catch return run.oom(pos);
    const got = store.readAt(run.io, run.alloc, p.full, offset, buf) catch |e| return storeFailed(run, pos, .read, p.rel, e);
    run.tally(got);
    run.read_bytes += got;
    try bi.chargeBytes(run, pos, got);
    return .{ .string = buf[0..got] };
}

// ── scanning a file without holding it ───────────────────────────────────

/// How much of a file a scan holds at once.
const scan_chunk = 64 * 1024;

const Scan = enum { count, find };

fn scanner(comptime how: Scan) bi.Impl {
    return struct {
        fn f(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
            const b: B = if (how == .count) .count_in else .find_in;
            const p = try pathArg(run, pos, b, args[0], false);
            const needle = try bi.stringArg(run, pos, b, args[1], "what it looks for");
            if (needle.len == 0) return run.fail(pos, .argument, "`{s}` of \"\" is an error: there is nothing to look for", .{@tagName(b)});
            if (needle.len > scan_chunk) return run.fail(pos, .argument, "`{s}`: what it looks for is longer than {d} bytes", .{ @tagName(b), scan_chunk });
            const r = try scan(run, pos, b, p, needle, how == .find, try rangeArgs(run, pos, b, args[2..]));
            return switch (how) {
                .count => .{ .int = @intCast(r.count) },
                .find => if (r.first) |at| .{ .int = @intCast(at) } else .nil,
            };
        }
    }.f;
}

/// **`count_lines(p[, offset[, n]])`**: the lines in a file, as
/// `#lines(read(p))` counts them (a last line without its newline counts
/// too), without holding the file: a megabyte at a time is at most 64 KiB
/// of arena. Of a range, the newlines in it, and the last line if the range
/// reaches the file's end: the parts' counts add up to the whole's.
fn countLines(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .count_lines, args[0], false);
    const r = try scan(run, pos, .count_lines, p, "\n", false, try rangeArgs(run, pos, .count_lines, args[1..]));
    return .{ .int = @intCast(r.count + @intFromBool(r.to_end and r.size > 0 and r.last != '\n')) };
}

/// A scan's range: from `offset`, `n` bytes, or to the end.
const Range = struct { offset: u64 = 0, n: ?u64 = null };

fn rangeArgs(run: *Run, pos: ast.Pos, b: B, args: []const Value) Error!Range {
    if (args.len == 0) return .{};
    const offset = try bi.intArg(run, pos, b, args[0], "its offset");
    if (offset < 0) return run.fail(pos, .argument, "`{s}`: offset {d} is before the file's start", .{ @tagName(b), offset });
    const n: ?i64 = if (args.len > 1) try bi.intArg(run, pos, b, args[1], "its count of bytes") else null;
    if (n != null and n.? < 0) return run.fail(pos, .argument, "`{s}`: a count of {d} bytes", .{ @tagName(b), n.? });
    return .{ .offset = @intCast(offset), .n = if (n) |x| @intCast(x) else null };
}

const Scanned = struct { count: u64 = 0, first: ?u64 = null, size: u64 = 0, last: u8 = 0, to_end: bool = false };

/// **A SCAN**: the file `scan_chunk` bytes at a time, one buffer reused,
/// counting `needle`'s occurrences (none overlapping) or stopping at the
/// first (`first_only`), across the chunks' seams. One store read for the
/// call; every byte counted against the read budget and charged a step.
///
/// **IN A RANGE, AT MOST THE CAP** (metal-vmm QUEUE 211, the caps): the
/// matches that start in `range`, which may be at most `call_bytes` long;
/// a match that starts in it is read to its end, at most the needle's
/// length less one past it. So a find over a file in parts finds what the
/// whole file's would, and a scan is a bounded slice of a run's time.
fn scan(run: *Run, pos: ast.Pos, b: B, p: Path, needle: []const u8, first_only: bool, range: Range) Error!Scanned {
    try countRead(run, pos);
    const file_size = try fileSize(run, pos, b, p);
    const start = @min(range.offset, file_size);
    const end = if (range.n) |n| start + @min(n, file_size - start) else file_size;
    if (end - start > run.budgets.call_bytes) return run.fail(pos, .argument, "`{s}` scans at most {d} bytes in one call, and this would be {d}: scan it in parts, `{s}(p, {s}offset, n)`", .{ @tagName(b), run.budgets.call_bytes, end - start, @tagName(b), if (b == .count_lines) "" else "s, " });
    const keep_most = needle.len - 1;
    // What the scan reads: the range, and a match's tail past it, never a
    // whole needle past it, so every match found starts in the range.
    const size = @min(file_size, end + keep_most);
    var r: Scanned = .{ .size = file_size, .to_end = end == file_size };
    if (end == start) return r;
    const finder = try text.Finder.init(run, pos, needle);
    // **ONE BUFFER FOR EVERY SCAN OF THE RUN** (208's cold review): a
    // fresh one a call would spend 64 KiB of arena a file, and a scan of
    // the chat's topics would run the site's 8 MiB out.
    // Sized once, for the longest needle and the fullest chunk (209's
    // review: sized by the needle, a scan with a longer one took another).
    if (run.scan_buf.len == 0) run.scan_buf = run.alloc.alloc(u8, 2 * scan_chunk) catch return run.oom(pos);
    const buf = run.scan_buf[0..@intCast(@min(size - start, scan_chunk) + keep_most)];
    // `buf[0..kept]` holds the last window's tail, from file offset `base`.
    var kept: usize = 0;
    var base: u64 = start;
    var at: u64 = start;
    while (at < size) {
        const want: usize = @intCast(@min(size - at, buf.len - kept));
        if (want > run.budgets.read_bytes -| run.read_bytes) return run.budgetStop(pos, .read_bytes);
        const got = store.readAt(run.io, run.alloc, p.full, at, buf[kept..][0..want]) catch |e| return storeFailed(run, pos, b, p.rel, e);
        run.read_bytes += got;
        try bi.chargeBytes(run, pos, got);
        run.tally(got);
        if (got == 0) break; // the file shrank under the scan
        at += got;
        const window = buf[0 .. kept + got];
        r.last = window[window.len - 1];
        var from: usize = 0;
        while (try finder.find(window, from)) |i| {
            if (r.first == null) r.first = base + i;
            r.count += 1;
            if (first_only) return r;
            from = i + needle.len;
        }
        // Keep what could still start a match: the last `keep_most` bytes,
        // none a match already took.
        const next = @max(from, window.len -| keep_most);
        kept = window.len - next;
        std.mem.copyForwards(u8, buf[0..kept], window[next..]);
        base += next;
    }
    return r;
}

/// What a folder holds, its names sorted, charged as `ls` is: an entry a
/// step and the sort's bound. The read is the caller's to count.
fn sortedEntries(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error![]store.Entry {
    const entries = store.list(run.io, run.alloc, full) catch |e| return storeFailed(run, pos, b, rel, e);
    return sortEntries(run, pos, entries);
}

/// `sortedEntries`, or null for a folder gone in a background run, which
/// reads while others write.
fn sortedEntriesOrGone(run: *Run, pos: ast.Pos, b: B, full: []const u8, rel: []const u8) Error!?[]store.Entry {
    const entries = store.list(run.io, run.alloc, full) catch |e| {
        if (run.read_only and e == error.FileNotFound) return null;
        return storeFailed(run, pos, b, rel, e);
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
};

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
        } else if (std.mem.eql(u8, k, "kind")) {
            const s = try bi.stringArg(run, pos, .walk, x, "its `kind`");
            o.kind = std.meta.stringToEnum(store.Kind, s) orelse return run.fail(pos, .argument, "`walk`: a kind of \"{s}\": \"file\", \"directory\" or \"other\"", .{s});
        } else return run.fail(pos, .argument, "`walk` takes `depth`, `like`, `kind` and `after`, not `{s}`", .{k});
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
    try countRead(run, pos);
    const st = (store.statOrNull(run.io, a, p.full) catch |e| return storeFailed(run, pos, .walk, p.rel, e)) orelse return storeFailed(run, pos, .walk, p.rel, error.FileNotFound);
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
        // **AT MOST `call_entries` A CALL** (QUEUE 211, the caps): with
        // more to come, the list ends with where to go on from.
        if (considered == run.budgets.call_entries) {
            const m = try run.newTable(pos);
            m.map.put(a, "path", .{ .string = last }) catch return run.oom(pos);
            m.map.put(a, "kind", .{ .string = "more" }) catch return run.oom(pos);
            m.map.put(a, "size", .{ .int = 0 }) catch return run.oom(pos);
            m.map.put(a, "modified", .{ .int = 0 }) catch return run.oom(pos);
            m.kind = .map;
            out.list.append(a, .{ .table = m }) catch return run.oom(pos);
            break;
        }
        considered += 1;
        const en = top.entries[top.at];
        top.at += 1;
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
                break :stat store.stat(run.io, a, full.?) catch |e| {
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
    // **A BACKGROUND RUN ONLY READS** (metal-vmm QUEUE 211, Steve's model),
    // refused before the path is looked at or anything is counted.
    if (run.read_only) return run.fail(pos, .argument, "`{s}` changes the store, and a background run only reads: send it as an `atomic` run", .{@tagName(b)});
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
    // removal of a missing path is an error, logged (docs/SHALE.md, "The store").
    // **ONLY WHAT ISN'T THERE IS MISSING** (209(a)): any other failure to
    // look is the store's own, named, logged, and why the run stopped.
    const looked: ?anyerror = switch (c) {
        .remove, .remove_tree => if (store.statOrNull(io, a, p.full)) |st| (if (st == null) error.FileNotFound else null) else |e| e,
        else => null,
    };
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
