//! **THE LEXER**: Lua's tokens, and a refusal by name for each of Lua's
//! that this language does not take (a long string without a level, floats, `/`, `:`, `...`,
//! bitwise operators, `goto`, `repeat`).

const std = @import("std");

pub const Tag = enum {
    eof,
    name,
    int,
    string,
    // keywords
    kw_and,
    kw_break,
    kw_const,
    kw_continue,
    kw_do,
    kw_else,
    kw_elseif,
    kw_end,
    kw_false,
    kw_for,
    kw_function,
    kw_if,
    kw_in,
    kw_local,
    kw_nil,
    kw_not,
    kw_or,
    kw_return,
    kw_then,
    kw_true,
    kw_while,
    // symbols
    plus,
    minus,
    star,
    slash_slash,
    percent,
    dot_dot,
    eq_eq,
    not_eq,
    lt,
    le,
    gt,
    ge,
    assign,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    dot,
    hash,
    semicolon,
};

pub const Token = struct {
    tag: Tag,
    /// The source bytes: a name, an int's digits; for a string, its bytes
    /// with escapes undone (owned by the lexer's allocator).
    text: []const u8,
    line: u32,
    column: u32,
    /// An int's value.
    int: i64 = 0,
    /// 9223372036854775808: too big for 64 bits, but the magnitude of the
    /// smallest integer, which a `-` before it makes (the parser's).
    min_magnitude: bool = false,
    /// A long string's level and where its closer is (QUEUE 232): what a
    /// syntax error right after it says.
    long: ?Long = null,
};

pub const Long = struct { level: u32, close_line: u32, close_column: u32 };

pub const Error = struct {
    line: u32,
    column: u32,
    refused: bool,
    message: []const u8,
};

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "and", .kw_and },           .{ "break", .kw_break },       .{ "do", .kw_do },
    .{ "const", .kw_const },       .{ "else", .kw_else },         .{ "elseif", .kw_elseif },
    .{ "continue", .kw_continue }, .{ "end", .kw_end },           .{ "false", .kw_false },
    .{ "for", .kw_for },           .{ "function", .kw_function }, .{ "if", .kw_if },
    .{ "in", .kw_in },             .{ "local", .kw_local },       .{ "nil", .kw_nil },
    .{ "not", .kw_not },           .{ "or", .kw_or },             .{ "return", .kw_return },
    .{ "then", .kw_then },         .{ "true", .kw_true },         .{ "while", .kw_while },
});

/// Lua's words this language refuses, each with why.
const refused_words = std.StaticStringMap([]const u8).initComptime(.{
    .{ "goto", "`goto` is not in this language: `break` and `continue` leave or go round a loop" },
    .{ "repeat", "`repeat ... until` is not in this language: use `while`" },
    .{ "until", "`repeat ... until` is not in this language: use `while`" },
});

pub const Lexer = struct {
    src: []const u8,
    at: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    alloc: std.mem.Allocator,
    err: ?Error = null,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .alloc = alloc };
    }

    fn fail(self: *Lexer, line: u32, column: u32, refused: bool, message: []const u8) error{Lex} {
        self.err = .{ .line = line, .column = column, .refused = refused, .message = message };
        return error.Lex;
    }

    fn failf(self: *Lexer, line: u32, column: u32, refused: bool, comptime fmt: []const u8, args: anytype) error{ Lex, OutOfMemory } {
        return self.fail(line, column, refused, try std.fmt.allocPrint(self.alloc, fmt, args));
    }

    /// A byte shown in a message: quoted when it prints, as `\xHH` when not.
    fn shown(self: *Lexer, b: u8) []const u8 {
        if (std.ascii.isPrint(b)) return std.fmt.allocPrint(self.alloc, "`{c}`", .{b}) catch "";
        return std.fmt.allocPrint(self.alloc, "the byte \\x{X:0>2}", .{b}) catch "";
    }

    fn peekAt(self: *const Lexer, k: usize) u8 {
        return if (self.at + k < self.src.len) self.src[self.at + k] else 0;
    }

    fn bump(self: *Lexer) u8 {
        const c = self.src[self.at];
        self.at += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else self.column += 1;
        return c;
    }

    fn skipSpaceAndComments(self: *Lexer) error{Lex}!void {
        while (self.at < self.src.len) {
            const c = self.src[self.at];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.bump();
            } else if (c == '-' and self.peekAt(1) == '-') {
                if (self.peekAt(2) == '[' and self.peekAt(3) == '[')
                    return self.fail(self.line, self.column, true, "a long comment needs a level: `--[=[ ... ]=]` (code is full of `]]`), or start each line with `--`");
                if (self.peekAt(2) == '[' and self.peekAt(3) == '=') {
                    // **A BLOCK COMMENT** (the design, final): `--` and a
                    // long string's opener; `--[=x` is a line comment.
                    var n: usize = 3;
                    while (self.peekAt(n) == '=') n += 1;
                    if (self.peekAt(n) == '[') {
                        const line = self.line;
                        const column = self.column;
                        _ = self.bump(); // -
                        _ = self.bump(); // -
                        _ = self.bump(); // [
                        _ = self.longString(line, column) catch {
                            const level = n - 3;
                            var closer: [64]u8 = undefined;
                            const message = std.fmt.allocPrint(self.alloc, "a long comment with no `{s}` to close it", .{closerText(&closer, @intCast(level))}) catch "a long comment that is never closed";
                            return self.fail(line, column, false, message);
                        };
                        continue;
                    }
                }
                while (self.at < self.src.len and self.src[self.at] != '\n') _ = self.bump();
            } else return;
        }
    }

    pub fn next(self: *Lexer) error{ Lex, OutOfMemory }!Token {
        try self.skipSpaceAndComments();
        const line = self.line;
        const column = self.column;
        if (self.at >= self.src.len) return .{ .tag = .eof, .text = "", .line = line, .column = column };
        const start = self.at;
        const c = self.src[self.at];

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.at < self.src.len and (std.ascii.isAlphanumeric(self.src[self.at]) or self.src[self.at] == '_')) _ = self.bump();
            const word = self.src[start..self.at];
            if (refused_words.get(word)) |why| return self.fail(line, column, true, why);
            return .{ .tag = keywords.get(word) orelse .name, .text = word, .line = line, .column = column };
        }
        if (std.ascii.isDigit(c)) return self.number(line, column);
        if (c == '"' or c == '\'') return self.string(line, column);

        _ = self.bump();
        const two = self.peekAt(0);
        const tag: Tag = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '%' => .percent,
            '#' => .hash,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ']' => .rbracket,
            ',' => .comma,
            ';' => .semicolon,
            '[' => blk: {
                if (two == '[') return self.fail(line, column, true, "a long string needs a level: `[=[ ... ]=]` (code being edited is full of `]]`)");
                if (two == '=') return self.longString(line, column);
                break :blk .lbracket;
            },
            '/' => blk: {
                if (two == '/') {
                    _ = self.bump();
                    break :blk .slash_slash;
                }
                return self.fail(line, column, true, "`/` divides into a float, and this language has no floats: use `//` (integer division)");
            },
            '.' => blk: {
                if (two == '.') {
                    _ = self.bump();
                    if (self.peekAt(0) == '.') return self.fail(line, column, true, "`...` (varargs) is not in this language");
                    break :blk .dot_dot;
                }
                if (std.ascii.isDigit(two)) return self.fail(line, column, true, "float literals are not in this language: integers only");
                break :blk .dot;
            },
            '=' => blk: {
                if (two == '=') {
                    _ = self.bump();
                    break :blk .eq_eq;
                }
                break :blk .assign;
            },
            '~' => blk: {
                if (two == '=') {
                    _ = self.bump();
                    break :blk .not_eq;
                }
                return self.fail(line, column, true, "bitwise operators (`~`) are not in this language");
            },
            '<' => blk: {
                if (two == '=') {
                    _ = self.bump();
                    break :blk .le;
                }
                if (two == '<') return self.fail(line, column, true, "bitwise operators (`<<`) are not in this language");
                break :blk .lt;
            },
            '>' => blk: {
                if (two == '=') {
                    _ = self.bump();
                    break :blk .ge;
                }
                if (two == '>') return self.fail(line, column, true, "bitwise operators (`>>`) are not in this language");
                break :blk .gt;
            },
            ':' => return self.fail(line, column, true, if (two == ':') "labels (`::name::`) are not in this language" else "`:` method calls are not in this language: call a builtin, `f(x, ...)`"),
            '&', '|' => return self.fail(line, column, true, "bitwise operators are not in this language"),
            '^' => return self.fail(line, column, true, "`^` (exponent) gives a float, and this language has no floats: multiply, `x * x`"),
            else => return self.failf(line, column, false, "a character no token starts with, {s}", .{self.shown(self.src[start])}),
        };
        return .{ .tag = tag, .text = self.src[start..self.at], .line = line, .column = column };
    }

    fn number(self: *Lexer, line: u32, column: u32) error{ Lex, OutOfMemory }!Token {
        const start = self.at;
        if (self.src[self.at] == '0' and (self.peekAt(1) == 'x' or self.peekAt(1) == 'X'))
            return self.fail(line, column, true, "hexadecimal literals are not in this language: write the number in decimal");
        while (self.at < self.src.len and std.ascii.isDigit(self.src[self.at])) _ = self.bump();
        const after = self.peekAt(0);
        if ((after == '.' and self.peekAt(1) != '.') or after == 'e' or after == 'E')
            return self.fail(line, column, true, "float literals are not in this language: integers only");
        if (std.ascii.isAlphabetic(after) or after == '_') return self.fail(line, column, false, "a number runs into a name");
        const text = self.src[start..self.at];
        const value = std.fmt.parseInt(i64, text, 10) catch {
            if (std.mem.eql(u8, text, "9223372036854775808")) return .{ .tag = .int, .text = text, .line = line, .column = column, .int = std.math.minInt(i64), .min_magnitude = true };
            return self.fail(line, column, false, "an integer literal too big for 64 bits: they run from -9223372036854775808 to 9223372036854775807");
        };
        return .{ .tag = .int, .text = text, .line = line, .column = column, .int = value };
    }

    /// **A LONG STRING** (QUEUE 232): `[=[ ... ]=]`, `[==[ ... ]==]`, a
    /// level of one or more `=`, closed by the same level. Its bytes are the
    /// source's, raw (no escapes, a CRLF kept), but for a newline right after
    /// the opener, dropped. Its line and column advance through it, so what
    /// follows is placed right. The `[` is taken.
    fn longString(self: *Lexer, line: u32, column: u32) error{Lex}!Token {
        var level: u32 = 0;
        while (self.peekAt(0) == '=') : (level += 1) _ = self.bump();
        if (self.peekAt(0) != '[') return self.fail(line, column, true, "`[=` opens a long string, `[=[ ... ]=]`: a `[` must follow its `=`s");
        _ = self.bump();
        if (self.peekAt(0) == '\r' and self.peekAt(1) == '\n') {
            _ = self.bump();
            _ = self.bump();
        } else if (self.peekAt(0) == '\n') _ = self.bump();
        const start = self.at;
        while (self.at < self.src.len) {
            if (self.src[self.at] == ']') {
                var n: u32 = 0;
                while (self.peekAt(1 + n) == '=') n += 1;
                if (n == level and self.peekAt(1 + n) == ']') {
                    const text = self.src[start..self.at];
                    const long: Long = .{ .level = level, .close_line = self.line, .close_column = self.column };
                    for (0..level + 2) |_| _ = self.bump();
                    return .{ .tag = .string, .text = text, .line = line, .column = column, .long = long };
                }
            }
            _ = self.bump();
        }
        var closer: [64]u8 = undefined;
        return self.failLong(line, column, closerText(&closer, level));
    }

    fn failLong(self: *Lexer, line: u32, column: u32, closer: []const u8) error{Lex} {
        const message = std.fmt.allocPrint(self.alloc, "a long string with no `{s}` to close it", .{closer}) catch "a long string that is never closed";
        return self.fail(line, column, false, message);
    }

    fn string(self: *Lexer, line: u32, column: u32) error{ Lex, OutOfMemory }!Token {
        const quote = self.bump();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.at >= self.src.len) return self.fail(line, column, false, "a string with no closing quote");
            const c = self.bump();
            if (c == quote) break;
            if (c == '\n') return self.fail(line, column, false, "a string runs past the end of its line: write \\n");
            if (c != '\\') {
                try out.append(self.alloc, c);
                continue;
            }
            if (self.at >= self.src.len) return self.fail(line, column, false, "a string with no closing quote");
            const e_line = self.line;
            const e_col = self.column - 1;
            const e = self.bump();
            try out.append(self.alloc, switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => if (std.ascii.isDigit(self.peekAt(0))) return self.fail(e_line, e_col, true, "decimal escapes (`\\ddd`) are not in this language: write a byte as \\xHH") else 0,
                'x' => blk: {
                    const hi = std.fmt.charToDigit(self.peekAt(0), 16) catch return self.fail(e_line, e_col, false, "`\\x` takes two hexadecimal digits: \\x0a");
                    const lo = std.fmt.charToDigit(self.peekAt(1), 16) catch return self.fail(e_line, e_col, false, "`\\x` takes two hexadecimal digits: \\x0a");
                    _ = self.bump();
                    _ = self.bump();
                    break :blk hi * 16 + lo;
                },
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                '1'...'9' => return self.fail(e_line, e_col, true, "decimal escapes (`\\ddd`) are not in this language: write a byte as \\xHH"),
                'u' => return self.fail(e_line, e_col, true, "`\\u{...}` is not in this language: strings are bytes; write UTF-8's bytes as \\xHH"),
                'z' => return self.fail(e_line, e_col, true, "`\\z` is not in this language: a string ends on its line"),
                else => return self.fail(e_line, e_col, true, "an escape this language does not have: only \\n, \\t, \\r, \\0, \\xHH, \\\\, \\\" and \\'"),
            });
        }
        return .{ .tag = .string, .text = out.items, .line = line, .column = column };
    }
};

/// A long string's closer at `level`, `]==]`, or as much of it as fits.
pub fn closerText(buf: []u8, level: u32) []const u8 {
    const n = @min(level, buf.len - 2);
    buf[0] = ']';
    @memset(buf[1..][0..n], '=');
    buf[n + 1] = ']';
    return buf[0 .. n + 2];
}

/// The opener a level up, `[===[`, or as much of it as fits.
pub fn openerText(buf: []u8, level: u32) []const u8 {
    const n = @min(level, buf.len - 2);
    buf[0] = '[';
    @memset(buf[1..][0..n], '=');
    buf[n + 1] = '[';
    return buf[0 .. n + 2];
}

const testing = std.testing;

fn tags(src: []const u8) ![]Tag {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), src);
    var out: std.ArrayList(Tag) = .empty;
    while (true) {
        const t = try lx.next();
        try out.append(testing.allocator, t.tag);
        if (t.tag == .eof) break;
    }
    return out.toOwnedSlice(testing.allocator);
}

test "lex: names, keywords, integers, strings with their escapes, every symbol, comments" {
    const got = try tags("local x = 12 -- a comment\nif x ~= 3 then print(\"a\\tb\") end // % .. == <= >= < > # [ ] { } , . ;");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Tag, &.{ .kw_local, .name, .assign, .int, .kw_if, .name, .not_eq, .int, .kw_then, .name, .lparen, .string, .rparen, .kw_end, .slash_slash, .percent, .dot_dot, .eq_eq, .le, .ge, .lt, .gt, .hash, .lbracket, .rbracket, .lbrace, .rbrace, .comma, .dot, .semicolon, .eof }, got);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "\"a\\n\\t\\\\\\\"b\" 'c' 9223372036854775807");
    try testing.expectEqualStrings("a\n\t\\\"b", (try lx.next()).text);
    try testing.expectEqualStrings("c", (try lx.next()).text);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try lx.next()).int);
    const e = try lx.next();
    try testing.expectEqual(Tag.eof, e.tag);
    try testing.expectEqual(@as(u32, 1), e.line);
}

test "lex: each Lua construct this language refuses is refused by name, where it stands" {
    const cases = [_]struct { src: []const u8, says: []const u8 }{
        .{ .src = "x = 1.5", .says = "float" },
        .{ .src = "x = .5", .says = "float" },
        .{ .src = "x = 1e3", .says = "float" },
        .{ .src = "x = 0x10", .says = "hexadecimal" },
        .{ .src = "x = a / b", .says = "`//`" },
        .{ .src = "s:upper()", .says = "method" },
        .{ .src = "::top::", .says = "labels" },
        .{ .src = "f(...)", .says = "varargs" },
        .{ .src = "x = [[long]]", .says = "a long string needs a level" },
        .{ .src = "--[[ long\ncomment ]]", .says = "a long comment needs a level" },
        .{ .src = "goto done", .says = "goto" },
        .{ .src = "repeat x = 1 until x", .says = "repeat" },
        .{ .src = "x = a & b", .says = "bitwise" },
        .{ .src = "x = a << 1", .says = "bitwise" },
        .{ .src = "x = ~a", .says = "bitwise" },
        .{ .src = "x = 2 ^ 3", .says = "exponent" },
        .{ .src = "x = \"\\q\"", .says = "escape" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), case.src);
        while (true) {
            const t = lx.next() catch break;
            if (t.tag == .eof) {
                std.debug.print("not refused: {s}\n", .{case.src});
                return error.TestUnexpectedResult;
            }
        }
        const e = lx.err.?;
        try testing.expect(e.refused);
        if (std.mem.indexOf(u8, e.message, case.says) == null) {
            std.debug.print("{s}: {s}\n", .{ case.src, e.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "lex: plain errors: an unclosed string, a string across a line, a number too big, a stray character; each with its line and column" {
    const cases = [_]struct { src: []const u8, line: u32, column: u32 }{
        .{ .src = "x = \"abc", .line = 1, .column = 5 },
        .{ .src = "\n  x = \"a\nb\"", .line = 2, .column = 7 },
        .{ .src = "x = 99999999999999999999", .line = 1, .column = 5 },
        .{ .src = "x = 1 @", .line = 1, .column = 7 },
        .{ .src = "x = 12ab", .line = 1, .column = 5 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), case.src);
        while (true) {
            const t = lx.next() catch break;
            try testing.expect(t.tag != .eof);
        }
        const e = lx.err.?;
        try testing.expect(!e.refused);
        try testing.expectEqual(case.line, e.line);
        try testing.expectEqual(case.column, e.column);
    }
}

test "lex: long strings, a level of `=` each (QUEUE 232): `]]` and a lower closer inside, the first newline dropped, bytes raw, the lines after placed right" {
    const cases = [_]struct { src: []const u8, text: []const u8 }{
        .{ .src = "[=[a]]b]=]", .text = "a]]b" },
        .{ .src = "[==[x ]=] y]]]==]", .text = "x ]=] y]]" },
        .{ .src = "[===[]==]]===]", .text = "]==]" },
        // The first newline after the opener is dropped; one before the
        // closer is the string's.
        .{ .src = "[=[\nline one\nline two\n]=]", .text = "line one\nline two\n" },
        // Raw: no escapes, and a CRLF is its two bytes.
        .{ .src = "[=[a\\n\"b\r\nc]=]", .text = "a\\n\"b\r\nc" },
        .{ .src = "[=[]=]", .text = "" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), case.src);
        const t = try lx.next();
        try testing.expectEqual(Tag.string, t.tag);
        try testing.expectEqualStrings(case.text, t.text);
        try testing.expectEqual(Tag.eof, (try lx.next()).tag);
    }
    // A token after a long string of three lines is on its own line.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "x = [=[\none\ntwo]=] y\nz");
    _ = try lx.next();
    _ = try lx.next();
    const s = try lx.next();
    try testing.expectEqual(@as(u32, 1), s.line);
    try testing.expectEqual(@as(u32, 5), s.column);
    try testing.expectEqual(@as(u32, 3), s.long.?.close_line);
    try testing.expectEqual(@as(u32, 4), s.long.?.close_column);
    const y = try lx.next();
    try testing.expectEqual(@as(u32, 3), y.line);
    try testing.expectEqual(@as(u32, 8), y.column);
    try testing.expectEqual(@as(u32, 4), (try lx.next()).line);
}

test "lex: a long string that is never closed, or an opener that is not one, is an error at the opener" {
    for ([_]struct { src: []const u8, says: []const u8 }{
        .{ .src = "x = [=[abc]]", .says = "with no `]=]` to close it" },
        .{ .src = "x = [==[abc]=]", .says = "with no `]==]` to close it" },
        .{ .src = "x = [=a", .says = "`[=` opens a long string" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), case.src);
        _ = try lx.next();
        _ = try lx.next();
        try testing.expectError(error.Lex, lx.next());
        errdefer std.debug.print("{s}: {s}\n", .{ case.src, lx.err.?.message });
        try testing.expect(std.mem.indexOf(u8, lx.err.?.message, case.says) != null);
        try testing.expectEqual(@as(u32, 5), lx.err.?.column);
    }
}

test "lex: a block comment is `--` and a long string's opener, any level (the design, final): what it holds is passed by, the lines after placed right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "x --[=[ a ]] b\n c ]=] y --[==[ ]=] ]==]\nz --[=x is a line comment\nw --[ too\nv");
    for ([_]struct { []const u8, u32, u32 }{ .{ "x", 1, 1 }, .{ "y", 2, 8 }, .{ "z", 3, 1 }, .{ "w", 4, 1 }, .{ "v", 5, 1 } }) |want| {
        const t = try lx.next();
        try testing.expectEqualStrings(want[0], t.text);
        try testing.expectEqual(want[1], t.line);
        try testing.expectEqual(want[2], t.column);
    }
    try testing.expectEqual(Tag.eof, (try lx.next()).tag);
    // Never closed: an error at the comment's start.
    var bad = Lexer.init(arena.allocator(), "x = 1\n  --[=[ never closed ]]");
    _ = try bad.next();
    _ = try bad.next();
    _ = try bad.next();
    try testing.expectError(error.Lex, bad.next());
    try testing.expectEqual(@as(u32, 2), bad.err.?.line);
    try testing.expectEqual(@as(u32, 3), bad.err.?.column);
    try testing.expect(std.mem.indexOf(u8, bad.err.?.message, "a long comment with no `]=]`") != null);
}
