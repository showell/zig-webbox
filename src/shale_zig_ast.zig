//! **ZIG READ BY ZIG'S PARSER** (metal-vmm QUEUE 235): what `zig_decls`
//! (and after it `zig_move` and `zig_imports`) know of a file, from
//! `std.zig.Ast`. Pure: the source in, the answer out. **The analysis is
//! the parser's and its tokens, not types**: the compiler judges after.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Kind = enum { @"fn", @"const", @"var", @"test", @"comptime", field };

/// How a declaration is named: `identifier` (a declaration, a field,
/// `test foo {}`), `string` (`test "..."`, its name the string's text) or
/// `none` (`test {}`, `comptime`, its name `""`).
pub const NameForm = enum { identifier, string, none };

/// Lines, 1-based, inclusive.
pub const Lines = struct { first: usize, last: usize };

/// **A TOP-LEVEL DECLARATION**: its span from its doc comment to the `}`,
/// `;` or (a field's) `,` that ends it, as lines and as bytes (`start`
/// inclusive, `stop` exclusive, from 0), and the plain `//` lines directly
/// above it, if any. A field has no visibility of its own: `pub`.
pub const Decl = struct {
    kind: Kind,
    name: []const u8,
    name_form: NameForm,
    visibility: enum { @"pub", file },
    linkage: enum { none, @"extern", @"export" },
    first: usize,
    last: usize,
    start: usize,
    stop: usize,
    comment_above: ?Lines,
    /// The line its name is on (a test's or a comptime's first token's).
    name_line: usize = 0,
    /// A `const`'s or `var`'s value, as its source says it; else "".
    value: []const u8 = "",
    /// The names of its members that are not `pub`, when its value is a
    /// container (`struct`, `union`, `enum`, `opaque`): what `X.y` from
    /// another file needs `pub` on. Fields have no `pub` and are not here.
    private_members: []const []const u8 = &.{},
};

/// The declarations and what reading them took, or the line of the
/// parser's first error (and its tag): no partial list.
pub const Decls = union(enum) {
    ok: struct { decls: []const Decl, tokens: usize, nodes: usize },
    parse_error: struct { line: usize, tag: []const u8 },
};

/// **A FILE'S TOP-LEVEL DECLARATIONS**, in file order.
pub fn decls(a: std.mem.Allocator, src: [:0]const u8) error{OutOfMemory}!Decls {
    const tree = try Ast.parse(a, src, .zig);
    if (tree.errors.len != 0) {
        const e = tree.errors[0];
        return .{ .parse_error = .{ .line = tree.tokenLocation(0, e.token).line + 1, .tag = @tagName(e.tag) } };
    }
    const starts = try lineStarts(a, src);
    var out: std.ArrayList(Decl) = .empty;
    for (tree.rootDecls()) |n| {
        var d: Decl = .{ .kind = .@"const", .name = "", .name_form = .identifier, .visibility = .file, .linkage = .none, .first = 0, .last = 0, .start = 0, .stop = 0, .comment_above = null };
        switch (tree.nodeTag(n)) {
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                var buf: [1]Ast.Node.Index = undefined;
                const fp = tree.fullFnProto(&buf, n).?;
                d.kind = .@"fn";
                if (fp.name_token) |t| {
                    d.name = tree.tokenSlice(t);
                    d.name_line = lineOf(starts, tree.tokenStart(t));
                } else d.name_form = .none;
                if (fp.visib_token != null) d.visibility = .@"pub";
                if (fp.extern_export_inline_token) |t| d.linkage = linkageOf(tree.tokenTag(t));
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const vd = tree.fullVarDecl(n).?;
                d.kind = if (tree.tokenTag(vd.ast.mut_token) == .keyword_const) .@"const" else .@"var";
                d.name = tree.tokenSlice(vd.ast.mut_token + 1);
                d.name_line = lineOf(starts, tree.tokenStart(vd.ast.mut_token + 1));
                if (vd.visib_token != null) d.visibility = .@"pub";
                if (vd.extern_export_token) |t| d.linkage = linkageOf(tree.tokenTag(t));
                if (vd.ast.init_node.unwrap()) |init| {
                    const last_init = tree.lastToken(init);
                    d.value = src[tree.tokenStart(tree.firstToken(init)) .. tree.tokenStart(last_init) + tree.tokenSlice(last_init).len];
                    d.private_members = try privateMembers(a, &tree, init);
                }
            },
            .test_decl => {
                d.kind = .@"test";
                if (tree.nodeData(n).opt_token_and_node[0].unwrap()) |t| {
                    const s = tree.tokenSlice(t);
                    if (tree.tokenTag(t) == .string_literal) {
                        d.name_form = .string;
                        d.name = s[1 .. s.len - 1];
                    } else d.name = s;
                } else d.name_form = .none;
            },
            .@"comptime" => {
                d.kind = .@"comptime";
                d.name_form = .none;
            },
            .container_field_init, .container_field_align, .container_field => {
                const cf = tree.fullContainerField(n).?;
                d.kind = .field;
                d.visibility = .@"pub";
                d.name = tree.tokenSlice(cf.ast.main_token);
            },
            // The parser gives a file's root nothing else in 0.16.
            else => unreachable,
        }
        // The span: back over its doc comment, on to its `;` or `,`.
        var first = tree.firstToken(n);
        while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
        var last = tree.lastToken(n);
        if (last + 1 < tree.tokens.len) switch (tree.tokenTag(last + 1)) {
            .semicolon => last += 1,
            .comma => if (d.kind == .field) {
                last += 1;
            },
            else => {},
        };
        if (d.name_line == 0) d.name_line = lineOf(starts, tree.tokenStart(tree.firstToken(n)));
        d.start = tree.tokenStart(first);
        d.stop = tree.tokenStart(last) + tree.tokenSlice(last).len;
        d.first = lineOf(starts, d.start);
        d.last = lineOf(starts, d.stop - 1);
        d.comment_above = commentAbove(src, starts, d.first);
        try out.append(a, d);
    }
    return .{ .ok = .{ .decls = out.items, .tokens = tree.tokens.len, .nodes = tree.nodes.len } };
}

/// A container value's members that are not `pub`: declarations and
/// functions, by name.
fn privateMembers(a: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index) ![]const []const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const c = tree.fullContainerDecl(&buf, node) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (c.ast.members) |m| {
        var fb: [1]Ast.Node.Index = undefined;
        if (tree.fullVarDecl(m)) |vd| {
            if (vd.visib_token == null) try out.append(a, tree.tokenSlice(vd.ast.mut_token + 1));
        } else if (tree.fullFnProto(&fb, m)) |fp| {
            if (fp.visib_token == null) if (fp.name_token) |t| try out.append(a, tree.tokenSlice(t));
        }
    }
    return out.items;
}

fn linkageOf(tag: std.zig.Token.Tag) @FieldType(Decl, "linkage") {
    return switch (tag) {
        .keyword_extern => .@"extern",
        .keyword_export => .@"export",
        else => .none,
    };
}

/// Where each line starts: `starts[i]` is line `i + 1`'s first byte.
pub fn lineStarts(a: std.mem.Allocator, src: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(a, 0);
    for (src, 0..) |c, i| if (c == '\n') try out.append(a, i + 1);
    return out.items;
}

/// The line, 1-based, of the byte at `offset`.
pub fn lineOf(starts: []const usize, offset: usize) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= offset) lo = mid else hi = mid;
    }
    return lo + 1;
}

/// The plain `//` lines directly above line `first` (no blank line
/// between, not `///` or `//!`), or null.
fn commentAbove(src: []const u8, starts: []const usize, first: usize) ?Lines {
    var top = first;
    while (top > 1) {
        const l = top - 1;
        const end = if (l < starts.len) starts[l] - 1 else src.len;
        const text = std.mem.trimStart(u8, src[starts[l - 1]..end], " \t");
        if (!std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "///") or std.mem.startsWith(u8, text, "//!")) break;
        top = l;
    }
    return if (top == first) null else .{ .first = top, .last = first - 1 };
}
// ── tokens: the one reading of identifiers ───────────────────────────────

pub const Tag = std.zig.Token.Tag;
pub const Tok = struct { tag: Tag, start: usize, end: usize };

/// A file's tokens, or the line of the first one Zig's tokenizer refuses.
pub fn tokens(a: std.mem.Allocator, src: [:0]const u8) error{OutOfMemory}!union(enum) { ok: []const Tok, invalid: usize } {
    var toks: std.ArrayList(Tok) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .invalid) return .{ .invalid = 1 + std.mem.count(u8, src[0..t.loc.start], "\n") };
        try toks.append(a, .{ .tag = t.tag, .start = t.loc.start, .end = t.loc.end });
    }
    return .{ .ok = toks.items };
}

/// What an identifier token is: a `use` of a name; a `declaration` (after
/// `const`, `var` or `fn`, before a `:` outside a container's own level, in
/// a capture's `|...|`); or a `field`: a nested container's member (its
/// fields, before their `:`; an enum's, a union's or an error set's
/// members; and its own `const`, `var` and `fn` declarations), which may
/// share a top-level name and is never that declaration. (linux_host.zig's
/// `pub const kept_open = &host_file.kept_open;`, in a nested struct.)
pub const Role = enum { use, declaration, field };

pub const Ident = struct { tok: usize, start: usize, end: usize, role: Role };

/// **THE ONE READING OF IDENTIFIERS** (metal-vmm QUEUE 235: `zig_rename`
/// and `zig_move` read with it, and a test holds them to the same
/// answers): every `.identifier` token not right after `.` (a field, a
/// declaration reached through a value or a module, an enum literal), with
/// its role. A local or a parameter cannot shadow a top-level name in Zig,
/// so a matching use or declaration is that declaration's. `@"x"` is its
/// own bytes. Two false declarations, both safe (a rename stops, nothing
/// written): `buf[0..n :0]`'s `n` before the sentinel's `:`, and `(a) | b
/// | c`, read as a capture.
pub fn identifiers(a: std.mem.Allocator, ts: []const Tok) error{OutOfMemory}![]const Ident {
    const Opens = enum { block, container, members };
    const Brace = struct { kind: Opens, parens: usize };
    var out: std.ArrayList(Ident) = .empty;
    var braces: std.ArrayList(Brace) = .empty;
    // What the next `{` opens: a container's after `struct` or `opaque`;
    // members' after `enum`, `union` or `error` (through `(enum)`, `(u8)`).
    var next_brace: Opens = .block;
    var parens: usize = 0;
    var in_capture = false;
    for (ts, 0..) |t, i| {
        const prev: ?Tag = if (i > 0) ts[i - 1].tag else null;
        const next: ?Tag = if (i + 1 < ts.len) ts[i + 1].tag else null;
        switch (t.tag) {
            .keyword_struct, .keyword_opaque => next_brace = .container,
            .keyword_enum, .keyword_union, .keyword_error => next_brace = .members,
            .l_paren => parens += 1,
            .r_paren => parens -|= 1,
            .doc_comment, .container_doc_comment => {},
            .l_brace => {
                try braces.append(a, .{ .kind = next_brace, .parens = parens });
                next_brace = .block;
            },
            .r_brace => {
                _ = braces.pop();
                next_brace = .block;
            },
            .pipe => {
                if (in_capture) {
                    in_capture = false;
                } else if (prev != null and (prev.? == .r_paren or prev.? == .keyword_else or prev.? == .keyword_catch) and isCapture(ts[i + 1 ..])) {
                    in_capture = true;
                }
                next_brace = .block;
            },
            .identifier => if (prev != .period) {
                // The file's root is a container.
                const top: Brace = if (braces.items.len > 0) braces.items[braces.items.len - 1] else .{ .kind = .container, .parens = 0 };
                const level = top.kind != .block and parens == top.parens;
                const member_start = prev == null or switch (prev.?) {
                    .l_brace, .comma, .doc_comment, .container_doc_comment, .semicolon, .r_brace, .keyword_comptime => true,
                    else => false,
                };
                const field = level and member_start and (next == .colon or
                    (top.kind == .members and (next == .comma or next == .r_brace or next == .equal)));
                // `const` names a declaration, unless it qualifies a pointer
                // (`[]const T`, `*const T`, `*align(4) const T`).
                const pointer_const = prev == .keyword_const and i >= 2 and switch (ts[i - 2].tag) {
                    .r_bracket, .asterisk, .asterisk_asterisk, .r_paren, .keyword_allowzero, .keyword_volatile => true,
                    else => false,
                };
                const keyword = (prev == .keyword_const and !pointer_const) or prev == .keyword_var or prev == .keyword_fn;
                // A nested container's own declaration is its member.
                const member_decl = keyword and level and braces.items.len > 0;
                const role: Role = if (field or member_decl) .field else if ((prev == .keyword_const and !pointer_const) or prev == .keyword_var or prev == .keyword_fn or next == .colon or in_capture) .declaration else .use;
                try out.append(a, .{ .tok = i, .start = t.start, .end = t.end, .role = role });
            },
            else => next_brace = .block,
        }
    }
    return out.items;
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
