//! **NOTHING IN THE MODULE NAMES THE HOST** (metal-vmm QUEUE 199): each of
//! its sources, read as text, refused anything that reaches past `host_io`
//! and the caller's allocator, outside `test` blocks and outside the
//! `*_test.zig` files (which run only on the Linux host's tests).

const std = @import("std");

const sources = .{
    .{ "script.zig", @embedFile("script.zig") },
    .{ "diag.zig", @embedFile("diag.zig") },
    .{ "ast.zig", @embedFile("ast.zig") },
    .{ "lex.zig", @embedFile("lex.zig") },
    .{ "parse.zig", @embedFile("parse.zig") },
    .{ "value.zig", @embedFile("value.zig") },
    .{ "interp.zig", @embedFile("interp.zig") },
    .{ "builtins.zig", @embedFile("builtins.zig") },
    .{ "builtins_store.zig", @embedFile("builtins_store.zig") },
    .{ "builtins_text.zig", @embedFile("builtins_text.zig") },
    .{ "builtins_lists.zig", @embedFile("builtins_lists.zig") },
    .{ "builtins_time.zig", @embedFile("builtins_time.zig") },
    .{ "builtins_format.zig", @embedFile("builtins_format.zig") },
    .{ "builtins_numbers.zig", @embedFile("builtins_numbers.zig") },
};

/// What a portable file may not name: the file system but its path
/// helpers, the OS, processes, threads, the clock, a host's own Io or
/// allocator, and printing past the run's own output.
const refused = [_][]const u8{
    "std.posix", "std.os",   "std.c.",         "std.process",     "std.Thread", "std.time",
    "Io.Dir",    "Threaded", "page_allocator", "std.debug.print",
};

/// The first refused name in `text` outside its `test` blocks, with its
/// line; `std.fs.` is refused too, except `std.fs.path`.
pub fn violation(text: []const u8) ?struct { line: usize, name: []const u8 } {
    var in_test = false;
    var depth: i32 = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        if (!in_test and std.mem.startsWith(u8, std.mem.trimStart(u8, code, " "), "test ")) {
            in_test = true;
            depth = 0;
        }
        if (in_test) {
            for (code) |ch| {
                if (ch == '{') depth += 1;
                if (ch == '}') depth -= 1;
            }
            if (depth <= 0 and std.mem.indexOfScalar(u8, code, '}') != null) in_test = false;
            continue;
        }
        for (refused) |r| if (std.mem.indexOf(u8, code, r) != null) return .{ .line = line_no, .name = r };
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, code, at, "std.fs.")) |i| : (at = i + 1) {
            if (!std.mem.startsWith(u8, code[i..], "std.fs.path")) return .{ .line = line_no, .name = "std.fs." };
        }
    }
    return null;
}

test "the script module names no host: nothing past host_io and the caller's allocator, outside its tests" {
    inline for (sources) |s| {
        if (violation(s[1])) |v| {
            std.debug.print("{s}:{d} names `{s}`\n", .{ s[0], v.line, v.name });
            return error.TestUnexpectedResult;
        }
    }
}

test "the check fires on each refused name, planted, and not on one in a test block or a comment" {
    for (refused ++ [_][]const u8{"std.fs."}) |r| {
        var buf: [256]u8 = undefined;
        const planted = try std.fmt.bufPrint(&buf, "const x = 1;\nconst y = {s}something;\n", .{r});
        try std.testing.expect(violation(planted) != null);
    }
    try std.testing.expect(violation("const p = std.fs.path.join;\n") == null);
    try std.testing.expect(violation("// std.posix is not used\nconst a = 1;\n") == null);
    try std.testing.expect(violation("test \"x\" {\n    var t = std.Io.Threaded.init(a, .{});\n    _ = std.time;\n}\nconst b = 2;\n") == null);
    try std.testing.expect(violation("test \"x\" {\n}\nconst c = std.posix.fd_t;\n") != null);
}

test "the list above is every source of the module: a new file is checked too (builtins_v31.zig was missed once)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, "src/script", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |en| {
        if (en.kind != .file or !std.mem.endsWith(u8, en.name, ".zig") or std.mem.endsWith(u8, en.name, "_test.zig")) continue;
        var listed = false;
        inline for (sources) |s| listed = listed or std.mem.eql(u8, s[0], en.name);
        if (!listed) {
            std.debug.print("src/script/{s} is not in portable_test.zig's sources\n", .{en.name});
            return error.TestUnexpectedResult;
        }
    }
}
