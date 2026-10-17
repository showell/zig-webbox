//! **A RENAME THAT KNOWS ZIG, TESTED** (metal-vmm QUEUE 234, 3): the
//! essay's misses each untouched or refused, through the gate; the pure
//! plan (`shale_host_zig.plan`) over the repo's own files, to and back.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");
const zig = @import("shale_host_zig.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{host_linux.linux_prelude};
}

/// What a run printed after its diff: its last line.
fn lastLine(t: *T, src: []const u8, mode: @import("webbox").script.process.Mode) ![]const u8 {
    var r = t.run(src, mode);
    defer r.deinit();
    if (r.stop) |s| {
        std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
        return error.TestUnexpectedResult;
    }
    const out = std.mem.trimEnd(u8, r.output, "\n");
    const at = if (std.mem.lastIndexOfScalar(u8, out, '\n')) |i| i + 1 else 0;
    return t.arena.allocator().dupe(u8, out[at..]);
}

const essay =
    \\const asks = 1;
    \\// asks for a thing, asks twice
    \\/// asks, documented
    \\pub fn f() u32 {
    \\    const w = .asks;
    \\    _ = w;
    \\    return asks + asks2 + foo.asks;
    \\}
    \\test "asks" {
    \\    _ = "asks";
    \\    _ = 'a';
    \\    _ = @"asks";
    \\}
    \\
;

test "zig_rename: identifiers only: not after `.`, not `@\"x\"`, not in strings, a test's name or comments; a longer name is another" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("a.zig", essay);
    try testing.expectEqualStrings("2\t3", try lastLine(&t, "local r = zig_rename(\"a.zig\", \"asks\", \"wants\") print(r.renamed, r.left_in_comments)", .atomic));
    try testing.expectEqualStrings(
        \\const wants = 1;
        \\// asks for a thing, asks twice
        \\/// asks, documented
        \\pub fn f() u32 {
        \\    const w = .asks;
        \\    _ = w;
        \\    return wants + asks2 + foo.asks;
        \\}
        \\test "asks" {
        \\    _ = "asks";
        \\    _ = 'a';
        \\    _ = @"asks";
        \\}
        \\
    , try t.file("a.zig"));
    // The essay's `.watch`: an enum literal is never the variable.
    try t.put("w.zig", "const watch = 1;\nconst x = .watch;\nconst y = watch;\n");
    try testing.expectEqualStrings("2\t0", try lastLine(&t, "local r = zig_rename(\"w.zig\", \"watch\", \"seen\") print(r.renamed, r.left_in_comments)", .atomic));
    try testing.expectEqualStrings("const seen = 1;\nconst x = .watch;\nconst y = seen;\n", try t.file("w.zig"));
    // Nothing to rename: nothing written, and it says 0.
    try testing.expectEqualStrings("0\t0", try lastLine(&t, "local r = zig_rename(\"w.zig\", \"nowhere\", \"x\") print(r.renamed, r.left_in_comments)", .atomic));
}

test "zig_rename: a qualified `to` in a declaration's place stops, naming the line, nothing written; its uses take it" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        // The essay's worst miss.
        .{ "pub const from = 1;\n", "line 1" },
        .{ "const a = 1;\nvar from: u8 = 0;\n", "line 2" },
        .{ "fn from() void {}\n", "line 1" },
        .{ "fn g(from: u8) void {\n    _ = from;\n}\n", "line 1" },
        .{ "const S = struct {\n    from: u8,\n};\n", "line 2" },
        .{ "fn g(o: ?u8) void {\n    if (o) |from| _ = from;\n}\n", "line 2" },
        .{ "fn g(o: []u8) void {\n    for (o) |*from| _ = from;\n}\n", "line 2" },
        .{ "fn g(o: []u8) void {\n    for (o, 0..) |x, from| _ = .{ x, from };\n}\n", "line 2" },
        .{ "const E = enum {\n    a,\n    from,\n};\n", "line 3" },
        .{ "const E = error{ a, from };\n", "line 1" },
    };
    for (cases) |c| {
        try t.put("d.zig", c[0]);
        try t.expectStop("zig_rename(\"d.zig\", \"from\", \"m.from\")", .atomic, .argument, c[1]);
        try testing.expectEqualStrings(c[0], try t.file("d.zig"));
    }
    // Its uses alone: a qualified name is what they become.
    try t.put("u.zig", "const m = @import(\"m.zig\");\nconst x = from + 1;\nfn g() u8 {\n    return from;\n}\n");
    try testing.expectEqualStrings("2\t0", try lastLine(&t, "local r = zig_rename(\"u.zig\", \"from\", \"m.from\") print(r.renamed, r.left_in_comments)", .atomic));
    try testing.expectEqualStrings("const m = @import(\"m.zig\");\nconst x = m.from + 1;\nfn g() u8 {\n    return m.from;\n}\n", try t.file("u.zig"));
}

test "zig_rename: what it refuses: `from` not an identifier, `to` not one or a qualified one, a file that does not tokenize; opts" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("a.zig", "const x = 1;\n");
    try t.expectStop("zig_rename(\"a.zig\", \"a.b\", \"c\")", .atomic, .argument, "`from`");
    try t.expectStop("zig_rename(\"a.zig\", \"const\", \"c\")", .atomic, .argument, "`from`");
    try t.expectStop("zig_rename(\"a.zig\", \"x\", \"1y\")", .atomic, .argument, "`to`");
    try t.expectStop("zig_rename(\"a.zig\", \"x\", \"a..b\")", .atomic, .argument, "`to`");
    try t.expectStop("zig_rename(\"a.zig\", \"x\", \"y\", {line = 1})", .atomic, .argument, "`lines`");
    try t.expectStop("zig_rename(\"a.zig\", \"x\", \"y\", {lines = {2, 1}})", .atomic, .argument, "`lines`");
    try t.put("bad.zig", "const x = 1;\nconst s = \"open\n;\n");
    try t.expectStop("zig_rename(\"bad.zig\", \"x\", \"y\")", .atomic, .argument, "line 2");
    try testing.expectEqualStrings("const x = 1;\nconst s = \"open\n;\n", try t.file("bad.zig"));
}

test "zig_rename: `lines` limits it to a range; a declaration outside it does not stop it" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.put("a.zig", "const a = x;\nconst b = x;\n// x\nconst c = x;\n");
    try testing.expectEqualStrings("1\t1", try lastLine(&t, "local r = zig_rename(\"a.zig\", \"x\", \"y\", {lines = {2, 3}}) print(r.renamed, r.left_in_comments)", .atomic));
    try testing.expectEqualStrings("const a = x;\nconst b = y;\n// x\nconst c = x;\n", try t.file("a.zig"));
    // A declaration outside the range does not stop it.
    try t.put("d.zig", "const x = 1;\nconst b = x;\n");
    try testing.expectEqualStrings("1\t0", try lastLine(&t, "local r = zig_rename(\"d.zig\", \"x\", \"m.x\", {lines = {2, 2}}) print(r.renamed, r.left_in_comments)", .atomic));
    try testing.expectEqualStrings("const x = 1;\nconst b = m.x;\n", try t.file("d.zig"));
}

test "zig_rename: a step a token, more for a file four times the size (a name not there: no diff's charge)" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    var steps: [2]u64 = undefined;
    for ([_]usize{ 200, 800 }, 0..) |n, k| {
        var src: std.ArrayList(u8) = .empty;
        for (0..n) |i| try src.print(a, "const v{d} = x;\n", .{i});
        try t.put("n.zig", src.items);
        var r = t.run("zig_rename(\"n.zig\", \"absent\", \"y\")", .atomic);
        defer r.deinit();
        try testing.expect(r.stop == null);
        steps[k] = r.steps;
    }
    // Five tokens a line: 600 lines more are 3,000 tokens more.
    if (steps[1] < steps[0] + 5 * 600) {
        std.debug.print("{d} steps at 200 lines, {d} at 800: less than a step a token more\n", .{ steps[0], steps[1] });
        return error.TestUnexpectedResult;
    }
}

test "zig_rename's plan, over the repo's own src/*.zig: renaming a name to one not in the file and back gives the file it began with" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var files: usize = 0;
    var renamed: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        const src = try dir.readFileAllocOptions(io, e.name, ar, .limited(16 << 20), .of(u8), 0);
        for ([_][]const u8{ "a", "std", "run", "pos", "self" }) |from| {
            const away = "zz_renamed_away";
            if (std.mem.indexOf(u8, src, away) != null) continue;
            const there = switch (try zig.plan(ar, src, from, away, null)) {
                .done => |p| p,
                else => return error.TestUnexpectedResult,
            };
            const z = try ar.dupeZ(u8, there.now);
            const back = switch (try zig.plan(ar, z, away, from, null)) {
                .done => |p| p,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, back.now, src)) {
                std.debug.print("src/{s}: `{s}` there and back is not the file\n", .{ e.name, from });
                return error.TestUnexpectedResult;
            }
            try testing.expectEqual(there.renamed, back.renamed);
            renamed += there.renamed;
        }
        files += 1;
    }
    try testing.expect(files > 50);
    try testing.expect(renamed > 1000);
}
