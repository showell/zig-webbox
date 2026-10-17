//! **THE STORE'S BUILTINS: READING FILES** (split from builtins_store.zig,
//! metal-vmm QUEUE 232): a file whole or in parts, its lines, a literal in
//! it, and the scans that count and find without holding it.

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

const Path = hub.Path;
const pathArg = hub.pathArg;
const storeFailed = hub.storeFailed;
const countRead = hub.countRead;

pub const specs = [_]bi.Spec{
    spec(.read, 1, 3, readFile),
    spec(.read_or, 2, 2, readOr),
    spec(.read_lines, 1, 3, readLines),
    spec(.line_at, 2, 2, lineAt),
    spec(.grep, 2, 2, grepFile),
    spec(.count_lines, 1, 3, countLines),
    spec(.count_in, 2, 4, scanner(.count)),
    spec(.find_in, 2, 4, scanner(.find)),
};

/// **`read(p)`**: the whole file. **`read(p, offset[, n])`**: from byte
/// `offset` (0-based, as the site's own sidecars count), `n` bytes or to
/// the end, fewer where the file ends; "" from its end or past it. Only
/// the bytes asked for are read and counted: a part of a file a
/// hundred megabytes long costs what the part does. The read budget's rest
/// is the read's limit (docs/SHALE.md, "The budgets").
fn readFile(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
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
pub fn fileSize(run: *Run, pos: ast.Pos, b: B, p: Path) Error!u64 {
    const st = (store.statOrNull(run.io, run.alloc, p.full) catch |e| return storeFailed(run, pos, b, p.rel, e)) orelse return storeFailed(run, pos, b, p.rel, error.FileNotFound);
    if (st.kind != .file) return storeFailed(run, pos, b, p.rel, error.IsDir);
    return st.size;
}

fn readPart(run: *Run, pos: ast.Pos, p: Path, offset: u64, n: ?u64) Error!Value {
    try countRead(run, pos);
    return readSized(run, pos, .read, p, try fileSize(run, pos, .read, p), offset, n);
}

/// **`read_or(p, default)`** (QUEUE 220): the whole file, or `default`
/// when nothing is at `p`: one store read, where `exists` then `read` was
/// two. Anything else (a folder, a failure) is the store's error, as
/// `read`'s; the bytes are a read's, under its cap and its budget.
fn readOr(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const p = try pathArg(run, pos, .read_or, args[0], false);
    try countRead(run, pos);
    const st = (store.statOrNull(run.io, run.alloc, p.full) catch |e| return storeFailed(run, pos, .read_or, p.rel, e)) orelse return args[1];
    if (st.kind != .file) return storeFailed(run, pos, .read_or, p.rel, error.IsDir);
    return readSized(run, pos, .read_or, p, st.size, 0, null);
}

/// A read of a file whose size is known, from `offset`, `n` bytes or to
/// its end.
pub fn readSized(run: *Run, pos: ast.Pos, b: B, p: Path, size: u64, offset: u64, n: ?u64) Error!Value {
    if (offset >= size) return .{ .string = "" };
    const want = @min(n orelse size - offset, size - offset);
    if (want > run.budgets.call_bytes) return run.fail(pos, .argument, "`{s}` brings at most {d} bytes in one call, and this would be {d}: read it in parts, `read(p, offset, n)`", .{ @tagName(b), run.budgets.call_bytes, want });
    if (want > run.budgets.read_bytes -| run.read_bytes) return run.budgetStop(pos, .read_bytes);
    const buf = run.alloc.alloc(u8, @intCast(want)) catch return run.oom(pos);
    const got = store.readAt(run.io, run.alloc, p.full, offset, buf) catch |e| return storeFailed(run, pos, b, p.rel, e);
    run.tally(got);
    run.read_bytes += got;
    try bi.chargeBytes(run, pos, got);
    return .{ .string = buf[0..got] };
}

// ── lines of a file, a part at a time (QUEUE 229, chunk 3) ──────────────

/// What `read_lines` brings when it is not told: 64 KiB, or the cap.
const read_lines_part: u64 = 64 * 1024;

/// How much `read_lines` and `line_at` read at a time past where they
/// were asked, to find a line's end or start.
const line_piece: u64 = 512;

/// **`read_lines(p[, offset[, n]])`**: the whole lines from byte `offset`
/// (0-based; 0 unset), as `lines` splits them: at least `n` bytes (64 KiB
/// unset), and on to the end of the line it stops in, so no line is cut.
/// `{lines, next, done}`: `next` is where the next part starts, `done`
/// whether that is the file's end. One store read for the call; the bytes
/// a read's, the whole part at most the call-bytes cap. `offset` is a line's
/// start, as a `next` is: one inside a line gives the line's rest.
fn readLines(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const b: B = .read_lines;
    const p = try pathArg(run, pos, b, args[0], false);
    const offset: u64 = if (args.len > 1) blk: {
        const o = try bi.intArg(run, pos, b, args[1], "its offset");
        if (o < 0) return run.fail(pos, .argument, "`read_lines`: offset {d} is before the file's start", .{o});
        break :blk @intCast(o);
    } else 0;
    const cap = run.budgets.call_bytes;
    const n: u64 = if (args.len > 2) blk: {
        const x = try bi.intArg(run, pos, b, args[2], "its count of bytes");
        if (x < 1) return run.fail(pos, .argument, "`read_lines`: a part of {d} bytes: it brings at least 1", .{x});
        break :blk @intCast(x);
    } else @min(read_lines_part, cap);
    if (n > cap) return run.fail(pos, .argument, "`read_lines` brings at most {d} bytes in one call, and this asks {d}: a smaller part, and `next` to go on", .{ cap, n });
    try countRead(run, pos);
    const size = try fileSize(run, pos, b, p);
    const start = @min(offset, size);
    const a = run.alloc;
    var got: std.ArrayList(u8) = .empty;
    got.appendSlice(a, (try readSized(run, pos, b, p, size, start, n)).string) catch return run.oom(pos);
    var end = start + got.items.len;
    // **NO LINE CUT**: on, a piece at a time, to the end of the last one.
    if (end < size and got.items[got.items.len - 1] != '\n') while (true) {
        if (end - start >= cap) return lineTooLong(run, pos, b, start, cap);
        const piece = (try readSized(run, pos, b, p, size, end, @min(line_piece, cap - (end - start)))).string;
        if (piece.len == 0) break;
        if (std.mem.indexOfScalar(u8, piece, '\n')) |i| {
            got.appendSlice(a, piece[0 .. i + 1]) catch return run.oom(pos);
            end += i + 1;
            break;
        }
        got.appendSlice(a, piece) catch return run.oom(pos);
        end += piece.len;
        if (end == size) break;
    };
    const out = try run.newTable(pos);
    const list = try run.newTable(pos);
    list.kind = .list;
    try run.charge(pos, got.items.len);
    var rest: []const u8 = got.items;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        list.list.append(a, .{ .string = line }) catch return run.oom(pos);
        run.tally(line.len + 1);
        rest = if (nl) |i| rest[i + 1 ..] else "";
    }
    out.kind = .map;
    out.map.put(a, "lines", .{ .table = list }) catch return run.oom(pos);
    out.map.put(a, "next", .{ .int = @intCast(end) }) catch return run.oom(pos);
    out.map.put(a, "done", .{ .boolean = end >= size }) catch return run.oom(pos);
    return .{ .table = out };
}

/// **`grep(p, s)`** (QUEUE 229, chunk 4): the lines of the file that hold
/// `s`, a literal, as `{line, text}`, `line` 1-based, in order, a line once
/// however often it holds it. The file is read whole, at most the
/// call-bytes cap (1 MiB: every source file): a bigger one goes through
/// `read_lines` and `contains` a part at a time. Its bytes a read's, a step
/// for 16; each line kept, a step a byte.
fn grepFile(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const b: B = .grep;
    const p = try pathArg(run, pos, b, args[0], false);
    const needle = try bi.stringArg(run, pos, b, args[1], "what it looks for");
    if (needle.len == 0) return run.fail(pos, .argument, "`grep` of \"\" is an error: there is nothing to look for", .{});
    try countRead(run, pos);
    const size = try fileSize(run, pos, b, p);
    if (size > run.budgets.call_bytes) return run.fail(pos, .argument, "`grep` reads a file whole, at most {d} bytes in one call, and {s} is {d}: `read_lines` and `contains` go through it a part at a time", .{ run.budgets.call_bytes, p.rel, size });
    const whole = (try readSized(run, pos, b, p, size, 0, null)).string;
    const a = run.alloc;
    const finder = try text.Finder.init(run, pos, needle);
    const out = try run.newTable(pos);
    out.kind = .list;
    var line: u64 = 1;
    var counted: usize = 0;
    var from: usize = 0;
    while (try finder.find(whole, from)) |i| {
        const start = if (std.mem.lastIndexOfScalar(u8, whole[0..i], '\n')) |nl| nl + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, whole, i, '\n') orelse whole.len;
        line += std.mem.count(u8, whole[counted..start], "\n");
        run.tally(start - counted);
        counted = start;
        try run.charge(pos, end - start);
        const m = try run.newTable(pos);
        m.kind = .map;
        m.map.put(a, "line", .{ .int = @intCast(line) }) catch return run.oom(pos);
        m.map.put(a, "text", .{ .string = whole[start..end] }) catch return run.oom(pos);
        out.list.append(a, .{ .table = m }) catch return run.oom(pos);
        from = end + 1;
        if (from > whole.len) break;
    }
    return .{ .table = out };
}

fn lineTooLong(run: *Run, pos: ast.Pos, b: B, at: u64, cap: u64) Error {
    return run.fail(pos, .argument, "`{s}`: the line at offset {d} runs past {d} bytes, the most one call brings", .{ @tagName(b), at, cap });
}

/// **`line_at(p, offset)`**: the whole line holding byte `offset`, without
/// its newline (a newline is its line's last byte), or nil at the file's end
/// or past it. Read back and on from `offset` a piece at a time; the line
/// at most the call-bytes cap. One store read for the call.
fn lineAt(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const b: B = .line_at;
    const p = try pathArg(run, pos, b, args[0], false);
    const o = try bi.intArg(run, pos, b, args[1], "its offset");
    if (o < 0) return run.fail(pos, .argument, "`line_at`: offset {d} is before the file's start", .{o});
    const offset: u64 = @intCast(o);
    try countRead(run, pos);
    const size = try fileSize(run, pos, b, p);
    if (offset >= size) return .nil;
    const cap = run.budgets.call_bytes;
    const piece_most = @min(line_piece, cap);
    // Back to the line's start: just past the newline before `offset`.
    var lo = offset;
    while (lo > 0) {
        const take = @min(lo, piece_most);
        const piece = (try readSized(run, pos, b, p, size, lo - take, take)).string;
        if (std.mem.lastIndexOfScalar(u8, piece, '\n')) |i| {
            lo = lo - take + i + 1;
            break;
        }
        lo -= take;
        if (offset - lo >= cap) return lineTooLong(run, pos, b, offset, cap);
    }
    // On to its end: its newline, or the file's end.
    var hi = offset;
    while (hi < size) {
        const piece = (try readSized(run, pos, b, p, size, hi, @min(piece_most, size - hi))).string;
        if (std.mem.indexOfScalar(u8, piece, '\n')) |i| {
            hi += i;
            break;
        }
        hi += piece.len;
        if (hi - lo > cap) return lineTooLong(run, pos, b, offset, cap);
    }
    if (hi - lo > cap) return lineTooLong(run, pos, b, offset, cap);
    return readSized(run, pos, b, p, size, lo, hi - lo);
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
