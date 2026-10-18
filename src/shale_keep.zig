//! **THE KEEP** (metal-vmm QUEUE 233, chunk 1; the dogfood design's
//! "Running a program"): what `run` keeps of a program's output, pure. The
//! output streams in as bytes; each line is filtered (`not_re` takes the
//! lines it matches out of the stream altogether; of the rest, `re` keeps
//! those that match, and `before` and `after` keep the lines around a match
//! as grep's context does), then **kept from both
//! ends**: the first `head` lines and a ring of the last `tail`, each cut at
//! `width`. What it holds is bounded by `(head + tail) · width` and one
//! line of at most `line_most`, whatever the program prints.
//!
//! `out` is the kept lines, a line `… N lines left out …` where lines were
//! dropped between head and tail. `total` counts every line of the output,
//! `matched` those that passed the filter (grep -c: context lines are kept,
//! not counted), `kept` the lines in `out`.

const std = @import("std");
const regex = @import("webbox").script.regex;

/// The most of one line the filter looks at; past it a line is matched on
/// its first `line_most` bytes, and kept cut as any long line is.
pub const line_most = 64 * 1024;

/// A compiled pattern and the scratch its searches work in.
pub const Pattern = struct {
    program: *const regex.Program,
    scratch: *regex.Scratch,

    fn matches(p: Pattern, line: []const u8, work: *u64) bool {
        const r = regex.search(p.program, p.scratch, line, std.math.maxInt(u64));
        work.* += r.positions * p.program.insts.len;
        return r.found != null;
    }
};

pub const Options = struct {
    re: ?Pattern = null,
    not_re: ?Pattern = null,
    before: usize = 0,
    after: usize = 0,
    head: usize = 0,
    tail: usize = 0,
    width: usize = 200,
};

pub const Kept = struct {
    out: []u8,
    total: u64,
    matched: u64,
    kept: u64,
    /// The filter's searches' work, places times instructions: what the
    /// host charges beside the bytes read.
    work: u64,
};

/// The mark a cut line ends with.
pub const cut_mark = "…";

pub const Keep = struct {
    alloc: std.mem.Allocator,
    o: Options,
    /// The line being read, at most `line_most` of it.
    line: std.ArrayList(u8) = .empty,
    /// Whether the line being read ran past `line_most`.
    line_over: bool = false,
    head: std.ArrayList([]u8) = .empty,
    /// The last `tail` lines kept, a ring from `ring_at`.
    ring: [][]u8,
    ring_len: usize = 0,
    ring_at: usize = 0,
    /// The lines before the next match, for `before`: a ring as `ring`.
    back: [][]u8,
    back_len: usize = 0,
    back_at: usize = 0,
    /// How many lines after a match are still to be kept as context.
    after_left: usize = 0,
    /// The lines that passed into the keep, head and tail and between.
    passed: u64 = 0,
    total: u64 = 0,
    matched: u64 = 0,
    work: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, o: Options) error{OutOfMemory}!Keep {
        const ring = try alloc.alloc([]u8, o.tail);
        errdefer alloc.free(ring);
        const back = try alloc.alloc([]u8, if (o.re != null) o.before else 0);
        return .{ .alloc = alloc, .o = o, .ring = ring, .back = back };
    }

    pub fn deinit(k: *Keep) void {
        k.line.deinit(k.alloc);
        for (k.head.items) |l| k.alloc.free(l);
        k.head.deinit(k.alloc);
        // Each ring from where it starts: a drain stopped part way leaves
        // `back` starting past 0.
        for (0..k.ring_len) |i| k.alloc.free(k.ring[(k.ring_at + i) % k.ring.len]);
        k.alloc.free(k.ring);
        for (0..k.back_len) |i| k.alloc.free(k.back[(k.back_at + i) % k.back.len]);
        k.alloc.free(k.back);
    }

    /// The program's next bytes, any number.
    pub fn feed(k: *Keep, bytes: []const u8) error{OutOfMemory}!void {
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const piece = rest[0 .. nl orelse rest.len];
            const room = line_most - k.line.items.len;
            if (piece.len > room) k.line_over = true;
            try k.line.appendSlice(k.alloc, piece[0..@min(piece.len, room)]);
            if (nl) |i| {
                try k.endLine();
                rest = rest[i + 1 ..];
            } else rest = &.{};
        }
    }

    fn endLine(k: *Keep) error{OutOfMemory}!void {
        defer {
            k.line.clearRetainingCapacity();
            k.line_over = false;
        }
        k.total += 1;
        const l = k.line.items;
        // Out of the stream altogether: neither kept nor context.
        if (k.o.not_re) |p| if (p.matches(l, &k.work)) return;
        const hit = if (k.o.re) |p| p.matches(l, &k.work) else true;
        if (hit) {
            k.matched += 1;
            // The lines before it, in order, then it. Each leaves the ring
            // before it is passed on: `pass` owns it then (and frees it if
            // it fails), so a failure part way leaves none in two places.
            while (k.back_len > 0) {
                const l0 = k.back[k.back_at];
                k.back_at = (k.back_at + 1) % k.back.len;
                k.back_len -= 1;
                try k.pass(l0);
            }
            k.back_at = 0;
            try k.pass(try k.cut(l, k.line_over));
            k.after_left = k.o.after;
        } else if (k.after_left > 0) {
            k.after_left -= 1;
            try k.pass(try k.cut(l, k.line_over));
        } else if (k.back.len > 0) {
            const c = try k.cut(l, k.line_over);
            if (k.back_len < k.back.len) {
                k.back[(k.back_at + k.back_len) % k.back.len] = c;
                k.back_len += 1;
            } else {
                k.alloc.free(k.back[k.back_at]);
                k.back[k.back_at] = c;
                k.back_at = (k.back_at + 1) % k.back.len;
            }
        }
    }

    /// A line `width` long at most, its cut marked.
    fn cut(k: *Keep, l: []const u8, over: bool) error{OutOfMemory}![]u8 {
        if (l.len <= k.o.width and !over) return k.alloc.dupe(u8, l);
        const n = @min(l.len, k.o.width);
        const c = try k.alloc.alloc(u8, n + cut_mark.len);
        @memcpy(c[0..n], l[0..n]);
        @memcpy(c[n..], cut_mark);
        return c;
    }

    /// A line through the filter (owned now by the keep): to the head
    /// while it has room, else to the tail's ring, the oldest out.
    fn pass(k: *Keep, line: []u8) error{OutOfMemory}!void {
        k.passed += 1;
        if (k.head.items.len < k.o.head) {
            k.head.append(k.alloc, line) catch |e| {
                k.alloc.free(line);
                return e;
            };
            return;
        }
        if (k.ring.len == 0) {
            k.alloc.free(line);
            return;
        }
        if (k.ring_len < k.ring.len) {
            k.ring[(k.ring_at + k.ring_len) % k.ring.len] = line;
            k.ring_len += 1;
        } else {
            k.alloc.free(k.ring[k.ring_at]);
            k.ring[k.ring_at] = line;
            k.ring_at = (k.ring_at + 1) % k.ring.len;
        }
    }

    /// The output ended: its last line, if it had no newline, and what was
    /// kept. `out` is the caller's, from the keep's allocator.
    pub fn finish(k: *Keep) error{OutOfMemory}!Kept {
        if (k.line.items.len > 0 or k.line_over) try k.endLine();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(k.alloc);
        for (k.head.items) |l| {
            try out.appendSlice(k.alloc, l);
            try out.append(k.alloc, '\n');
        }
        const left_out = k.passed - k.head.items.len - k.ring_len;
        if (left_out > 0) try out.print(k.alloc, "… {d} line{s} left out …\n", .{ left_out, if (left_out == 1) "" else "s" });
        var i: usize = 0;
        while (i < k.ring_len) : (i += 1) {
            try out.appendSlice(k.alloc, k.ring[(k.ring_at + i) % k.ring.len]);
            try out.append(k.alloc, '\n');
        }
        return .{ .out = try out.toOwnedSlice(k.alloc), .total = k.total, .matched = k.matched, .kept = k.head.items.len + k.ring_len, .work = k.work };
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// **THE ORACLE** (the design's): the output split into lines, filtered as
/// grep's context would, each cut, then the first `head` and the last
/// `tail`, a mark between where lines were dropped. Plainly right, and slow.
fn oracle(a: std.mem.Allocator, out: []const u8, o: Options, re: ?[]const u8, not_re: ?[]const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| try all.append(a, l);
    if (all.items.len > 0 and all.items[all.items.len - 1].len == 0) _ = all.pop();
    // `not_re`'s lines out of the stream first.
    var lines: std.ArrayList([]const u8) = .empty;
    for (all.items) |l| if (not_re == null or !try matchesText(a, not_re.?, l[0..@min(l.len, line_most)])) try lines.append(a, l);
    const hits = try a.alloc(bool, lines.items.len);
    for (lines.items, hits) |l, *h| h.* = if (re) |p| try matchesText(a, p, l[0..@min(l.len, line_most)]) else true;
    var passed: std.ArrayList([]const u8) = .empty;
    for (lines.items, 0..) |l, i| {
        // A match, or within `after` lines after one, or `before` before.
        var keep = hits[i];
        var d: usize = 1;
        while (!keep and d <= o.after and d <= i) : (d += 1) keep = hits[i - d];
        d = 1;
        while (!keep and d <= o.before and i + d < lines.items.len) : (d += 1) keep = hits[i + d];
        if (keep) try passed.append(a, if (l.len > o.width) try std.mem.concat(a, u8, &.{ l[0..o.width], cut_mark }) else l);
    }
    var out_lines: std.ArrayList(u8) = .empty;
    const h = @min(o.head, passed.items.len);
    for (passed.items[0..h]) |l| try out_lines.print(a, "{s}\n", .{l});
    const rest = passed.items[h..];
    const t = @min(o.tail, rest.len);
    if (rest.len > t) try out_lines.print(a, "… {d} line{s} left out …\n", .{ rest.len - t, if (rest.len - t == 1) "" else "s" });
    for (rest[rest.len - t ..]) |l| try out_lines.print(a, "{s}\n", .{l});
    return out_lines.items;
}

fn matchesText(a: std.mem.Allocator, pattern: []const u8, s: []const u8) !bool {
    var refused: regex.Refusal = undefined;
    var p = try regex.compile(a, pattern, .{}, &refused);
    var sc = try regex.Scratch.init(a, &p);
    return regex.search(&p, &sc, s, std.math.maxInt(u64)).found != null;
}

fn kept(a: std.mem.Allocator, out: []const u8, o: Options, re: ?[]const u8, not_re: ?[]const u8, cut_at: usize) !Kept {
    var opts = o;
    var refused: regex.Refusal = undefined;
    if (re) |p| {
        const prog = try a.create(regex.Program);
        prog.* = try regex.compile(a, p, .{}, &refused);
        const sc = try a.create(regex.Scratch);
        sc.* = try regex.Scratch.init(a, prog);
        opts.re = .{ .program = prog, .scratch = sc };
    }
    if (not_re) |p| {
        const prog = try a.create(regex.Program);
        prog.* = try regex.compile(a, p, .{}, &refused);
        const sc = try a.create(regex.Scratch);
        sc.* = try regex.Scratch.init(a, prog);
        opts.not_re = .{ .program = prog, .scratch = sc };
    }
    var k = try Keep.init(a, opts);
    // Fed in pieces, cut anywhere: a line's end may come in a later piece.
    var at: usize = 0;
    while (at < out.len) {
        const n = @min(cut_at, out.len - at);
        try k.feed(out[at..][0..n]);
        at += n;
    }
    return k.finish();
}

test "keep: head and tail and the filter, against take and last over the filtered lines, on random outputs (the design's oracle)" {
    var prng = std.Random.DefaultPrng.init(233);
    const rand = prng.random();
    const pieces = [_][]const u8{ "ok", "error", "FAIL", "x", "\n", "\n", "\n", "\r\n", "\x00", " ", "warn" };
    const patterns = [_]?[]const u8{ null, "error|FAIL", "^ok", "x$", "warn" };
    for (0..3000) |round| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        for (0..rand.uintAtMost(usize, 60)) |_| try out.appendSlice(a, pieces[rand.uintLessThan(usize, pieces.len)]);
        // Sometimes a long line.
        if (rand.uintLessThan(u8, 8) == 0) try out.appendNTimes(a, 'L', 300);
        const o: Options = .{
            .head = rand.uintAtMost(usize, 4),
            .tail = rand.uintAtMost(usize, 4),
            .width = 1 + rand.uintAtMost(usize, 12),
            .before = rand.uintAtMost(usize, 2),
            .after = rand.uintAtMost(usize, 2),
        };
        const re = patterns[rand.uintLessThan(usize, patterns.len)];
        const not_re: ?[]const u8 = if (rand.uintLessThan(u8, 4) == 0) "warn" else null;
        const got = try kept(a, out.items, o, re, not_re, 1 + rand.uintAtMost(usize, 7));
        const want = try oracle(a, out.items, o, re, not_re);
        errdefer std.debug.print("round {d}: \"{f}\" {any} re {?s} not {?s}\ngot:\n{s}\nwant:\n{s}\n", .{ round, std.zig.fmtString(out.items), o, re, not_re, got.out, want });
        try testing.expectEqualStrings(want, got.out);
        // The counts: every line; the filter's; what is in `out`.
        var total: u64 = std.mem.count(u8, out.items, "\n");
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') total += 1;
        try testing.expectEqual(total, got.total);
        try testing.expect(got.kept <= o.head + o.tail);
        try testing.expect(got.matched <= got.total);
    }
}

test "keep: the edges: nothing, no final newline, fewer lines than head and tail, a line past line_most, nothing kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try kept(a, "", .{ .head = 2, .tail = 2 }, null, null, 4);
    try testing.expectEqualStrings("", empty.out);
    try testing.expectEqual(@as(u64, 0), empty.total);
    const short = try kept(a, "a\nb\nc", .{ .head = 2, .tail = 2 }, null, null, 1);
    try testing.expectEqualStrings("a\nb\nc\n", short.out);
    try testing.expectEqual(@as(u64, 3), short.kept);
    const many = try kept(a, "1\n2\n3\n4\n5\n6\n7\n", .{ .head = 2, .tail = 2 }, null, null, 3);
    try testing.expectEqualStrings("1\n2\n… 3 lines left out …\n6\n7\n", many.out);
    try testing.expectEqual(@as(u64, 7), many.total);
    // A line past line_most is matched on its first part and kept cut.
    var huge: std.ArrayList(u8) = .empty;
    try huge.appendSlice(a, "error ");
    try huge.appendNTimes(a, 'z', line_most + 10);
    try huge.appendSlice(a, " tail\nok\n");
    const h = try kept(a, huge.items, .{ .head = 5, .width = 8 }, "error", null, 4096);
    try testing.expectEqualStrings("error zz…\n", h.out);
    try testing.expectEqual(@as(u64, 1), h.matched);
    try testing.expectEqual(@as(u64, 2), h.total);
    // head 0 and tail 0: nothing kept, the counts still counted.
    const none = try kept(a, "a\nerror\nb\n", .{}, "error", null, 2);
    try testing.expectEqualStrings("… 1 line left out …\n", none.out);
    try testing.expectEqual(@as(u64, 1), none.matched);
}

test "keep: an allocation refused anywhere (the host's cap) leaves nothing freed twice and nothing leaked" {
    var refused: regex.Refusal = undefined;
    var prog = try regex.compile(testing.allocator, "error", .{}, &refused);
    defer prog.deinit(testing.allocator);
    var sc = try regex.Scratch.init(testing.allocator, &prog);
    defer sc.deinit(testing.allocator);
    const out = "a\nb\nc\nerror one\nd\ne\nf\ng\nerror two\nh\n";
    // Every allocation the keep makes, refused in turn.
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        const a = failing.allocator();
        var k = Keep.init(a, .{ .re = .{ .program = &prog, .scratch = &sc }, .before = 3, .after = 1, .head = 8, .tail = 1 }) catch continue;
        defer k.deinit();
        k.feed(out) catch continue;
        const got = k.finish() catch continue;
        a.free(got.out);
        if (!failing.has_induced_failure) break;
    }
    try testing.expect(fail_at > 5);
}
