//! **v31's BUILTINS** (metal-vmm QUEUE 206, from 204(b)): lines and words,
//! `like`, dates, sizes and padding, a table of rows, and a sort by key.
//! Pure work on values: no store, no host but the run's budgets. Each
//! charges steps in proportion to the work it does, as every builtin does.

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const builtins = @import("builtins.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;

// ── lines and words ──────────────────────────────────────────────────────

/// **`lines(s)`**: `s` split at each `\n`, with no last empty piece after a
/// final newline (`#lines("a\nb\n")` is 2). **`words(s)`**: the runs
/// between ASCII whitespace, none empty.
pub fn splitText(run: *Run, pos: ast.Pos, b: B, arg: Value) Error!Value {
    const str = try builtins.stringArg(run, pos, b, arg, "its string");
    try run.charge(pos, str.len);
    const out = try run.newTable(pos);
    out.kind = .list;
    const a = run.alloc;
    if (b == .lines) {
        var rest = str;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const line = if (nl) |i| rest[0..i] else rest;
            out.list.append(a, .{ .string = line }) catch return run.oom(pos);
            rest = if (nl) |i| rest[i + 1 ..] else "";
        }
    } else {
        var it = std.mem.tokenizeAny(u8, str, " \t\r\n\x0b\x0c");
        while (it.next()) |w| out.list.append(a, .{ .string = w }) catch return run.oom(pos);
    }
    return .{ .table = out };
}

// ── like ─────────────────────────────────────────────────────────────────

/// **`like(s, pattern)`**: whether the whole of `s` matches `pattern`, where
/// `*` is any run of bytes (none included), `?` is one byte, and every other
/// byte is itself. No classes, no escapes: not Lua's patterns. The classic
/// walk that goes back only to the last `*`; every byte it looks at is a
/// step, so a pattern that backtracks a long string runs out of steps.
pub fn like(run: *Run, pos: ast.Pos, s_arg: Value, p_arg: Value) Error!Value {
    const s = try builtins.stringArg(run, pos, .like, s_arg, "its string");
    const p = try builtins.stringArg(run, pos, .like, p_arg, "its pattern");
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
            return .{ .boolean = false };
        }
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    try run.charge(pos, looked + p.len);
    return .{ .boolean = pi == p.len };
}

// ── dates ────────────────────────────────────────────────────────────────

/// The latest second `date` writes: 9999-12-31T23:59:59Z.
const last_second: i64 = 253402300799;

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @intFromBool(m <= 2), .m = m, .d = d };
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// **`date(seconds)`**: the UTC time `seconds` after the epoch, as
/// `YYYY-MM-DDTHH:MM:SSZ`, from 1970 to the end of 9999.
pub fn date(run: *Run, pos: ast.Pos, arg: Value) Error!Value {
    const t = try builtins.intArg(run, pos, .date, arg, "its seconds");
    if (t < 0 or t > last_second) return run.fail(pos, .argument, "`date`: {d} is outside 1970-01-01 to 9999-12-31", .{t});
    const c = civilFromDays(@divFloor(t, 86400));
    const r = @mod(t, 86400);
    try run.charge(pos, 20);
    const text = std.fmt.allocPrint(run.alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(c.y)),                @as(u64, @intCast(c.m)),                          @as(u64, @intCast(c.d)),
        @as(u64, @intCast(@divFloor(r, 3600))), @as(u64, @intCast(@divFloor(@mod(r, 3600), 60))), @as(u64, @intCast(@mod(r, 60))),
    }) catch return run.oom(pos);
    return .{ .string = text };
}

/// Digits at `s[at..][0..n]`, all of them, as a number; null otherwise.
fn digitsAt(s: []const u8, at: usize, n: usize) ?i64 {
    if (at + n > s.len) return null;
    var v: i64 = 0;
    for (s[at..][0..n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// The seconds since the epoch of an RFC 3339 time, or of a date alone (its
/// midnight UTC); null when `s` is neither, or names no real day or time.
pub fn parseTime(s: []const u8) ?i64 {
    const y = digitsAt(s, 0, 4) orelse return null;
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const m = digitsAt(s, 5, 2) orelse return null;
    const d = digitsAt(s, 8, 2) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    const day = daysFromCivil(y, m, d) * 86400;
    if (s.len == 10) return day;
    if (s.len < 20 or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const hh = digitsAt(s, 11, 2) orelse return null;
    const mm = digitsAt(s, 14, 2) orelse return null;
    const ss = digitsAt(s, 17, 2) orelse return null;
    if (hh > 23 or mm > 59 or ss > 59) return null;
    var at: usize = 19;
    // A fraction of a second, dropped: the time is whole seconds.
    if (s[at] == '.') {
        at += 1;
        const from = at;
        while (at < s.len and std.ascii.isDigit(s[at])) at += 1;
        if (at == from) return null;
    }
    if (at >= s.len) return null;
    var offset: i64 = 0;
    if (s[at] == 'Z') {
        at += 1;
    } else if (s[at] == '+' or s[at] == '-') {
        const oh = digitsAt(s, at + 1, 2) orelse return null;
        if (at + 3 >= s.len or s[at + 3] != ':') return null;
        const om = digitsAt(s, at + 4, 2) orelse return null;
        if (oh > 23 or om > 59) return null;
        offset = (oh * 60 + om) * 60;
        if (s[at] == '-') offset = -offset;
        at += 6;
    } else return null;
    if (at != s.len) return null;
    return day + hh * 3600 + mm * 60 + ss - offset;
}

/// **`seconds(text)`**: `date`'s inverse. An RFC 3339 time (`T` between the
/// date and the time, then `Z` or `±HH:MM`; a fraction of a second is
/// dropped) or a date alone, which is its midnight UTC. Anything else, a
/// day that is not in the calendar among them, is an error.
pub fn seconds(run: *Run, pos: ast.Pos, arg: Value) Error!Value {
    const s = try builtins.stringArg(run, pos, .seconds, arg, "its time");
    try run.charge(pos, s.len);
    const t = parseTime(s) orelse return run.fail(pos, .argument, "`seconds`: \"{s}\" is not an RFC 3339 time (2026-10-14T03:00:00Z, or +02:00 for Z) nor a date (2026-10-14)", .{s[0..@min(s.len, 40)]});
    return .{ .int = t };
}

// ── sizes, padding, tables ───────────────────────────────────────────────

/// **`human(bytes)`**: `512 B`, `1.5 KiB`, `3.2 MiB`, up to EiB: one
/// decimal, rounded half up, in integers. A negative size keeps its sign.
pub fn human(run: *Run, pos: ast.Pos, arg: Value) Error!Value {
    const n = try builtins.intArg(run, pos, .human, arg, "its size");
    try run.charge(pos, 16);
    const neg = n < 0;
    const mag: u128 = @abs(@as(i128, n));
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    const sign: []const u8 = if (neg) "-" else "";
    if (mag < 1024) return .{ .string = std.fmt.allocPrint(run.alloc, "{s}{d} B", .{ sign, mag }) catch return run.oom(pos) };
    var u: usize = 1;
    while (u + 1 < units.len and mag >= (@as(u128, 1) << @intCast(10 * (u + 1)))) u += 1;
    var unit: u128 = @as(u128, 1) << @intCast(10 * u);
    var tenths = (mag * 10 + unit / 2) / unit;
    // 1023.95 KiB rounds to 1024.0: say 1.0 MiB.
    if (tenths >= 10240 and u + 1 < units.len) {
        u += 1;
        unit <<= 10;
        tenths = (mag * 10 + unit / 2) / unit;
    }
    return .{ .string = std.fmt.allocPrint(run.alloc, "{s}{d}.{d} {s}", .{ sign, tenths / 10, tenths % 10, units[u] }) catch return run.oom(pos) };
}

/// A scalar's text, as `print` writes it.
fn cellText(run: *Run, pos: ast.Pos, v: Value, what: []const u8) Error![]const u8 {
    var buf: [24]u8 = undefined;
    const t = try builtins.scalarText(run, pos, v, &buf, what);
    return run.alloc.dupe(u8, t) catch return run.oom(pos);
}

/// `text` padded with spaces to `width`: on the right (left-aligned), or,
/// for a negative width, on the left (right-aligned). Longer text is kept
/// whole.
fn padded(run: *Run, pos: ast.Pos, text: []const u8, width: i64) Error![]const u8 {
    const w: usize = @intCast(@min(@abs(width), std.math.maxInt(u32)));
    if (text.len >= w) return text;
    try run.charge(pos, w);
    const out = run.alloc.alloc(u8, w) catch return run.oom(pos);
    const gap = w - text.len;
    if (width < 0) {
        @memset(out[0..gap], ' ');
        @memcpy(out[gap..], text);
    } else {
        @memcpy(out[0..text.len], text);
        @memset(out[text.len..], ' ');
    }
    return out;
}

/// **`pad(v, width)`**: a string or an integer as text, padded with spaces
/// to `width` on the right, or to `-width` on the left (for numbers).
pub fn pad(run: *Run, pos: ast.Pos, v: Value, w_arg: Value) Error!Value {
    const width = try builtins.intArg(run, pos, .pad, w_arg, "its width");
    const text = switch (v) {
        .string => |s| s,
        .int => try cellText(run, pos, v, "pad"),
        else => return run.fail(pos, .type, "`pad` takes a string or an integer, not {s}", .{v.typeName()}),
    };
    return .{ .string = try padded(run, pos, text, width) };
}

/// **`table(rows, columns)`**: the rows (maps) as aligned text, a line for
/// the column names and one a row, the columns two spaces apart, with no
/// spaces at the ends of lines and no newline at the end (`print` adds
/// it). A column of integers is aligned on the right, its name too. Every
/// row must have every column (an error, as reading a missing key is);
/// a cell is a scalar.
pub fn table(run: *Run, pos: ast.Pos, rows_arg: Value, cols_arg: Value) Error!Value {
    const rows = try builtins.listArg(run, pos, .table, rows_arg);
    const cols = try builtins.listArg(run, pos, .table, cols_arg);
    const a = run.alloc;
    const nc = cols.list.items.len;
    const names = a.alloc([]const u8, nc) catch return run.oom(pos);
    for (cols.list.items, names, 0..) |c, *n, i| n.* = switch (c) {
        .string => |s| s,
        else => return run.fail(pos, .type, "`table`: column {d} must be a string, not {s}", .{ i + 1, c.typeName() }),
    };
    const nr = rows.list.items.len;
    // **EVERY CELL COSTS A STEP, CHARGED BEFORE THE GRID IS MADE**: an empty
    // cell's text is 0 bytes, so charging only text would let a few
    // thousand rows and columns buy millions of uncharged lookups and the
    // grid's allocation.
    try run.charge(pos, nr * nc);
    const cells = a.alloc([]const u8, nr * nc) catch return run.oom(pos);
    const widths = a.alloc(usize, nc) catch return run.oom(pos);
    const numeric = a.alloc(bool, nc) catch return run.oom(pos);
    for (names, widths, numeric) |n, *w, *num| {
        w.* = n.len;
        num.* = nr > 0;
    }
    for (rows.list.items, 0..) |row, r| {
        const m = switch (row) {
            .table => |t| if (t.kind == .map) t else return run.fail(pos, .type, "`table`: row {d} must be a map, not {s}", .{ r + 1, row.typeName() }),
            else => return run.fail(pos, .type, "`table`: row {d} must be a map, not {s}", .{ r + 1, row.typeName() }),
        };
        for (names, 0..) |n, c| {
            const v = m.map.get(n) orelse return run.fail(pos, .index, "`table`: row {d} has no \"{s}\"", .{ r + 1, n });
            if (v != .int) numeric[c] = false;
            const t = try cellText(run, pos, v, "table");
            try run.charge(pos, t.len);
            cells[r * nc + c] = t;
            widths[c] = @max(widths[c], t.len);
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (0..nr + 1) |r| {
        if (r > 0) out.append(a, '\n') catch return run.oom(pos);
        const start = out.items.len;
        for (0..nc) |c| {
            if (c > 0) out.appendSlice(a, "  ") catch return run.oom(pos);
            const t = if (r == 0) names[c] else cells[(r - 1) * nc + c];
            const w: i64 = @intCast(widths[c]);
            out.appendSlice(a, try padded(run, pos, t, if (numeric[c]) -w else w)) catch return run.oom(pos);
        }
        // No spaces at the line's end.
        while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    }
    return .{ .string = out.items };
}

// ── sort by key ──────────────────────────────────────────────────────────

const KeyContext = struct {
    key: []const u8,
    inner: builtins.SortContext = .{},

    fn lessThan(ctx: *KeyContext, x: Value, y: Value) bool {
        return ctx.inner.lessThan(x.table.map.get(ctx.key).?, y.table.map.get(ctx.key).?);
    }
};

/// **`sort(rows, key)`**: a list of maps, in place, by each one's `key`,
/// all integers or all strings. **STABLE**: rows with equal keys keep
/// their order, so a sort by one key then another orders by both.
pub fn sortByKey(run: *Run, pos: ast.Pos, t: *value.Table, key_arg: Value) Error!Value {
    const key = try builtins.stringArg(run, pos, .sort, key_arg, "its key");
    const items = t.list.items;
    if (items.len == 0) return .nil;
    var kind: ?std.meta.Tag(Value) = null;
    var bytes: u64 = 0;
    for (items, 0..) |item, i| {
        const m = switch (item) {
            .table => |m| if (m.kind == .map) m else return run.fail(pos, .type, "`sort` by a key takes a list of maps, and item {d} is {s}", .{ i + 1, item.typeName() }),
            else => return run.fail(pos, .type, "`sort` by a key takes a list of maps, and item {d} is {s}", .{ i + 1, item.typeName() }),
        };
        const v = m.map.get(key) orelse return run.fail(pos, .index, "`sort`: item {d} has no \"{s}\"", .{ i + 1, key });
        const k = std.meta.activeTag(v);
        if ((k != .int and k != .string) or (kind != null and kind.? != k))
            return run.fail(pos, .type, "`sort` by \"{s}\" takes all integers or all strings, and item {d}'s is {s}", .{ key, i + 1, v.typeName() });
        kind = k;
        if (k == .string) bytes += v.string.len;
    }
    try run.charge(pos, builtins.sortBound(items.len, bytes));
    var ctx: KeyContext = .{ .key = key };
    std.sort.block(Value, items, &ctx, KeyContext.lessThan);
    return .nil;
}
