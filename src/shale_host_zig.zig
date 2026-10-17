//! **A RENAME THAT KNOWS ZIG** (metal-vmm QUEUE 234, 3): `zig_rename(path,
//! from, to, opts?)`, the Linux prelude's, over `host("zig_rename", ...)`.
//! Every identifier token `from` (std.zig.Tokenizer's) becomes `to`: never
//! one right after `.` (a field, a declaration reached through a value or
//! a module, an enum literal), never `@"from"` (its bytes are not `from`'s),
//! never in a string, a character or a comment, which are not identifier
//! tokens. **The analysis is tokens, not types**: the compiler judges
//! after. A `to` with a `.` in it where `from` is declared (after `const`,
//! `var` or `fn`, before a `:`, in a capture's `|...|`, an enum's or an
//! error set's member) stops the run, nothing written: `pub const
//! m.from` is the miss it stops. The plan is pure (`plan`), and the run's
//! part writes through core's `rewrite`, a change like any other.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const ast = script.ast;
const Run = script.interp.Run;
const Value = script.value.Value;
const Error = script.interp.Error;
const Tag = std.zig.Token.Tag;

pub const Span = script.builtins_change.Span;

/// Lines, 1-based, inclusive.
pub const Lines = struct { first: usize, last: usize };

/// **WHAT A RENAME WOULD DO**: the file after it, where it changed, what
/// it renamed and what it left in comments (whole words in the gaps
/// between tokens, and in doc comments), and the tokens it read.
pub const Plan = struct { now: []const u8, spans: []const Span, renamed: usize, left_in_comments: usize, tokens: usize };

/// A plan, or the line it stopped at: `declaration`, a qualified `to`
/// where `from` is declared; `invalid`, a token Zig's tokenizer refuses.
pub const Outcome = union(enum) { done: Plan, declaration: usize, invalid: usize };

const Tok = struct { tag: Tag, start: usize, end: usize };

/// **THE RENAME, PLANNED**: pure, over `src`'s tokens.
pub fn plan(a: std.mem.Allocator, src: [:0]const u8, from: []const u8, to: []const u8, lines: ?Lines) error{OutOfMemory}!Outcome {
    var toks: std.ArrayList(Tok) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    var at_line: LineCursor = .{ .src = src };
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .invalid) return .{ .invalid = at_line.lineOf(t.loc.start) };
        try toks.append(a, .{ .tag = t.tag, .start = t.loc.start, .end = t.loc.end });
    }
    const qualified = std.mem.indexOfScalar(u8, to, '.') != null;
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var line: LineCursor = .{ .src = src };
    var copied: usize = 0;
    var gap: usize = 0;
    var renamed: usize = 0;
    var left: usize = 0;
    // Which braces hold an enum's, a union's or an error set's members.
    var braces: std.ArrayList(bool) = .empty;
    var members_next = false;
    var in_capture = false;
    const ts = toks.items;
    for (ts, 0..) |t, i| {
        const prev: ?Tag = if (i > 0) ts[i - 1].tag else null;
        const next: ?Tag = if (i + 1 < ts.len) ts[i + 1].tag else null;
        // The comments between the last token and this one.
        left += try wordsIn(&line, src[gap..t.start], gap, from, lines);
        gap = t.end;
        switch (t.tag) {
            .doc_comment, .container_doc_comment => left += try wordsIn(&line, src[t.start..t.end], t.start, from, lines),
            .keyword_enum, .keyword_union, .keyword_error => members_next = true,
            .l_paren, .r_paren => {},
            .l_brace => {
                try braces.append(a, members_next);
                members_next = false;
            },
            .r_brace => {
                _ = braces.pop();
                members_next = false;
            },
            .pipe => {
                if (in_capture) {
                    in_capture = false;
                } else if (prev != null and (prev.? == .r_paren or prev.? == .keyword_else or prev.? == .keyword_catch) and isCapture(ts[i + 1 ..])) {
                    in_capture = true;
                }
                members_next = false;
            },
            .identifier => if (prev != .period and std.mem.eql(u8, src[t.start..t.end], from)) {
                const n = line.lineOf(t.start);
                if (lines == null or (n >= lines.?.first and n <= lines.?.last)) {
                    const members = braces.items.len > 0 and braces.items[braces.items.len - 1];
                    const declared = prev == .keyword_const or prev == .keyword_var or prev == .keyword_fn or next == .colon or in_capture or
                        (members and (prev == .l_brace or prev == .comma) and (next == .comma or next == .r_brace or next == .equal or next == .colon));
                    if (qualified and declared) return .{ .declaration = n };
                    try out.appendSlice(a, src[copied..t.start]);
                    const c0 = out.items.len;
                    try out.appendSlice(a, to);
                    try spans.append(a, .{ .o0 = t.start, .o1 = t.end, .c0 = c0, .c1 = out.items.len });
                    copied = t.end;
                    renamed += 1;
                }
            },
            else => members_next = false,
        }
    }
    left += try wordsIn(&line, src[gap..], gap, from, lines);
    try out.appendSlice(a, src[copied..]);
    return .{ .done = .{ .now = out.items, .spans = spans.items, .renamed = renamed, .left_in_comments = left, .tokens = ts.len } };
}

/// Whether the tokens after a `|` are a capture's: `[*]name(, [*]name)*|`.
fn isCapture(ts: []const Tok) bool {
    var i: usize = 0;
    while (true) {
        if (i < ts.len and ts[i].tag == .asterisk) i += 1;
        if (i >= ts.len or ts[i].tag != .identifier) return false;
        i += 1;
        if (i < ts.len and ts[i].tag == .pipe) return true;
        if (i >= ts.len or ts[i].tag != .comma) return false;
        i += 1;
    }
}

/// Lines counted forward, for offsets that only grow.
const LineCursor = struct {
    src: []const u8,
    at: usize = 0,
    line: usize = 1,

    fn lineOf(c: *LineCursor, offset: usize) usize {
        c.line += std.mem.count(u8, c.src[c.at..offset], "\n");
        c.at = offset;
        return c.line;
    }
};

/// The whole-word `from`s in `text` (at `base` in the file), in range.
fn wordsIn(line: *LineCursor, text: []const u8, base: usize, from: []const u8, lines: ?Lines) !usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, from)) |k| {
        i = k + 1;
        const end = k + from.len;
        if ((k > 0 and word(text[k - 1])) or (end < text.len and word(text[end]))) continue;
        const l = line.lineOf(base + k);
        if (lines == null or (l >= lines.?.first and l <= lines.?.last)) n += 1;
    }
    return n;
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ── the run's part ───────────────────────────────────────────────────────

/// **`host("zig_rename", path, {from, to}, opts)`**: checked, read, planned,
/// charged (the file `dupeZ`'d for the tokenizer, a step a token), and
/// written through core's `rewrite` when it renames anything.
/// `{renamed, left_in_comments}`.
pub fn rename(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 3) return run.fail(pos, .argument, "`zig_rename` takes a path, `{{from, to}}` and options, given {d}", .{args.len});
    const hub = script.builtins_store;
    const rd = script.builtins_read;
    const p = try hub.pathArg(run, pos, .host, args[0], false);
    const names = switch (args[1]) {
        .table => |t| if (t.kind == .map) t else return run.fail(pos, .type, "`zig_rename`'s names are `{{from, to}}`", .{}),
        else => return run.fail(pos, .type, "`zig_rename`'s names are `{{from, to}}`", .{}),
    };
    const from = try script.builtins.stringArg(run, pos, .host, names.map.get("from") orelse .nil, "`from`");
    const to = try script.builtins.stringArg(run, pos, .host, names.map.get("to") orelse .nil, "`to`");
    if (!std.zig.isValidId(from)) return run.fail(pos, .argument, "`zig_rename`'s `from` (\"{s}\") is not a Zig identifier: one name, not a keyword", .{from});
    var parts = std.mem.splitScalar(u8, to, '.');
    while (parts.next()) |part| if (!std.zig.isValidId(part))
        return run.fail(pos, .argument, "`zig_rename`'s `to` (\"{s}\") is not a Zig identifier, or names joined by `.`", .{to});
    const lines = try linesOpt(run, pos, args[2]);
    try hub.countRead(run, pos);
    const size = try rd.fileSize(run, pos, .host, p);
    const was = (try rd.readSized(run, pos, .host, p, size, 0, null)).string;
    const a = run.alloc;
    const src = a.dupeZ(u8, was) catch return run.oom(pos);
    try script.builtins.chargeBytes(run, pos, src.len);
    const got = plan(a, src, from, to, lines) catch return run.oom(pos);
    const done = switch (got) {
        .done => |d| d,
        .declaration => |n| return run.fail(pos, .argument, "`zig_rename`: {s} declares `{s}` at line {d}, and `{s}` is qualified, which cannot be declared: rename the declaration itself, or leave it out with `lines`; nothing written", .{ p.rel, from, n, to }),
        .invalid => |n| return run.fail(pos, .argument, "`zig_rename`: {s} does not tokenize as Zig at line {d}; nothing written", .{ p.rel, n }),
    };
    try run.charge(pos, done.tokens);
    if (done.renamed > 0) try script.builtins_change.rewrite(run, pos, p, was, done.now, done.spans);
    const t = try run.newTable(pos);
    t.kind = .map;
    t.map.put(a, "renamed", .{ .int = @intCast(done.renamed) }) catch return run.oom(pos);
    t.map.put(a, "left_in_comments", .{ .int = @intCast(done.left_in_comments) }) catch return run.oom(pos);
    return .{ .table = t };
}

fn linesOpt(run: *Run, pos: ast.Pos, v: Value) Error!?Lines {
    const m = switch (v) {
        .nil => return null,
        .table => |t| if (t.kind == .list) return run.fail(pos, .type, "`zig_rename`'s options are a map, not a list", .{}) else t,
        else => return run.fail(pos, .type, "`zig_rename`'s options are a map, not {s}", .{v.typeName()}),
    };
    var got: ?Lines = null;
    for (m.map.keys(), m.map.values()) |k, x| {
        if (!std.mem.eql(u8, k, "lines")) return run.fail(pos, .argument, "`zig_rename` takes `lines`, not `{s}`", .{k});
        const l = switch (x) {
            .table => |t| t,
            else => return run.fail(pos, .argument, "`zig_rename`'s `lines` is `{{first, last}}`", .{}),
        };
        if (l.kind != .list or l.list.items.len != 2 or l.list.items[0] != .int or l.list.items[1] != .int)
            return run.fail(pos, .argument, "`zig_rename`'s `lines` is `{{first, last}}`", .{});
        const first = l.list.items[0].int;
        const last = l.list.items[1].int;
        if (first < 1 or last < first) return run.fail(pos, .argument, "`zig_rename`'s `lines` ({d}, {d}) is no range: 1 <= first <= last", .{ first, last });
        got = .{ .first = @intCast(first), .last = @intCast(last) };
    }
    return got;
}
