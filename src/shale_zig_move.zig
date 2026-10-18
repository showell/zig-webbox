//! **DECLARATIONS MOVED BETWEEN FILES, AND WHAT THE MOVE BROKE**
//! (metal-vmm QUEUE 235, 2): `zig_move`'s pure part. The declarations are
//! `zig_decls`'s (shale_zig_ast.zig) and the uses are the one reading of
//! identifiers (`za.identifiers`, `zig_rename`'s too). **The analysis is
//! Zig's parser and its tokens, not types**: a method called through a
//! value (`progress.end(.deadline)`) and a name reached through an
//! `@This()` alias are not reported, and the compiler finds both. A local
//! or a parameter cannot shadow a top-level name in Zig, so a name that
//! matches is that declaration or a use of it.

const std = @import("std");
const za = @import("shale_zig_ast.zig");

/// `was[o0..o1]` became `now[c0..c1]` (core's `Span`, field for field).
pub const Span = struct { o0: usize, o1: usize, c0: usize, c1: usize };

/// A declaration to move: by name, and by kind when a name is two
/// (`test foo {}` and `const foo`).
pub const Want = struct { name: []const u8, kind: ?za.Kind = null };

/// What goes with a declaration: its doc comment (`doc`), or that and the
/// plain `//` lines directly above it (`doc_and_plain`).
pub const CommentMode = enum { doc, doc_and_plain };

pub const NameLine = struct { name: []const u8, line: usize };

/// An import the moved code uses: its name, and its value as `from` says
/// it (`@import("std")`, `std.Io.net`), so `const name = target;` copies it.
pub const ImportNeed = struct { name: []const u8, target: []const u8, line: usize };

pub const Moved = struct {
    from_now: []const u8,
    from_spans: []const Span,
    to_now: []const u8,
    to_spans: []const Span,
    moved: usize,
    /// Moved declarations `from` still uses that are not `pub`, at their
    /// name's line; and members `X.y` of a moved `X` that `from` names and
    /// that are not `pub`, at their first use.
    needs_pub: []const NameLine,
    needs_import: []const ImportNeed,
    /// Other top-level declarations of `from` the moved code uses.
    needs_from_from: []const NameLine,
    /// Each line of `from` that still names a moved declaration.
    uses_left: []const NameLine,
    /// The tokens and Ast nodes read, of both files: the charge.
    work: usize,
};

/// The move, or why it stops with nothing written.
pub const Outcome = union(enum) { done: Moved, refused: []const u8 };

fn ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Where a declaration ends for a move: its `;` or `}`, or the end of a
/// `//` comment on its last line (`const b = 2; // why`), which is its own.
/// A `///` there is the next declaration's doc comment, not this one's.
fn endWithComment(src: []const u8, stop: usize) usize {
    var i = stop;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    if (!std.mem.startsWith(u8, src[i..], "//")) return stop;
    if (std.mem.startsWith(u8, src[i..], "///") and !std.mem.startsWith(u8, src[i..], "////")) return stop;
    while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
    return i;
}

fn refuse(a: std.mem.Allocator, comptime f: []const u8, args: anytype) error{OutOfMemory}!Outcome {
    return .{ .refused = try std.fmt.allocPrint(a, f, args) };
}

/// **THE MOVE, PLANNED**: `wants` cut from `from` (each with the
/// whitespace after it, up to the next token or comment, so one blank
/// line stays where it was between two others, and none at the end of the
/// file) and put in `to` in `from`'s order, one blank line between each
/// and before the first: at the end, or after the declaration `after`.
/// How `file`'s lines end: CRLF when its first does, else LF; a file with
/// no line yet ends them as `other` does.
fn newline(file: []const u8, other: []const u8) []const u8 {
    const in = if (std.mem.indexOfScalar(u8, file, '\n') != null) file else other;
    const at = std.mem.indexOfScalar(u8, in, '\n') orelse return "\n";
    return if (at > 0 and in[at - 1] == '\r') "\r\n" else "\n";
}

pub fn move(a: std.mem.Allocator, from: [:0]const u8, to: [:0]const u8, wants: []const Want, mode: CommentMode, after: ?[]const u8) error{OutOfMemory}!Outcome {
    const fd = switch (try za.decls(a, from)) {
        .ok => |ok| ok,
        .parse_error => |e| return refuse(a, "`from` does not parse as Zig: line {d} ({s})", .{ e.line, e.tag }),
    };
    const td = switch (try za.decls(a, to)) {
        .ok => |ok| ok,
        .parse_error => |e| return refuse(a, "`to` does not parse as Zig: line {d} ({s})", .{ e.line, e.tag }),
    };
    // **WHAT TO MOVE**: each name once, found once.
    const picked = try a.alloc(bool, fd.decls.len);
    @memset(picked, false);
    for (wants) |w| {
        if (w.name.len == 0) return refuse(a, "a declaration with no name (`test {{}}`, `comptime`) cannot be named, so it cannot be moved", .{});
        var found: usize = 0;
        var count: usize = 0;
        for (fd.decls, 0..) |d, i| {
            if (d.name_form == .none or !std.mem.eql(u8, d.name, w.name)) continue;
            if (w.kind) |k| if (d.kind != k) continue;
            count += 1;
            found = i;
        }
        if (count == 0) return refuse(a, "`{s}`{s} is not a top-level declaration of `from`; nothing written", .{ w.name, if (w.kind != null) " of that kind" else "" });
        if (count > 1) return refuse(a, "`{s}` names {d} declarations of `from`: say which, `{{kind = ..., name = \"{s}\"}}`; nothing written", .{ w.name, count, w.name });
        if (picked[found]) return refuse(a, "`{s}` is named twice; nothing written", .{w.name});
        picked[found] = true;
    }
    // **THE CUTS**, in file order, adjacent ones joined.
    const starts = try za.lineStarts(a, from);
    const Cut = struct { s: usize, e: usize };
    var cuts: std.ArrayList(Cut) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    for (fd.decls, 0..) |d, i| if (picked[i]) {
        var s = d.start;
        if (mode == .doc_and_plain) if (d.comment_above) |c| {
            s = starts[c.first - 1];
        };
        const stop = endWithComment(from, d.stop);
        var e = stop;
        while (e < from.len and ws(from[e])) e += 1;
        try texts.append(a, from[s..stop]);
        // A cut that starts at or before the last one's end joins it: the
        // last one's whitespace ran up to an indented comment this one takes.
        if (cuts.items.len > 0 and s <= cuts.items[cuts.items.len - 1].e) {
            const last = &cuts.items[cuts.items.len - 1];
            last.e = @max(last.e, e);
        } else try cuts.append(a, .{ .s = s, .e = e });
    };
    // A cut to the file's end takes the whitespace before it too, and the
    // file keeps one newline (none, if nothing is left).
    var tail_repl: []const u8 = "";
    if (cuts.items.len > 0 and cuts.items[cuts.items.len - 1].e == from.len) {
        const c = &cuts.items[cuts.items.len - 1];
        while (c.s > 0 and ws(from[c.s - 1])) c.s -= 1;
        if (c.s > 0) tail_repl = newline(from, from);
    }
    var out: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var copied: usize = 0;
    for (cuts.items, 0..) |c, ci| {
        try out.appendSlice(a, from[copied..c.s]);
        const c0 = out.items.len;
        if (ci == cuts.items.len - 1 and c.e == from.len) try out.appendSlice(a, tail_repl);
        try spans.append(a, .{ .o0 = c.s, .o1 = c.e, .c0 = c0, .c1 = out.items.len });
        copied = c.e;
    }
    try out.appendSlice(a, from[copied..]);

    // **WHERE THEY GO**, between lines ended as `to`'s are.
    const nl = newline(to, from);
    const gap = try std.mem.concat(a, u8, &.{ nl, nl });
    const block = try std.mem.join(a, gap, texts.items);
    var to_now: []const u8 = undefined;
    var to_span: Span = undefined;
    if (after) |name| {
        var at: usize = 0;
        var n: usize = 0;
        for (td.decls) |d| if (d.name_form != .none and std.mem.eql(u8, d.name, name)) {
            n += 1;
            at = endWithComment(to, d.stop);
        };
        if (n == 0) return refuse(a, "`after`: `{s}` is not a top-level declaration of `to`; nothing written", .{name});
        if (n > 1) return refuse(a, "`after`: `{s}` names {d} declarations of `to`; nothing written", .{ name, n });
        to_now = try std.mem.concat(a, u8, &.{ to[0..at], gap, block, to[at..] });
        to_span = .{ .o0 = at, .o1 = at, .c0 = at, .c1 = at + gap.len + block.len };
    } else {
        const t = std.mem.trimEnd(u8, to, " \t\r\n");
        to_now = if (t.len == 0) try std.mem.concat(a, u8, &.{ block, nl }) else try std.mem.concat(a, u8, &.{ t, gap, block, nl });
        to_span = .{ .o0 = t.len, .o1 = to.len, .c0 = t.len, .c1 = to_now.len };
    }

    // **WHAT THE MOVE BROKE**, read from `from` as it was.
    const ts = switch (try za.tokens(a, from)) {
        .ok => |ok| ok,
        .invalid => |n| return refuse(a, "`from` does not tokenize as Zig at line {d}", .{n}),
    };
    const ids = try za.identifiers(a, ts);
    var moved_names: std.StringHashMapUnmanaged(usize) = .empty;
    var staying: std.StringHashMapUnmanaged(usize) = .empty;
    for (fd.decls, 0..) |d, i| {
        if (d.name_form == .none or d.kind == .@"test") continue;
        if (picked[i]) try moved_names.put(a, d.name, i) else try staying.put(a, d.name, i);
    }
    // The imports that stay: `@import(...)`, then what names a part of one
    // (`std.Io.net`), until no more are found.
    var imports: std.StringHashMapUnmanaged([]const u8) = .empty;
    var grew = true;
    while (grew) {
        grew = false;
        for (fd.decls, 0..) |d, i| {
            if (picked[i] or d.kind != .@"const" or imports.contains(d.name)) continue;
            const v = d.value;
            // (Split, so library_test's reader of imports passes it by.)
            const is_import = std.mem.startsWith(u8, v, "@" ++ "import(") or (chain(v) and imports.contains(v[0 .. std.mem.indexOfScalar(u8, v, '.') orelse v.len]));
            if (is_import) {
                try imports.put(a, d.name, v);
                grew = true;
            }
        }
    }
    var needs_import: std.ArrayList(ImportNeed) = .empty;
    var needs_from_from: std.ArrayList(NameLine) = .empty;
    var uses_left: std.ArrayList(NameLine) = .empty;
    var members: std.ArrayList(NameLine) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (ids) |id| {
        if (id.role != .use) continue;
        const name = from[id.start..id.end];
        const line = za.lineOf(starts, id.start);
        if (inMoved(fd.decls, picked, id.start)) {
            if (moved_names.contains(name)) continue;
            if (imports.get(name)) |target| {
                if ((try seen.getOrPut(a, try key(a, "i", name, 0))).found_existing) continue;
                try needs_import.append(a, .{ .name = name, .target = target, .line = line });
            } else if (staying.contains(name)) {
                if ((try seen.getOrPut(a, try key(a, "f", name, 0))).found_existing) continue;
                try needs_from_from.append(a, .{ .name = name, .line = line });
            }
            continue;
        }
        const i = moved_names.get(name) orelse continue;
        if (!(try seen.getOrPut(a, try key(a, "u", name, line))).found_existing) try uses_left.append(a, .{ .name = name, .line = line });
        // `X.y`, a member of a moved `X` that is not `pub`.
        if (id.tok + 2 < ts.len and ts[id.tok + 1].tag == .period and ts[id.tok + 2].tag == .identifier) {
            const y = from[ts[id.tok + 2].start..ts[id.tok + 2].end];
            for (fd.decls[i].private_members) |m| if (std.mem.eql(u8, m, y)) {
                const full = try std.fmt.allocPrint(a, "{s}.{s}", .{ name, y });
                if (!(try seen.getOrPut(a, try key(a, "m", full, 0))).found_existing) try members.append(a, .{ .name = full, .line = line });
            };
        }
    }
    // **AN IMPORT NAMED THROUGH ANOTHER** (`const Bus = streams.Bus;`)
    // needs that one too, and so on to an `@import` (angry-gopher router.zig's
    // search tests named `Bus` and `Hub` and never `streams`).
    var k: usize = 0;
    while (k < needs_import.items.len) : (k += 1) {
        const need = needs_import.items[k];
        if (!chain(need.target)) continue;
        const head = need.target[0..std.mem.indexOfScalar(u8, need.target, '.').?];
        const target = imports.get(head) orelse continue;
        if ((try seen.getOrPut(a, try key(a, "i", head, 0))).found_existing) continue;
        try needs_import.append(a, .{ .name = head, .target = target, .line = need.line });
    }
    var needs_pub: std.ArrayList(NameLine) = .empty;
    for (fd.decls, 0..) |d, i| if (picked[i] and d.visibility == .file) {
        for (uses_left.items) |u| if (std.mem.eql(u8, u.name, d.name)) {
            try needs_pub.append(a, .{ .name = d.name, .line = d.name_line });
            break;
        };
    };
    try needs_pub.appendSlice(a, members.items);
    var moved: usize = 0;
    for (picked) |p| moved += @intFromBool(p);
    return .{ .done = .{
        .from_now = out.items,
        .from_spans = spans.items,
        .to_now = to_now,
        .to_spans = try a.dupe(Span, &.{to_span}),
        .moved = moved,
        .needs_pub = needs_pub.items,
        .needs_import = needs_import.items,
        .needs_from_from = needs_from_from.items,
        .uses_left = uses_left.items,
        .work = fd.tokens + fd.nodes + td.tokens + td.nodes + ts.len,
    } };
}

/// Whether `v` is names joined by `.`: `std.Io.net`.
fn chain(v: []const u8) bool {
    if (std.mem.indexOfScalar(u8, v, '.') == null) return false;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |part| if (!std.zig.isValidId(part)) return false;
    return true;
}

fn inMoved(ds: []const za.Decl, picked: []const bool, at: usize) bool {
    for (ds, 0..) |d, i| if (picked[i] and at >= d.start and at < d.stop) return true;
    return false;
}

fn key(a: std.mem.Allocator, kind: []const u8, name: []const u8, line: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{d}", .{ kind, name, line });
}
