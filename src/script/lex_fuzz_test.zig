//! The lexer's fuzz (the dogfood design: fuzzed first, before long strings
//! went in). Expensive, so out of the gate: `zig build fuzz`.

const std = @import("std");
const testing = std.testing;
const Lexer = @import("lex.zig").Lexer;

test "expensive fuzz: lex: random sources of brackets, `=`, `-`, quotes and newlines end in a token stream or a clean error, never a panic, every place in the source (the design: fuzzed first)" {
    if (!@import("script_test_options").expensive) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(2322);
    const rand = prng.random();
    // Bytes, and the pieces of openers and closers, so long strings and
    // block comments form, nest, cross and end mid-closer.
    const pieces = [_][]const u8{ "[", "]", "=", "-", "\n", "\"", "a", " ", "\\", "\r", "[=[", "]=]", "[==[", "]==]", "--[=[", "--[[", "]]", "--" };
    var buf: [96]u8 = undefined;
    var long_seen: usize = 0;
    for (0..200_000) |_| {
        var len: usize = 0;
        for (0..rand.uintAtMost(usize, 24)) |_| {
            const p = pieces[rand.uintLessThan(usize, pieces.len)];
            if (len + p.len > buf.len) break;
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        const src = buf[0..len];
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), src);
        errdefer std.debug.print("source \"{f}\"\n", .{std.zig.fmtString(src)});
        var last_line: u32 = 1;
        while (true) {
            const t = lx.next() catch {
                const e = lx.err.?;
                try testing.expect(e.line >= 1 and e.line <= last_line + std.mem.count(u8, src, "\n"));
                break;
            };
            try testing.expect(t.line >= last_line);
            last_line = t.line;
            if (t.long != null) long_seen += 1;
            if (t.tag == .eof) break;
        }
    }
    // The alphabet makes long strings, not only errors.
    try testing.expect(long_seen > 100);
}
