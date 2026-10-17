//! **A ZIG FILE'S `@import`s AND `@embedFile`s, FROM ZIG'S PARSER**
//! (metal-vmm QUEUE 235, 3): the one reading library_test.zig's rules and
//! Shale's `zig_imports` share, as `edge_sites.parseSites` is shared. A
//! call split over lines is one call, and one in a comment or a string is
//! none: the parser says what is code. Pure: the source in, the calls out.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Kind = enum { import, embed };

/// One call: what it names (its string, unescaped), the declaration it
/// binds when it is that declaration's whole value (`const host_io =`
/// the call, else ""), and its line.
pub const Ref = struct { kind: Kind, target: []const u8, name: []const u8, line: usize };

/// The calls in source order and what reading them took, or the line of
/// the parser's first error.
pub const Refs = union(enum) {
    ok: struct { refs: []const Ref, tokens: usize, nodes: usize },
    parse_error: usize,
};

pub fn refs(a: std.mem.Allocator, src: [:0]const u8) error{OutOfMemory}!Refs {
    const tree = try Ast.parse(a, src, .zig);
    if (tree.errors.len != 0) return .{ .parse_error = tree.tokenLocation(0, tree.errors[0].token).line + 1 };
    // The names: a declaration whose value is the call itself.
    var bound: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (0..tree.nodes.len) |k| {
        const node: Ast.Node.Index = @enumFromInt(k);
        if (node == .root) continue;
        if (tree.fullVarDecl(node)) |vd| if (vd.ast.init_node.unwrap()) |init|
            try bound.put(a, @intFromEnum(init), tree.tokenSlice(vd.ast.mut_token + 1));
    }
    const At = struct { tok: u32, ref: Ref };
    var found: std.ArrayList(At) = .empty;
    for (0..tree.nodes.len) |k| {
        const node: Ast.Node.Index = @enumFromInt(k);
        var buf: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buf, node) orelse continue;
        const main = tree.nodeMainToken(node);
        const call = tree.tokenSlice(main);
        const kind: Kind = if (std.mem.eql(u8, call, "@import")) .import else if (std.mem.eql(u8, call, "@embedFile")) .embed else continue;
        if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) continue;
        const target = std.zig.string_literal.parseAlloc(a, tree.tokenSlice(tree.nodeMainToken(params[0]))) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try found.append(a, .{ .tok = main, .ref = .{
            .kind = kind,
            .target = target,
            .name = bound.get(@intFromEnum(node)) orelse "",
            .line = tree.tokenLocation(0, main).line + 1,
        } });
    }
    std.mem.sort(At, found.items, {}, struct {
        fn lt(_: void, x: At, y: At) bool {
            return x.tok < y.tok;
        }
    }.lt);
    const out = try a.alloc(Ref, found.items.len);
    for (found.items, out) |f, *o| o.* = f.ref;
    return .{ .ok = .{ .refs = out, .tokens = tree.tokens.len, .nodes = tree.nodes.len } };
}

test "zig_refs: each call once, by its string; a name when it is the whole value; a split call one; a comment's or a string's none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The calls spelled in pieces, so a reader of text (angry-gopher's
    // tools/lint_webbox_library.py walks this file) takes none for one.
    const I = "@" ++ "import";
    const E = "@" ++ "embedFile";
    const src = "const std = " ++ I ++ "(\"std\");\n" ++
        "const T = " ++ I ++ "(\"b.zig\").T;\n" ++
        "// const c = " ++ I ++ "(\"c.zig\");\n" ++
        "const s = " ++ I ++ "(\n    \"../top.zig\",\n);\n" ++
        "const doc =\n    \\\\" ++ I ++ "(\"users.zig\")\n;\n" ++
        "const p = " ++ E ++ "(\"pre\\x6Cude.shale\");\n";
    const got = (try refs(arena.allocator(), src)).ok.refs;
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("std", got[0].target);
    try std.testing.expectEqualStrings("std", got[0].name);
    try std.testing.expectEqualStrings("b.zig", got[1].target);
    try std.testing.expectEqualStrings("", got[1].name);
    try std.testing.expectEqual(@as(usize, 4), got[2].line);
    try std.testing.expectEqualStrings("../top.zig", got[2].target);
    try std.testing.expectEqual(Kind.embed, got[3].kind);
    try std.testing.expectEqualStrings("prelude.shale", got[3].target);
    try std.testing.expectEqual(@as(usize, 3), (try refs(arena.allocator(), "const a = 1;\n\nconst = ;\n")).parse_error);
}
