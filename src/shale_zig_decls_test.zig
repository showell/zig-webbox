//! **A FILE'S TOP-LEVEL DECLARATIONS, FROM ZIG'S PARSER, TESTED**
//! (metal-vmm QUEUE 235, 1): `zig_decls` over the file the linux_host
//! split began from (`git show 589837e^:src/linux_host.zig`) and over
//! hand-written fixtures for the rest; the pure reader
//! (`shale_zig_ast.decls`) over the repo's own src/**/*.zig.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");
const zig_ast = @import("shale_zig_ast.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{host_linux.linux_prelude};
}

/// Each declaration a row: kind, name, name_form, visibility, linkage,
/// first, last, comment_above (or `-`).
const rows =
    \\for d in zig_decls(arg("p", "a.zig")) do
    \\  local ca = "-"
    \\  if has_key(d, "comment_above") then ca = d.comment_above.first .. "-" .. d.comment_above.last end
    \\  print(d.kind, d.name, d.name_form, d.visibility, d.linkage, d.first, d.last, ca)
    \\end
    \\
;

test "zig_decls: the linux_host split's file: a pub fn with its doc, a struct listed alone, an extern struct's linkage, a test by its string" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.expectOutput(
        \\local r = must(run({"git", "show", "589837e^:src/linux_host.zig"}, {timeout_ms = 30000, whole = 1048576}))
        \\create("lh.zig", r.out)
        \\local seen = {}
        \\for d in zig_decls("lh.zig") do
        \\  seen[d.name] = true
        \\  if d.name == "freeSpaceAt" or d.name == "Hold" or d.name == "Statfs" or starts_with(d.name, "portFrom:") then
        \\    print(d.kind, sub(d.name, 1, 9), d.name_form, d.visibility, d.linkage, d.first, d.last)
        \\  end
        \\end
        \\-- Hold's members are not top-level.
        \\print(has_key(seen, "to"), has_key(seen, "Hold"))
    ,
        "const\tHold\tidentifier\tfile\tnone\t526\t590\n" ++
            "const\tStatfs\tidentifier\tfile\tnone\t1361\t1376\n" ++
            "fn\tfreeSpace\tidentifier\tpub\tnone\t1378\t1393\n" ++
            "test\tportFrom:\tstring\tfile\tnone\t1464\t1472\n" ++
            "false\ttrue\n",
    );
}

test "zig_decls: fixtures: extern and export, a doc comment holding a brace, a test named as a declaration, unnamed ones, a root field, comments above" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("a.zig",
        \\//! The file's own doc: no declaration's.
        \\
        \\/// A { brace, in a doc comment.
        \\const foo = 1;
        \\test foo {}
        \\test {}
        \\test {}
        \\extern fn write(fd: i32) isize;
        \\export fn f() void {}
        \\pub export var v: u8 = 0;
        \\// plain, one
        \\// plain, two
        \\/// doc
        \\pub const b = 2;
        \\// plain, apart
        \\
        \\const c = 3;
        \\comptime {}
        \\x: u8 = 0,
        \\
    );
    try t.expectOutput(
        rows,
        "const\tfoo\tidentifier\tfile\tnone\t3\t4\t-\n" ++
            "test\tfoo\tidentifier\tfile\tnone\t5\t5\t-\n" ++
            "test\t\tnone\tfile\tnone\t6\t6\t-\n" ++
            "test\t\tnone\tfile\tnone\t7\t7\t-\n" ++
            "fn\twrite\tidentifier\tfile\textern\t8\t8\t-\n" ++
            "fn\tf\tidentifier\tfile\texport\t9\t9\t-\n" ++
            "var\tv\tidentifier\tpub\texport\t10\t10\t-\n" ++
            "const\tb\tidentifier\tpub\tnone\t13\t14\t11-12\n" ++
            "const\tc\tidentifier\tfile\tnone\t17\t17\t-\n" ++
            "comptime\t\tnone\tfile\tnone\t18\t18\t-\n" ++
            "field\tx\tidentifier\tpub\tnone\t19\t19\t-\n",
    );
    // start and stop are bytes: `read(p, start, stop - start)` is the
    // declaration, its doc comment first, its `;` or `,` last.
    try t.expectOutput(
        \\for d in zig_decls("a.zig") do
        \\  if d.name == "b" or d.name == "write" or d.name == "x" then print(read("a.zig", d.start, d.stop - d.start)) end
        \\end
    , "extern fn write(fd: i32) isize;\n/// doc\npub const b = 2;\nx: u8 = 0,\n");
}

test "zig_decls: a parse error stops, naming its line, with no list" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("bad.zig", "const a = 1;\nconst = ;\n");
    try t.expectStop("zig_decls(\"bad.zig\")", .atomic, .argument, "line 2");
}

test "zig_decls: a step a token and a node, more for a file four times the size" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    var steps: [2]u64 = undefined;
    for ([_]usize{ 200, 800 }, 0..) |n, k| {
        var src: std.ArrayList(u8) = .empty;
        for (0..n) |i| try src.print(a, "const v{d} = x;\n", .{i});
        try t.put("n.zig", src.items);
        var r = t.run("local d = zig_decls(\"n.zig\")", .atomic);
        defer r.deinit();
        try testing.expect(r.stop == null);
        steps[k] = r.steps;
    }
    // Five tokens and two nodes a line: 600 lines more are 4,200 more.
    if (steps[1] < steps[0] + 7 * 600) {
        std.debug.print("{d} steps at 200 lines, {d} at 800: less than a step a token and a node more\n", .{ steps[0], steps[1] });
        return error.TestUnexpectedResult;
    }
}

test "zig_decls over the repo's own src/**/*.zig: in file order, never overlapping, and between them only whitespace and comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    var files: usize = 0;
    var listed: usize = 0;
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
        const src = try dir.readFileAllocOptions(io, e.path, a, .limited(16 << 20), .of(u8), 0);
        const got = switch (try zig_ast.decls(a, src)) {
            .ok => |ok| ok.decls,
            else => {
                std.debug.print("src/{s} does not parse\n", .{e.path});
                return error.TestUnexpectedResult;
            },
        };
        var at: usize = 0;
        for (got) |d| {
            if (d.start < at or d.stop <= d.start) {
                std.debug.print("src/{s}: `{s}` at {d}..{d} overlaps or is out of order (at {d})\n", .{ e.path, d.name, d.start, d.stop, at });
                return error.TestUnexpectedResult;
            }
            try onlyComments(a, e.path, src[at..d.start]);
            at = d.stop;
        }
        try onlyComments(a, e.path, src[at..]);
        files += 1;
        listed += got.len;
    }
    try testing.expect(files > 80);
    try testing.expect(listed > 2000);
}

/// A gap's tokens: none but a file's own doc comment (`//!`).
fn onlyComments(a: std.mem.Allocator, path: []const u8, gap: []const u8) !void {
    const z = try a.dupeZ(u8, gap);
    var tz = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) return;
        if (t.tag == .container_doc_comment) continue;
        std.debug.print("src/{s}: a gap holds `{s}` ({s})\n", .{ path, z[t.loc.start..t.loc.end], @tagName(t.tag) });
        return error.TestUnexpectedResult;
    }
}
