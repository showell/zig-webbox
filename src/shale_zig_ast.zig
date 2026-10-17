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
                if (fp.name_token) |t| d.name = tree.tokenSlice(t) else d.name_form = .none;
                if (fp.visib_token != null) d.visibility = .@"pub";
                if (fp.extern_export_inline_token) |t| d.linkage = linkageOf(tree.tokenTag(t));
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const vd = tree.fullVarDecl(n).?;
                d.kind = if (tree.tokenTag(vd.ast.mut_token) == .keyword_const) .@"const" else .@"var";
                d.name = tree.tokenSlice(vd.ast.mut_token + 1);
                if (vd.visib_token != null) d.visibility = .@"pub";
                if (vd.extern_export_token) |t| d.linkage = linkageOf(tree.tokenTag(t));
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
        d.start = tree.tokenStart(first);
        d.stop = tree.tokenStart(last) + tree.tokenSlice(last).len;
        d.first = lineOf(starts, d.start);
        d.last = lineOf(starts, d.stop - 1);
        d.comment_above = commentAbove(src, starts, d.first);
        try out.append(a, d);
    }
    return .{ .ok = .{ .decls = out.items, .tokens = tree.tokens.len, .nodes = tree.nodes.len } };
}

fn linkageOf(tag: std.zig.Token.Tag) @FieldType(Decl, "linkage") {
    return switch (tag) {
        .keyword_extern => .@"extern",
        .keyword_export => .@"export",
        else => .none,
    };
}

/// Where each line starts: `starts[i]` is line `i + 1`'s first byte.
fn lineStarts(a: std.mem.Allocator, src: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(a, 0);
    for (src, 0..) |c, i| if (c == '\n') try out.append(a, i + 1);
    return out.items;
}

/// The line, 1-based, of the byte at `offset`.
fn lineOf(starts: []const usize, offset: usize) usize {
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
