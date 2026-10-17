//! **THE BUILTINS' PROPERTIES** (metal-vmm QUEUE 209(e)): what must hold
//! between builtins whatever the input, tried on random inputs from fixed
//! seeds. Each script states its property and prints `ok`, or what broke;
//! where Zig can say the answer itself (a stable sort, the table's
//! columns), it does, and the script's answer is checked against it.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

var out_buf: [256 * 1024]u8 = undefined;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        try self.tmp.dir.createDir(self.threaded.io(), "data", .default_dir);
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn put(self: *Fixture, name: []const u8, data: []const u8) !void {
        var buf: [64]u8 = undefined;
        try self.tmp.dir.writeFile(self.threaded.io(), .{ .sub_path = try std.fmt.bufPrint(&buf, "data/{s}", .{name}), .data = data });
    }

    /// Runs `src`, which must finish; its output, owned by the caller.
    fn output(self: *Fixture, src: []const u8) ![]u8 {
        var r = script.run(self.threaded.io(), testing.allocator, self.root, src, .{ .steps = 50_000_000, .arena_bytes = 64 * 1024 * 1024 }, 0, &out_buf);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        return testing.allocator.dupe(u8, r.output);
    }

    fn expectOk(self: *Fixture, src: []const u8, what: []const u8) !void {
        const out = try self.output(src);
        defer testing.allocator.free(out);
        if (!std.mem.eql(u8, out, "ok\n")) {
            std.debug.print("{s}: {s}\n", .{ what, out });
            return error.TestUnexpectedResult;
        }
    }
};

/// A haystack and a needle that meet often: a small alphabet, the needle
/// sometimes planted, sometimes the size of a scan's chunk boundary.
fn haystackAndNeedle(rand: std.Random, hay: *std.ArrayList(u8), needle: *std.ArrayList(u8)) !void {
    hay.clearRetainingCapacity();
    needle.clearRetainingCapacity();
    const alphabet = "ab\n";
    const nlen: usize = switch (rand.uintLessThan(u8, 4)) {
        0 => 1,
        1 => 1 + rand.uintLessThan(usize, 4),
        2 => 1 + rand.uintLessThan(usize, 40),
        else => 1000 + rand.uintLessThan(usize, 9000),
    };
    for (0..nlen) |_| try needle.append(testing.allocator, alphabet[rand.uintLessThan(usize, 2)]);
    const size: usize = switch (rand.uintLessThan(u8, 4)) {
        0 => rand.uintLessThan(usize, 50),
        1 => rand.uintLessThan(usize, 5000),
        else => 60_000 + rand.uintLessThan(usize, 300_000),
    };
    while (hay.items.len < size) {
        if (rand.uintLessThan(u8, 8) == 0) {
            try hay.appendSlice(testing.allocator, needle.items);
        } else try hay.append(testing.allocator, alphabet[rand.uintLessThan(usize, alphabet.len)]);
    }
}

/// The needle's occurrences, none overlapping, left to right.
fn occurrences(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, hay, at, needle)) |i| {
        n += 1;
        at = i + needle.len;
    }
    return n;
}

test "props: reading in pieces and joining is a whole read; count_in, find_in, split and join agree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(209);
    const rand = prng.random();
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(testing.allocator);
    var needle: std.ArrayList(u8) = .empty;
    defer needle.deinit(testing.allocator);
    for (0..40) |_| {
        try haystackAndNeedle(rand, &hay, &needle);
        try f.put("h", hay.items);
        try f.put("t", needle.items);
        // Pieces of any size, at most a few thousand reads.
        const piece = @max(1 + rand.uintLessThan(usize, 70_000), hay.items.len / 2000 + 1);
        var src_buf: [2048]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf,
            \\local s = read("h")
            \\local t = read("t")
            \\local parts = {{}}
            \\local off = 0
            \\while off < #s do
            \\  push(parts, read("h", off, {d}))
            \\  off = off + {d}
            \\end
            \\if join(parts, "") ~= s then print("pieces joined are not the whole read") end
            \\if read("h", #s) ~= "" or read("h", #s + 7) ~= "" or read("h", 0) ~= s then print("the end, or the start") end
            \\local c = count_in("h", t)
            \\if c ~= #split(s, t) - 1 then print("count_in", c, #split(s, t) - 1) end
            \\if c ~= {d} then print("count_in against Zig", c) end
            \\local fi = find_in("h", t)
            \\local fs = find(s, t)
            \\if (fi == nil) ~= (fs == nil) or (fi ~= nil and fi + 1 ~= fs) then print("find_in", fi, fs) end
            \\if fi ~= nil and read("h", fi, #t) ~= t then print("find_in's offset reads the needle") end
            \\if join(split(s, t), t) ~= s then print("split then join") end
            \\print("ok")
        , .{ piece, piece, occurrences(hay.items, needle.items) });
        f.expectOk(src, "store and text") catch |e| {
            std.debug.print("  haystack {d} bytes, needle {d} bytes, pieces of {d}\n", .{ hay.items.len, needle.items.len, piece });
            return e;
        };
    }
}

test "props: split then join round-trips any string and separator" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(2091);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    // Strings and separators written into the source: printable bytes,
    // escaped where they must be.
    const alphabet = "ab,;\\\" ";
    for (0..200) |_| {
        src.clearRetainingCapacity();
        try src.appendSlice(testing.allocator, "local s = \"");
        for (0..rand.uintLessThan(usize, 30)) |_| try appendEscaped(&src, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        try src.appendSlice(testing.allocator, "\"\nlocal sep = \"");
        for (0..1 + rand.uintLessThan(usize, 3)) |_| try appendEscaped(&src, alphabet[rand.uintLessThan(usize, alphabet.len)]);
        try src.appendSlice(testing.allocator,
            \\"
            \\local pieces = split(s, sep)
            \\if join(pieces, sep) ~= s then print("join", s, sep) end
            \\for p in pieces do if contains(p, sep) then print("a piece holds the separator") end end
            \\if #pieces - 1 ~= #substitute(s, sep, sep .. "x") - #s then print("one piece more than separators") end
            \\print("ok")
        );
        try f.expectOk(src.items, "split and join");
    }
}

fn appendEscaped(src: *std.ArrayList(u8), c: u8) !void {
    if (c == '\\' or c == '"') try src.append(testing.allocator, '\\');
    try src.append(testing.allocator, c);
}

test "props: sort by key B then key A orders as one sort by (A, B), equal rows kept in order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(2092);
    const rand = prng.random();
    const Row = struct { a: u8, b: u8, i: usize };
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    for (0..60) |round| {
        const n = rand.uintLessThan(usize, 40);
        var rows: [40]Row = undefined;
        for (rows[0..n], 0..) |*r, i| r.* = .{ .a = rand.uintLessThan(u8, 4), .b = rand.uintLessThan(u8, 4), .i = i };
        // Strings one round, integers the next: the two kinds sort alike.
        const strings = round % 2 == 0;
        src.clearRetainingCapacity();
        try src.appendSlice(testing.allocator, "local rows = {}\n");
        for (rows[0..n]) |r| {
            if (strings) {
                try src.print(testing.allocator, "push(rows, {{a = \"k{c}\", b = \"k{c}\", i = {d}}})\n", .{ 'a' + r.a, 'a' + r.b, r.i });
            } else try src.print(testing.allocator, "push(rows, {{a = {d}, b = {d}, i = {d}}})\n", .{ @as(i64, r.a) - 2, @as(i64, r.b) - 2, r.i });
        }
        try src.appendSlice(testing.allocator,
            \\sort(rows, "b")
            \\sort(rows, "a")
            \\local is = {}
            \\for r in rows do push(is, r.i) end
            \\print(join(is, " "))
        );
        std.sort.block(Row, rows[0..n], {}, struct {
            fn lt(_: void, x: Row, y: Row) bool {
                return x.a < y.a or (x.a == y.a and x.b < y.b);
            }
        }.lt);
        want.clearRetainingCapacity();
        for (rows[0..n], 0..) |r, k| try want.print(testing.allocator, "{s}{d}", .{ if (k > 0) " " else "", r.i });
        try want.append(testing.allocator, '\n');
        const out = try f.output(src.items);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(want.items, out);
    }
}

test "props: seconds(date(x)) is x across the whole range" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(2093);
    const rand = prng.random();
    const last: i64 = 253_402_300_799; // 9999-12-31T23:59:59Z
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.print(testing.allocator, "local xs = {{0, 1, 59, 86399, 86400, 951782400, 951868800, {d}, {d}", .{ last - 1, last });
    for (0..2000) |k| {
        // Most anywhere; some near a day's edge, where a calendar slips.
        const x = if (k % 4 == 0) @divFloor(rand.intRangeAtMost(i64, 0, last), 86400) * 86400 + rand.intRangeAtMost(i64, -1, 1) else rand.intRangeAtMost(i64, 0, last);
        try src.print(testing.allocator, ", {d}", .{std.math.clamp(x, 0, last)});
    }
    try src.appendSlice(testing.allocator,
        \\}
        \\for x in xs do
        \\  local d = date(x)
        \\  if seconds(d) ~= x then print(x, d, seconds(d)) end
        \\  if seconds(sub(d, 1, 10)) ~= x - x % 86400 then print("its day", x, d) end
        \\end
        \\print("ok")
    );
    try f.expectOk(src.items, "dates");
}

test "props: table() lines up any rows: each cell in its column, strings left, integers right" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(2094);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    const names = [_][]const u8{ "name", "n", "size", "a_long_column" };
    const most_rows = 12;
    for (0..100) |_| {
        const nr = rand.uintLessThan(usize, most_rows);
        const nc = 1 + rand.uintLessThan(usize, names.len);
        // Each column one kind for every row: strings, or integers.
        var ints: [names.len]bool = undefined;
        for (ints[0..nc]) |*k| k.* = rand.boolean();
        // Every cell's text, kept to check against: (row, column) ranges
        // into `text`, the header as row 0.
        var cells: [most_rows + 1][names.len][]const u8 = undefined;
        text.clearRetainingCapacity();
        try text.ensureTotalCapacity(testing.allocator, 4096);
        src.clearRetainingCapacity();
        try src.appendSlice(testing.allocator, "local rows = {}\n");
        for (names[0..nc], 0..) |n, c| cells[0][c] = n;
        for (1..nr + 1) |r| {
            try src.appendSlice(testing.allocator, "push(rows, {");
            for (names[0..nc], ints[0..nc], 0..) |n, int, c| {
                if (c > 0) try src.appendSlice(testing.allocator, ", ");
                const start = text.items.len;
                if (int) {
                    text.printAssumeCapacity("{d}", .{rand.intRangeAtMost(i64, -100_000, 10_000_000) >> rand.uintLessThan(u6, 24)});
                    try src.print(testing.allocator, "{s} = {s}", .{ n, text.items[start..] });
                } else {
                    for (0..rand.uintLessThan(usize, 16)) |_| text.appendAssumeCapacity("xyz-"[rand.uintLessThan(usize, 4)]);
                    try src.print(testing.allocator, "{s} = \"{s}\"", .{ n, text.items[start..] });
                }
                cells[r][c] = text.items[start..];
            }
            try src.appendSlice(testing.allocator, "})\n");
        }
        try src.appendSlice(testing.allocator, "print(table(rows, {");
        for (names[0..nc], 0..) |n, c| try src.print(testing.allocator, "{s}\"{s}\"", .{ if (c > 0) ", " else "", n });
        try src.appendSlice(testing.allocator, "}))\n");
        const out = try f.output(src.items);
        defer testing.allocator.free(out);
        checkTable(out, cells[0 .. nr + 1], ints[0..nc], nr > 0) catch |e| {
            std.debug.print("{s}\n{s}", .{ src.items, out });
            return e;
        };
    }
}

/// Each column as wide as its widest cell, the name among them, two
/// spaces apart; a string cell starts at its column's start, an integer
/// cell (the column's name too) ends at its column's end; no line ends in
/// a space.
fn checkTable(out: []const u8, cells: []const [4][]const u8, ints: []const bool, any_rows: bool) !void {
    const nc = ints.len;
    var widths: [4]usize = @splat(0);
    for (cells) |row| for (row[0..nc], 0..) |t, c| {
        widths[c] = @max(widths[c], t.len);
    };
    var starts: [4]usize = undefined;
    var x: usize = 0;
    for (0..nc) |c| {
        starts[c] = x;
        x += widths[c] + 2;
    }
    try testing.expect(out.len > 0 and out[out.len - 1] == '\n');
    var it = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');
    var r: usize = 0;
    while (it.next()) |line| : (r += 1) {
        try testing.expect(r < cells.len);
        if (line.len > 0) try testing.expect(line[line.len - 1] != ' ');
        // The line padded back to its full width, then each cell read at
        // its place.
        var full: [512]u8 = @splat(' ');
        @memcpy(full[0..line.len], line);
        for (0..nc) |c| {
            const place = full[starts[c] .. starts[c] + widths[c]];
            const t = cells[r][c];
            // A column of integers only while there are rows to have them.
            const right = ints[c] and any_rows;
            const at = if (right) widths[c] - t.len else 0;
            try testing.expectEqualStrings(t, place[at .. at + t.len]);
            for (place[0..at]) |b| try testing.expectEqual(' ', b);
            for (place[at + t.len ..]) |b| try testing.expectEqual(' ', b);
            if (c + 1 < nc) try testing.expectEqualStrings("  ", full[starts[c] + widths[c] ..][0..2]);
        }
        try testing.expect(line.len <= x - 2);
    }
    try testing.expectEqual(cells.len, r);
}

test "property: read_lines over a file, in parts of any size, gives lines(read(the whole file)), each line whole (QUEUE 229)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(229);
    const rand = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..60) |round| {
        text.clearRetainingCapacity();
        // Lines of 0 to 40 bytes, sometimes no newline at the end, and
        // sometimes no line at all.
        const n_lines = rand.uintAtMost(usize, 30);
        for (0..n_lines) |_| {
            const len = rand.uintAtMost(usize, 40);
            for (0..len) |_| try text.append(testing.allocator, "abc \t\r"[rand.uintLessThan(usize, 6)]);
            try text.append(testing.allocator, '\n');
        }
        if (rand.boolean() and text.items.len > 0) _ = text.pop();
        try f.put("t.txt", text.items);
        const part = 1 + rand.uintAtMost(usize, 64);
        var src_buf: [1024]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf,
            \\local whole = lines(read_or("t.txt", ""))
            \\local got = {{}}
            \\local at = 0
            \\local parts = 0
            \\while true do
            \\  local r = read_lines("t.txt", at, {d})
            \\  for l in r.lines do push(got, l) end
            \\  parts = parts + 1
            \\  if r.done then break end
            \\  if r.next <= at then print("no progress at " .. at) break end
            \\  at = r.next
            \\end
            \\local ok = #got == #whole
            \\if ok then for i = 1, #got do if got[i] ~= whole[i] then ok = false end end end
            \\if ok then print("ok") else print(join(got, "|") .. " ~= " .. join(whole, "|")) end
        , .{part});
        errdefer std.debug.print("round {d}, parts of {d}\n", .{ round, part });
        try f.expectOk(src, "read_lines");
    }
}

test "property: line_at at every offset of a file is the line lines(read(whole)) has there" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.put("t.txt", "one\n\ntwo words\nlast");
    try f.expectOk(
        \\local whole = read("t.txt")
        \\local ls = lines(whole)
        \\local line = 1
        \\local ok = true
        \\for at = 0, #whole - 1 do
        \\  if line_at("t.txt", at) ~= ls[line] then ok = false print("at " .. at) end
        \\  if sub(whole, at + 1, at + 1) == "\n" then line = line + 1 end
        \\end
        \\if line_at("t.txt", #whole) ~= nil then ok = false end
        \\if ok then print("ok") end
    , "line_at");
}

// ── regular expressions (metal-vmm QUEUE 230, chunk 2) ──────────────────

const regex = script.regex;

/// **A PATTERN OF THE SUBSET, AS A TREE**: what the generator makes, the
/// reference matcher reads, and `render` writes as the pattern's text. The
/// reference never parses: it reads the tree the text was written from.
const GNode = struct {
    kind: enum { lit, any, set, start, end, group },
    c: u8 = 0,
    set: usize = 0,
    quant: enum { one, star, plus, opt } = .one,
    inner: []const GNode = &.{},
};

/// The classes the generator writes, and which bytes each holds.
const gen_sets = [_]struct { text: []const u8, holds: []const u8 }{
    .{ .text = "[ab]", .holds = "ab" },
    .{ .text = "[^a]", .holds = "b1 .\n" },
    .{ .text = "[a-b]", .holds = "ab" },
    .{ .text = "\\d", .holds = "1" },
    .{ .text = "\\w", .holds = "ab1" },
    .{ .text = "\\s", .holds = " \n" },
    .{ .text = "[^ab1]", .holds = " .\n" },
    .{ .text = "[.1]", .holds = ".1" },
    .{ .text = "[\\d ]", .holds = "1 " },
    .{ .text = "\\S", .holds = "ab1." },
};
/// What the strings are made of: every class above tells some apart.
const gen_alphabet = "ab1 .\n";

fn genSeq(rand: std.Random, arena: std.mem.Allocator, len_most: usize, group_left: *bool) ![]const GNode {
    const n = rand.uintAtMost(usize, len_most);
    const seq = try arena.alloc(GNode, n);
    for (seq) |*node| {
        node.* = switch (rand.uintLessThan(u8, 16)) {
            0...5 => .{ .kind = .lit, .c = "ab1 .\n"[rand.uintLessThan(usize, 6)] },
            6, 7 => .{ .kind = .any },
            8...10 => .{ .kind = .set, .set = rand.uintLessThan(usize, gen_sets.len) },
            11 => .{ .kind = .start },
            12 => .{ .kind = .end },
            else => if (group_left.*) blk: {
                group_left.* = false;
                var none = false;
                break :blk .{ .kind = .group, .inner = try genSeq(rand, arena, 3, &none) };
            } else .{ .kind = .lit, .c = 'a' },
        };
        if (node.kind != .start and node.kind != .end) node.quant = switch (rand.uintLessThan(u8, 8)) {
            0, 1 => .star,
            2 => .plus,
            3 => .opt,
            else => .one,
        };
    }
    return seq;
}

fn render(out: *std.ArrayList(u8), seq: []const GNode) !void {
    const a = testing.allocator;
    for (seq) |node| {
        switch (node.kind) {
            .lit => switch (node.c) {
                '.' => try out.appendSlice(a, "\\."),
                '\n' => try out.appendSlice(a, "\\n"),
                else => try out.append(a, node.c),
            },
            .any => try out.append(a, '.'),
            .set => try out.appendSlice(a, gen_sets[node.set].text),
            .start => try out.append(a, '^'),
            .end => try out.append(a, '$'),
            .group => {
                try out.append(a, '(');
                try render(out, node.inner);
                try out.append(a, ')');
            },
        }
        switch (node.quant) {
            .one => {},
            .star => try out.append(a, '*'),
            .plus => try out.append(a, '+'),
            .opt => try out.append(a, '?'),
        }
    }
}

/// **THE REFERENCE: A BACKTRACKING MATCHER**, slow and plainly right:
/// each choice tried in its order of preference (more before fewer, a
/// group's `?` taken before skipped), the first way through that reaches
/// the pattern's end is the match. A loop's turn that matched nothing
/// ends the loop as failed (a `+`'s first turn excepted), as a Thompson
/// machine's does: an empty turn is never what makes a match.
const Ref = struct {
    s: []const u8,

    const Caps = struct { gs: ?usize = null, ge: ?usize = null };
    const Hit = struct { end: usize, caps: Caps };
    const Cont = union(enum) {
        done,
        seq: struct { rest: []const GNode, next: *const Cont },
        close: *const Cont,
        /// After a `*` turn begun at `start`: another turn, or on.
        again: struct { node: *const GNode, start: usize, next: *const Cont },
        /// After a `+`'s first turn: more turns, or on.
        more: struct { node: *const GNode, next: *const Cont },
    };

    fn go(r: Ref, k: *const Cont, pos: usize, caps: Caps) ?Hit {
        return switch (k.*) {
            .done => .{ .end = pos, .caps = caps },
            .seq => |q| r.seqAt(q.rest, q.next, pos, caps),
            .close => |next| r.go(next, pos, .{ .gs = caps.gs, .ge = pos }),
            .again => |q| if (pos == q.start) null else r.star(q.node, q.next, pos, caps),
            .more => |q| r.star(q.node, q.next, pos, caps),
        };
    }

    fn seqAt(r: Ref, nodes: []const GNode, k: *const Cont, pos: usize, caps: Caps) ?Hit {
        if (nodes.len == 0) return r.go(k, pos, caps);
        const n = &nodes[0];
        const rest: Cont = .{ .seq = .{ .rest = nodes[1..], .next = k } };
        return switch (n.quant) {
            .one => r.once(n, &rest, pos, caps),
            .opt => r.once(n, &rest, pos, caps) orelse r.go(&rest, pos, caps),
            .star => r.star(n, &rest, pos, caps),
            .plus => r.once(n, &Cont{ .more = .{ .node = n, .next = &rest } }, pos, caps),
        };
    }

    fn star(r: Ref, n: *const GNode, k: *const Cont, pos: usize, caps: Caps) ?Hit {
        return r.once(n, &Cont{ .again = .{ .node = n, .start = pos, .next = k } }, pos, caps) orelse r.go(k, pos, caps);
    }

    fn once(r: Ref, n: *const GNode, k: *const Cont, pos: usize, caps: Caps) ?Hit {
        const at: ?u8 = if (pos < r.s.len) r.s[pos] else null;
        return switch (n.kind) {
            .lit => if (at != null and at.? == n.c) r.go(k, pos + 1, caps) else null,
            .any => if (at != null and at.? != '\n') r.go(k, pos + 1, caps) else null,
            .set => if (at != null and std.mem.indexOfScalar(u8, gen_sets[n.set].holds, at.?) != null) r.go(k, pos + 1, caps) else null,
            .start => if (pos == 0) r.go(k, pos, caps) else null,
            .end => if (pos == r.s.len) r.go(k, pos, caps) else null,
            .group => r.seqAt(n.inner, &Cont{ .close = k }, pos, .{ .gs = pos, .ge = null }),
        };
    }

    /// The leftmost match, as `regex.search` gives it.
    fn find(r: Ref, seq: []const GNode) ?regex.Found {
        for (0..r.s.len + 1) |start| {
            if (r.seqAt(seq, &Cont{ .done = {} }, start, .{})) |h| return .{
                .start = start,
                .end = h.end,
                .group = if (h.caps.gs != null and h.caps.ge != null) .{ h.caps.gs.?, h.caps.ge.? } else null,
            };
        }
        return null;
    }
};

fn groupText(s: []const u8, f: regex.Found) []const u8 {
    return if (f.group) |g| s[g[0]..g[1]] else "";
}

test "property: re_find's machine finds what a backtracking matcher finds, on random patterns of the subset and random strings (QUEUE 230)" {
    var prng = std.Random.DefaultPrng.init(230);
    const rand = prng.random();
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(testing.allocator);
    var matched: usize = 0;
    for (0..20_000) |round| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var group_left = true;
        const tree = try genSeq(rand, arena.allocator(), 6, &group_left);
        pattern.clearRetainingCapacity();
        try render(&pattern, tree);
        s.clearRetainingCapacity();
        for (0..rand.uintAtMost(usize, 12)) |_| try s.append(testing.allocator, gen_alphabet[rand.uintLessThan(usize, gen_alphabet.len)]);

        var refused: regex.Refusal = undefined;
        var program = regex.compile(testing.allocator, pattern.items, &refused) catch |e| {
            std.debug.print("round {d}: /{s}/ refused at {d}: {s}\n", .{ round, pattern.items, refused.at, refused.message });
            return e;
        };
        defer program.deinit(testing.allocator);
        var scratch = try regex.Scratch.init(testing.allocator, &program);
        defer scratch.deinit(testing.allocator);
        const got = regex.search(&program, &scratch, s.items, std.math.maxInt(u64));
        const want = (Ref{ .s = s.items }).find(tree);
        errdefer std.debug.print("round {d}: /{s}/ on \"{f}\": got {?any}, want {?any}\n", .{ round, pattern.items, std.zig.fmtString(s.items), got.found, want });
        try testing.expect(got.finished);
        try testing.expectEqual(want == null, got.found == null);
        if (want) |w| {
            matched += 1;
            try testing.expectEqual(w.start, got.found.?.start);
            try testing.expectEqual(w.end, got.found.?.end);
            try testing.expectEqualStrings(groupText(s.items, w), groupText(s.items, got.found.?));
        }
    }
    // The rounds are not all misses.
    try testing.expect(matched > 5_000);
}

/// `s` written inside a Shale string literal.
fn appendShaleString(src: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '\n' => try src.appendSlice(testing.allocator, "\\n"),
        '\\', '"' => {
            try src.append(testing.allocator, '\\');
            try src.append(testing.allocator, c);
        },
        else => try src.append(testing.allocator, c),
    };
}

test "property: re_find and re_match in a script say what the backtracking matcher says, through both engines (QUEUE 230)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(2301);
    const rand = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    var s_buf: [16]u8 = undefined;
    for (0..300) |round| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var group_left = true;
        const tree = try genSeq(rand, arena.allocator(), 6, &group_left);
        pattern.clearRetainingCapacity();
        try render(&pattern, tree);
        const s = s_buf[0..rand.uintAtMost(usize, s_buf.len)];
        for (s) |*c| c.* = gen_alphabet[rand.uintLessThan(usize, gen_alphabet.len)];
        // The script: every field of the match, the group's only when the
        // pattern has one.
        src.clearRetainingCapacity();
        try src.appendSlice(testing.allocator, "local s = \"");
        try appendShaleString(&src, s);
        try src.appendSlice(testing.allocator, "\"\nlocal p = \"");
        try appendShaleString(&src, pattern.items);
        try src.appendSlice(testing.allocator,
            \\"
            \\local m = re_find(s, p)
            \\if m then print(m.at, "[" .. m.text .. "]", "[" .. get(m, "group", "-") .. "]", re_match(s, p)) else print("none", re_match(s, p)) end
        );
        const has_group = std.mem.indexOfScalar(u8, pattern.items, '(') != null;
        want.clearRetainingCapacity();
        if ((Ref{ .s = s }).find(tree)) |w| {
            try want.print(testing.allocator, "{d}\t[{s}]\t[{s}]\ttrue\n", .{ w.start + 1, s[w.start..w.end], if (has_group) groupText(s, w) else "-" });
        } else try want.appendSlice(testing.allocator, "none\tfalse\n");
        const out = try f.output(src.items);
        defer testing.allocator.free(out);
        errdefer std.debug.print("round {d}: /{s}/ on \"{f}\"\n", .{ round, pattern.items, std.zig.fmtString(s) });
        try testing.expectEqualStrings(want.items, out);
    }
}

/// The steps of `re_find(rep("a", n), pattern)` alone, its setup's taken off.
fn reSteps(f: *Fixture, pattern: []const u8, n: usize) !u64 {
    var buf: [256]u8 = undefined;
    const setup = try std.fmt.bufPrint(&buf, "local s = rep(\"a\", {d})", .{n});
    var r0 = script.run(f.threaded.io(), testing.allocator, f.root, setup, .{ .steps = 500_000_000 }, 0, &out_buf);
    defer r0.deinit();
    var buf2: [512]u8 = undefined;
    const whole = try std.fmt.bufPrint(&buf2, "{s}\nlocal m = re_find(s, \"{s}\")", .{ setup, pattern });
    var r = script.run(f.threaded.io(), testing.allocator, f.root, whole, .{ .steps = 500_000_000 }, 0, &out_buf);
    defer r.deinit();
    try testing.expect(r.finished());
    return r.steps - r0.steps;
}

test "property: a search's cost is linear in the string, whatever the pattern: `(a*)*b` on a run of `a` costs about what `a*b` does (QUEUE 230)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const n = 20_000;
    const plain = try reSteps(&f, "a*b", n);
    // Exactly what it says it charges: 20,001 places (the end is one) at
    // `a*b`'s 5 instructions, 4 to compile its 3 bytes, and the call's 4.
    try testing.expectEqual(@as(u64, 20_001 * 5 + 4 + 4), plain);
    for ([_][]const u8{ "(a*)*b", "(a+)+b", "a?a?a?a?a?a*a*a*b", "(a?)*a*b" }) |p| {
        const at_n = try reSteps(&f, p, n);
        const at_4n = try reSteps(&f, p, 4 * n);
        errdefer std.debug.print("/{s}/: {d} steps at {d}, {d} at {d}; a*b {d}\n", .{ p, at_n, n, at_4n, 4 * n, plain });
        // Four times the string, four times the steps, within 1% (a
        // search's end and its compile are a few steps it pays once).
        try testing.expect(at_4n <= 4 * at_n);
        try testing.expect(at_4n * 100 >= 4 * at_n * 99);
    }
    // The loop of a loop, which backtracking takes exponential time over,
    // costs about what `a*b` does: its 9 instructions to 5.
    try testing.expect(try reSteps(&f, "(a*)*b", n) <= 2 * plain);
}
