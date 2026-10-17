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

const za = @import("shale_zig_ast.zig");

/// **THE RENAME, PLANNED**: pure, over `src`'s tokens and the one reading
/// of identifiers (`za.identifiers`, which `zig_move` reads with too).
pub fn plan(a: std.mem.Allocator, src: [:0]const u8, from: []const u8, to: []const u8, lines: ?Lines) error{OutOfMemory}!Outcome {
    const ts = switch (try za.tokens(a, src)) {
        .ok => |ok| ok,
        .invalid => |n| return .{ .invalid = n },
    };
    const qualified = std.mem.indexOfScalar(u8, to, '.') != null;
    const starts = try za.lineStarts(a, src);
    // The comments: the gaps between tokens, and the doc comments.
    var line: LineCursor = .{ .src = src };
    var left: usize = 0;
    var gap: usize = 0;
    for (ts) |t| {
        left += try wordsIn(&line, src[gap..t.start], gap, from, lines);
        gap = t.end;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) left += try wordsIn(&line, src[t.start..t.end], t.start, from, lines);
    }
    left += try wordsIn(&line, src[gap..], gap, from, lines);
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var copied: usize = 0;
    var renamed: usize = 0;
    for (try za.identifiers(a, ts)) |id| {
        if (!std.mem.eql(u8, src[id.start..id.end], from)) continue;
        const n = za.lineOf(starts, id.start);
        if (lines != null and (n < lines.?.first or n > lines.?.last)) continue;
        // A field of that name is another thing: never renamed.
        if (id.role == .field) continue;
        if (qualified and id.role == .declaration) return .{ .declaration = n };
        try out.appendSlice(a, src[copied..id.start]);
        const c0 = out.items.len;
        try out.appendSlice(a, to);
        try spans.append(a, .{ .o0 = id.start, .o1 = id.end, .c0 = c0, .c1 = out.items.len });
        copied = id.end;
        renamed += 1;
    }
    try out.appendSlice(a, src[copied..]);
    return .{ .done = .{ .now = out.items, .spans = spans.items, .renamed = renamed, .left_in_comments = left, .tokens = ts.len } };
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

/// **`host("zig_decls", path)`**: a Zig file's top-level declarations, from
/// Zig's parser (shale_zig_ast.zig), as maps, in file order. Charged: the
/// read, the `dupeZ`, a step a token and a step an Ast node. A parse error
/// stops, naming its first line.
pub fn decls(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 1) return run.fail(pos, .argument, "`zig_decls` takes a path, given {d} arguments", .{args.len});
    const hub = script.builtins_store;
    const rd = script.builtins_read;
    const p = try hub.pathArg(run, pos, .host, args[0], false);
    try hub.countRead(run, pos);
    const size = try rd.fileSize(run, pos, .host, p);
    const was = (try rd.readSized(run, pos, .host, p, size, 0, null)).string;
    const a = run.alloc;
    const src = a.dupeZ(u8, was) catch return run.oom(pos);
    try script.builtins.chargeBytes(run, pos, src.len);
    const got = switch (za.decls(a, src) catch return run.oom(pos)) {
        .ok => |ok| ok,
        .parse_error => |e| return run.fail(pos, .argument, "`zig_decls`: {s} does not parse as Zig: line {d} ({s})", .{ p.rel, e.line, e.tag }),
    };
    try run.charge(pos, got.tokens + got.nodes);
    const list = try run.newTable(pos);
    list.kind = .list;
    for (got.decls) |d| {
        const m = try run.newTable(pos);
        m.kind = .map;
        try put(run, pos, m, "kind", .{ .string = @tagName(d.kind) });
        try put(run, pos, m, "name", .{ .string = d.name });
        try put(run, pos, m, "name_form", .{ .string = @tagName(d.name_form) });
        try put(run, pos, m, "visibility", .{ .string = @tagName(d.visibility) });
        try put(run, pos, m, "linkage", .{ .string = @tagName(d.linkage) });
        try put(run, pos, m, "first", .{ .int = @intCast(d.first) });
        try put(run, pos, m, "last", .{ .int = @intCast(d.last) });
        try put(run, pos, m, "start", .{ .int = @intCast(d.start) });
        try put(run, pos, m, "stop", .{ .int = @intCast(d.stop) });
        if (d.comment_above) |c| {
            const cm = try run.newTable(pos);
            cm.kind = .map;
            try put(run, pos, cm, "first", .{ .int = @intCast(c.first) });
            try put(run, pos, cm, "last", .{ .int = @intCast(c.last) });
            try put(run, pos, m, "comment_above", .{ .table = cm });
        }
        list.list.append(a, .{ .table = m }) catch return run.oom(pos);
    }
    return .{ .table = list };
}

/// A Zig file read whole and NUL-ended for the parser, the read and the
/// copy charged; null for one that is not there, when that is allowed.
fn readZig(run: *Run, pos: ast.Pos, p: script.builtins_store.Path, missing_ok: bool) Error!?[:0]const u8 {
    const hub = script.builtins_store;
    try hub.countRead(run, pos);
    if (missing_ok) {
        const st = webbox.store.statOrNull(run.io, run.alloc, p.full) catch |e| return hub.storeFailed(run, pos, .host, p.rel, e);
        if (st == null) return null;
    }
    const size = try script.builtins_read.fileSize(run, pos, .host, p);
    const was = (try script.builtins_read.readSized(run, pos, .host, p, size, 0, null)).string;
    const src = run.alloc.dupeZ(u8, was) catch return run.oom(pos);
    try script.builtins.chargeBytes(run, pos, src.len);
    return src;
}

fn put(run: *Run, pos: ast.Pos, t: *script.value.Table, k: []const u8, v: Value) Error!void {
    t.map.put(run.alloc, k, v) catch return run.oom(pos);
}

/// `{name, line}` maps, a list (`{name, target, line}` with a target).
fn nameLines(run: *Run, pos: ast.Pos, items: anytype) Error!Value {
    const list = try run.newTable(pos);
    list.kind = .list;
    for (items) |x| {
        const m = try run.newTable(pos);
        m.kind = .map;
        try put(run, pos, m, "name", .{ .string = x.name });
        if (@hasField(@TypeOf(x), "target")) try put(run, pos, m, "target", .{ .string = x.target });
        try put(run, pos, m, "line", .{ .int = @intCast(x.line) });
        list.list.append(run.alloc, .{ .table = m }) catch return run.oom(pos);
    }
    return .{ .table = list };
}

/// **`host("zig_move", from, to, {names, opts})`**: top-level declarations
/// moved from one Zig file to another (shale_zig_move.zig), and what the
/// move broke. `to` may be missing: it is made. `to` is written first and
/// `from` after, each through core's `rewrite`, so a stop between them
/// leaves the declarations in both, never in neither. Charged: the reads,
/// the copies, a step a token and a node of both files.
pub fn move(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const zm = @import("shale_zig_move.zig");
    if (args.len != 3) return run.fail(pos, .argument, "`zig_move` takes `from`, `to` and `{{names, opts}}`, given {d}", .{args.len});
    const hub = script.builtins_store;
    const a = run.alloc;
    const p = try hub.pathArg(run, pos, .host, args[0], false);
    const q = try hub.pathArg(run, pos, .host, args[1], false);
    if (std.mem.eql(u8, p.full, q.full)) return run.fail(pos, .argument, "`zig_move`: `from` and `to` are one file", .{});
    const packed_args = switch (args[2]) {
        .table => |t| if (t.kind == .map) t else return run.fail(pos, .type, "`zig_move`'s names are a list", .{}),
        else => return run.fail(pos, .type, "`zig_move`'s names are a list", .{}),
    };
    const names = switch (packed_args.map.get("names") orelse Value.nil) {
        .table => |t| if (t.kind == .list) t else return run.fail(pos, .type, "`zig_move`'s names are a list of names, or `{{kind = ..., name = ...}}`", .{}),
        else => return run.fail(pos, .type, "`zig_move`'s names are a list of names, or `{{kind = ..., name = ...}}`", .{}),
    };
    var wants: std.ArrayList(zm.Want) = .empty;
    for (names.list.items) |v| switch (v) {
        .string => |s| wants.append(a, .{ .name = s }) catch return run.oom(pos),
        .table => |t| {
            if (t.kind != .map) return run.fail(pos, .type, "`zig_move`: a name is a string, or `{{kind = ..., name = ...}}`", .{});
            var w: zm.Want = .{ .name = "" };
            for (t.map.keys(), t.map.values()) |k, x| {
                const s = switch (x) {
                    .string => |s| s,
                    else => return run.fail(pos, .type, "`zig_move`: a name's `{s}` is a string", .{k}),
                };
                if (std.mem.eql(u8, k, "name")) {
                    w.name = s;
                } else if (std.mem.eql(u8, k, "kind")) {
                    w.kind = std.meta.stringToEnum(za.Kind, s) orelse return run.fail(pos, .argument, "`zig_move`: no kind `{s}`: fn, const, var, test, comptime or field", .{s});
                } else return run.fail(pos, .argument, "`zig_move`: a name takes `kind` and `name`, not `{s}`", .{k});
            }
            wants.append(a, w) catch return run.oom(pos);
        },
        else => return run.fail(pos, .type, "`zig_move`: a name is a string, or `{{kind = ..., name = ...}}`", .{}),
    };
    if (wants.items.len == 0) return run.fail(pos, .argument, "`zig_move`: no names: nothing to move", .{});
    var mode: zm.CommentMode = .doc;
    var after: ?[]const u8 = null;
    switch (packed_args.map.get("opts") orelse Value.nil) {
        .nil => {},
        .table => |t| for (t.map.keys(), t.map.values()) |k, x| {
            const s = switch (x) {
                .string => |s| s,
                else => return run.fail(pos, .type, "`zig_move`'s `{s}` is a string", .{k}),
            };
            if (std.mem.eql(u8, k, "comment")) {
                mode = std.meta.stringToEnum(zm.CommentMode, s) orelse return run.fail(pos, .argument, "`zig_move`'s `comment` is \"doc\" or \"doc_and_plain\", not \"{s}\"", .{s});
            } else if (std.mem.eql(u8, k, "after")) {
                after = s;
            } else return run.fail(pos, .argument, "`zig_move` takes `comment` and `after`, not `{s}`", .{k});
        },
        else => |v| return run.fail(pos, .type, "`zig_move`'s options are a map, not {s}", .{v.typeName()}),
    }
    const from_src = (try readZig(run, pos, p, false)).?;
    const to_src = (try readZig(run, pos, q, true)) orelse "";
    const done = switch (zm.move(a, from_src, to_src, wants.items, mode, after) catch return run.oom(pos)) {
        .done => |d| d,
        .refused => |why| return run.fail(pos, .argument, "`zig_move` {s} to {s}: {s}", .{ p.rel, q.rel, why }),
    };
    try run.charge(pos, done.work);
    // Both files may change, or neither is written.
    try script.builtins_change.mayChange(run, pos, q);
    try script.builtins_change.mayChange(run, pos, p);
    const spans = struct {
        fn of(r: *Run, ps: ast.Pos, xs: []const zm.Span) Error![]const Span {
            const out = r.alloc.alloc(Span, xs.len) catch return r.oom(ps);
            for (xs, out) |x, *o| o.* = .{ .o0 = x.o0, .o1 = x.o1, .c0 = x.c0, .c1 = x.c1 };
            return out;
        }
    }.of;
    try script.builtins_change.rewrite(run, pos, q, to_src, done.to_now, try spans(run, pos, done.to_spans));
    try script.builtins_change.rewrite(run, pos, p, from_src, done.from_now, try spans(run, pos, done.from_spans));
    const t = try run.newTable(pos);
    t.kind = .map;
    try put(run, pos, t, "moved", .{ .int = @intCast(done.moved) });
    try put(run, pos, t, "needs_pub", try nameLines(run, pos, done.needs_pub));
    try put(run, pos, t, "needs_import", try nameLines(run, pos, done.needs_import));
    try put(run, pos, t, "needs_from_from", try nameLines(run, pos, done.needs_from_from));
    try put(run, pos, t, "uses_left", try nameLines(run, pos, done.uses_left));
    return .{ .table = t };
}

/// **`host("zig_imports", path)`**: a Zig file's `@import`s and
/// `@embedFile`s, from Zig's parser (webbox's zig_refs.zig, library_test's
/// reading too), in source order: `{kind, target, name, line, file}`, the
/// file `found` or `missing` beside the importer, or a `module` (a target
/// with no extension). Charged: the read, the copy, a step a token and a
/// node, and a step a call for its look at the file.
pub fn imports(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 1) return run.fail(pos, .argument, "`zig_imports` takes a path, given {d} arguments", .{args.len});
    const a = run.alloc;
    const p = try script.builtins_store.pathArg(run, pos, .host, args[0], false);
    const src = (try readZig(run, pos, p, false)).?;
    const got = switch (webbox.zig_refs.refs(a, src) catch return run.oom(pos)) {
        .ok => |ok| ok,
        .parse_error => |line| return run.fail(pos, .argument, "`zig_imports`: {s} does not parse as Zig: line {d}", .{ p.rel, line }),
    };
    try run.charge(pos, got.tokens + got.nodes + got.refs.len);
    const dir = std.fs.path.dirnamePosix(p.full) orelse ".";
    const list = try run.newTable(pos);
    list.kind = .list;
    for (got.refs) |r| {
        const file: []const u8 = if (std.fs.path.extension(r.target).len == 0) "module" else file: {
            const full = std.fs.path.resolvePosix(a, &.{ dir, r.target }) catch return run.oom(pos);
            const st = webbox.store.statOrNull(run.io, a, full) catch |e| return script.builtins_store.storeFailed(run, pos, .host, r.target, e);
            break :file if (st != null) "found" else "missing";
        };
        const m = try run.newTable(pos);
        m.kind = .map;
        try put(run, pos, m, "kind", .{ .string = @tagName(r.kind) });
        try put(run, pos, m, "target", .{ .string = r.target });
        try put(run, pos, m, "name", .{ .string = r.name });
        try put(run, pos, m, "line", .{ .int = @intCast(r.line) });
        try put(run, pos, m, "file", .{ .string = file });
        list.list.append(a, .{ .table = m }) catch return run.oom(pos);
    }
    return .{ .table = list };
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
