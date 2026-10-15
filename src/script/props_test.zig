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
