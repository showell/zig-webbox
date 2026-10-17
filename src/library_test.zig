//! **THE LIBRARY IS THE FILES ITS ROOTS NAME**, checked where the library is
//! changed (the box's essay "checks that stopped checking", 2026-10-17: this
//! lived as a lint in angry-gopher, which no webbox change ran, and was red
//! there for 14 hours). Two roots, `webbox.zig` (portable) and
//! `webbox_linux.zig` (the Linux host), and for each:
//!
//! - every file reachable from it by a relative `@import` is one it names, or
//!   in a folder it names a file of (Shale's `script/`), so membership is said
//!   in one place;
//! - its files import only the modules it may: `std`, `builtin` and `host_io`
//!   for the portable half (and a test's `*_test_options`, which only
//!   webbox's tests provide), and `webbox` too for the Linux half, which reaches
//!   the portable half as that module, never by path; the portable half never
//!   reaches the Linux one;
//! - no file embeds a file, except Shale source beside it (the prelude, which
//!   the library compiles and never serves): what a page serves is the
//!   application's;
//! - every module the root names is in its `test {}` block, so its tests run
//!   (`host_fetch`'s never did);
//! - no file takes `Io` from std (an `Io` declared as std's): on metal it is
//!   `host_io`'s, and std's has no machine under it (the kernel's build
//!   refuses one, zig-metal-unikernel tools/verdicts.py's `STD_IO_ALIAS`).
//!
//! The library's own tests (`*_test.zig`) are recorded, not walked: they may
//! embed what they check and name test options.

const std = @import("std");
const testing = std.testing;
const Io = @import("host_io").Io;

const Root = struct { file: []const u8, may: []const []const u8 };

const roots = [_]Root{
    .{ .file = "webbox.zig", .may = &.{ "std", "builtin", "host_io" } },
    .{ .file = "webbox_linux.zig", .may = &.{ "std", "builtin", "host_io", "webbox" } },
};

/// Every `@import("x")` or `@embedFile("x")` target in `text`, a call split
/// over lines included, one inside a `//` comment left out.
fn refs(a: std.mem.Allocator, text: []const u8, comptime call: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, call ++ "(")) |i| {
        at = i + call.len + 1;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |n| n + 1 else 0;
        if (std.mem.indexOf(u8, text[line_start..i], "//") != null) continue;
        var j = at;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        if (j >= text.len or text[j] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, text, j + 1, '"') orelse continue;
        try out.append(a, text[j + 1 .. end]);
    }
    return out.toOwnedSlice(a);
}

/// `dep` as the library names it: relative to the folder of the file that
/// imports it, `..` and `.` taken out (zig's own rule).
fn resolved(a: std.mem.Allocator, importer: []const u8, dep: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (std.fs.path.dirnamePosix(importer)) |d| {
        var it = std.mem.splitScalar(u8, d, '/');
        while (it.next()) |p| try parts.append(a, p);
    }
    var it = std.mem.splitScalar(u8, dep, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".") or p.len == 0) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0 or std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                try parts.append(a, "..");
            } else _ = parts.pop();
            continue;
        }
        try parts.append(a, p);
    }
    return std.mem.join(a, "/", parts.items);
}

fn isTest(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_test.zig");
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// A file in a folder the root names a file of is the library's too.
fn vouched(dep: []const u8, named: []const []const u8) bool {
    const folder = std.fs.path.dirnamePosix(dep) orelse return false;
    if (std.mem.startsWith(u8, folder, "..")) return false;
    for (named) |n| if (std.fs.path.dirnamePosix(n)) |f| {
        if (std.mem.eql(u8, f, folder)) return true;
    };
    return false;
}

/// The names `pub const NAME = @import("....zig")` in a root.
fn namedModules(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const eq = std.mem.indexOf(u8, line, " = @import(\"") orelse continue;
        if (std.mem.indexOf(u8, line, ".zig\")") == null) continue;
        try out.append(a, line[prefix.len..eq]);
    }
    return out.toOwnedSlice(a);
}

/// What is wrong with the library under `dir`, one line each.
fn problems(io: Io, a: std.mem.Allocator, dir: Io.Dir) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var portable: []const []const u8 = &.{};
    // The Linux root's names, read first: the portable half must not reach them.
    var linux_named: std.ArrayList([]const u8) = .empty;
    if (dir.readFileAlloc(io, roots[1].file, a, .limited(1 << 20))) |lt| {
        for (try refs(a, lt, "@import")) |dep| if (std.mem.endsWith(u8, dep, ".zig") and !isTest(dep)) try linux_named.append(a, dep);
    } else |_| {}
    for (roots, 0..) |root, ri| {
        const text = dir.readFileAlloc(io, root.file, a, .limited(1 << 20)) catch {
            try out.append(a, try std.fmt.allocPrint(a, "{s}: the library's root, and not there", .{root.file}));
            continue;
        };
        var named: std.ArrayList([]const u8) = .empty;
        for (try refs(a, text, "@import")) |dep| if (std.mem.endsWith(u8, dep, ".zig") and !isTest(dep)) try named.append(a, dep);
        for (try refs(a, text, "@import")) |dep| if (!std.mem.endsWith(u8, dep, ".zig") and !contains(root.may, dep))
            try out.append(a, try std.fmt.allocPrint(a, "{s} imports the module {s}, which it may not", .{ root.file, dep }));

        // Every module the root names is in its test block.
        const block = if (std.mem.indexOf(u8, text, "\ntest {")) |b| text[b..] else "";
        for (try namedModules(a, text)) |name| {
            const line = try std.fmt.allocPrint(a, "_ = {s};", .{name});
            if (std.mem.indexOf(u8, block, line) == null)
                try out.append(a, try std.fmt.allocPrint(a, "{s} names {s} but its test block does not: its tests never run", .{ root.file, name }));
        }

        var seen: std.ArrayList([]const u8) = .empty;
        var todo: std.ArrayList([]const u8) = .empty;
        try todo.appendSlice(a, named.items);
        while (todo.pop()) |name| {
            if (contains(seen.items, name)) continue;
            try seen.append(a, name);
            const body = dir.readFileAlloc(io, name, a, .limited(4 << 20)) catch {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: reached from {s}, and not there", .{ name, root.file }));
                continue;
            };
            // Split, so this file is not one the kernel's regex finds.
            for ([_][]const u8{ "const Io = " ++ "std.Io;", "const Io = " ++ "@import(\"std\").Io;" }) |alias| if (std.mem.indexOf(u8, body, alias) != null)
                try out.append(a, try std.fmt.allocPrint(a, "{s} takes Io from std (`{s}`): a library file's Io is host_io's", .{ name, alias }));
            for (try refs(a, body, "@embedFile")) |e| {
                if (std.mem.endsWith(u8, e, ".shale") and std.mem.indexOfScalar(u8, e, '/') == null) continue;
                try out.append(a, try std.fmt.allocPrint(a, "{s} embeds {s}: what a page serves is the application's, not the library's", .{ name, e }));
            }
            for (try refs(a, body, "@import")) |dep| {
                if (!std.mem.endsWith(u8, dep, ".zig")) {
                    // A test's options (`*_test_options`): only webbox's own
                    // test build provides one, so a use outside a test fails
                    // every application's build, loudly.
                    if (std.mem.endsWith(u8, dep, "_test_options")) continue;
                    if (!contains(root.may, dep)) try out.append(a, try std.fmt.allocPrint(a, "{s} imports the module {s}, which {s}'s files may not", .{ name, dep, root.file }));
                    continue;
                }
                const r = try resolved(a, name, dep);
                if (isTest(r)) continue;
                if (ri == 1 and contains(portable, r)) {
                    try out.append(a, try std.fmt.allocPrint(a, "{s} reaches {s} by path: the Linux half imports the portable one as the module `webbox`", .{ name, r }));
                    continue;
                }
                if (ri == 0 and contains(linux_named.items, r)) {
                    try out.append(a, try std.fmt.allocPrint(a, "{s} reaches the Linux half's {s}", .{ name, r }));
                    continue;
                }
                if (!contains(named.items, r) and !vouched(r, named.items))
                    try out.append(a, try std.fmt.allocPrint(a, "{s} imports {s}, which {s} does not name: the library reaches outside itself", .{ name, r, root.file }));
                try todo.append(a, r);
            }
        }
        if (ri == 0) portable = seen.items;
    }
    return out.toOwnedSlice(a);
}

test "library: the files each root reaches, it names; each imports only the modules it may; none embeds a page; every named module's tests run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    var src = try Io.Dir.cwd().openDir(io, "src", .{});
    defer src.close(io);
    const found = try problems(io, arena.allocator(), src);
    for (found) |p| std.debug.print("library: {s}\n", .{p});
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "library: its check finds each kind of mistake, on planted trees" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = struct {
        fn f(d: Io.Dir, name: []const u8, body: []const u8) !void {
            if (std.fs.path.dirnamePosix(name)) |sub| try d.createDirPath(testing.io, sub);
            try d.writeFile(testing.io, .{ .sub_path = name, .data = body });
        }
    }.f;
    const clean_root = "pub const a = @import(\"a.zig\");\npub const s = @import(\"sub/s.zig\");\n\ntest {\n    _ = a;\n    _ = s;\n}\n";
    try w(tmp.dir, "webbox.zig", clean_root);
    try w(tmp.dir, "webbox_linux.zig", "pub const l = @import(\"l.zig\");\n\ntest {\n    _ = l;\n}\n");
    try w(tmp.dir, "a.zig", "const std = @import(\"std\");\nconst p = @embedFile(\"prelude.shale\");\n");
    try w(tmp.dir, "sub/s.zig", "const t = @import(\"t.zig\");\n// const u = @import(\"../users.zig\");\n");
    try w(tmp.dir, "sub/t.zig", "const io = @import(\n    \"host_io\",\n);\n");
    try w(tmp.dir, "l.zig", "const webbox = @import(\"webbox\");\nconst fixture = @import(\"l_test_options\").fixture;\n");
    try testing.expectEqual(@as(usize, 0), (try problems(io, a, tmp.dir)).len);

    const Case = struct { file: []const u8, body: []const u8, says: []const u8 };
    for ([_]Case{
        .{ .file = "sub/t.zig", .body = "const u = @import(\"../users.zig\");\n", .says = "sub/t.zig imports users.zig, which webbox.zig does not name" },
        .{ .file = "sub/t.zig", .body = "const u = @import(\n    \"../users.zig\",\n);\n", .says = "sub/t.zig imports users.zig" },
        .{ .file = "a.zig", .body = "const p = @embedFile(\"chat.js\");\n", .says = "a.zig embeds chat.js" },
        .{ .file = "a.zig", .body = "const p = @embedFile(\"../prelude.shale\");\n", .says = "a.zig embeds ../prelude.shale" },
        .{ .file = "a.zig", .body = "const l = @import(\"webbox_linux\");\n", .says = "a.zig imports the module webbox_linux" },
        .{ .file = "a.zig", .body = "const l = @import(\"l.zig\");\n", .says = "a.zig reaches the Linux half's l.zig" },
        .{ .file = "l.zig", .body = "const a = @import(\"a.zig\");\n", .says = "l.zig reaches a.zig by path" },
        .{ .file = "sub/t.zig", .body = "const std = @import(\"std\");\nconst Io = " ++ "std.Io;\n", .says = "sub/t.zig takes Io from std" },
        .{ .file = "a.zig", .body = "const Io = " ++ "@import(\"std\").Io;\n", .says = "a.zig takes Io from std" },
        .{ .file = "webbox.zig", .body = "pub const a = @import(\"a.zig\");\npub const s = @import(\"sub/s.zig\");\n\ntest {\n    _ = a;\n}\n", .says = "webbox.zig names s but its test block does not" },
    }) |c| {
        const was = try tmp.dir.readFileAlloc(io, c.file, a, .limited(1 << 16));
        try w(tmp.dir, c.file, c.body);
        const found = try problems(io, a, tmp.dir);
        errdefer for (found) |p| std.debug.print("  found: {s}\n", .{p});
        errdefer std.debug.print("planted in {s}, wanted: {s}\n", .{ c.file, c.says });
        try testing.expect(found.len >= 1);
        var hit = false;
        for (found) |p| hit = hit or std.mem.indexOf(u8, p, c.says) != null;
        try testing.expect(hit);
        try w(tmp.dir, c.file, was);
    }
}
