//! **THE ADVERSARY**: random and mutated sources, seeded and replayable,
//! each run against a real store with small budgets. Every run must end,
//! finished or stopped: never a Zig panic (the test would crash), never a
//! leak (the backing allocator is `testing.allocator`), never past its
//! output or arena budget, never outside its root. `zig build test
//! -Dscript-fuzz=N` runs N.

const std = @import("std");
const script = @import("script.zig");
const options = @import("script_test_options");
const testing = std.testing;

const corpus = [_][]const u8{
    @embedFile("examples/topics.shale"),
    @embedFile("examples/big_files.shale"),
    @embedFile("examples/delete_topic.shale"),
    "local l = {3, 1, 2} sort(l) for x in l do print(x) end",
    "local m = {a = 1, b = \"x\"} for k in keys(m) do print(k, m[k]) end",
    "function f(n) if n < 2 then return n end return f(n - 1) + f(n - 2) end print(f(15))",
    "local s = \"\" for i = 1, 100 do s = s .. i .. \",\" end print(#split(s, \",\"))",
    "local i = 0 while i < 10 do i = i + 1 if i % 3 == 0 then break end end print(i)",
    "replace(\"f.txt\", \"one\") append(\"f.txt\", \"two\") print(read(\"f.txt\"), stat(\"f.txt\").size)",
    "mkdir(\"a/b\") print(is_dir(\"a\"), exists(\"a/b\")) remove_tree(\"a\")",
    "print(sub(\"hello\", -3, -2), upper(trim(\"  x \")), find(\"abc\", \"c\"), tonumber(\"-12\"))",
    "local t = {} t[1] = 1 t[2] = 2 print(#t, t[1] + t[#t])",
};

/// Pieces a mutation splices in: the language's words and symbols, the
/// extremes of its numbers, and the calls that reach for what they must not.
const fragments = [_][]const u8{
    "local ",     " = ",      "if ",       " then ",    " else ",     " elseif ",   " end ",     "while ",
    " do ",       "for ",     " in ",      "function ", "return ",    "break ",     " and ",     " or ",
    "not ",       "nil",      "true",      "false",     "(",          ")",          "{",         "}",
    "[",          "]",        ",",         ".",         "..",         "#",          "+",         "-",
    "*",          "//",       "%",         "==",        "~=",         "<",          "<=",        ">",
    ";",          "x",        "y",         "l",         "m",          "f",          "s",         "i",
    "0",          "1",        "-1",        "9223372036854775807",     "\"str\"",    "\"\"",      "\"a\\nb\"",
    "print(",     "ls(\"\")", "read(\"../auth/secret\")", "remove_tree(\"\")",       "remove_tree(\"..\")",
    "read(\"/etc/passwd\")",  "replace(\"z\", \"v\")",    "append(\"z\", s)",         "push(l, ",  "sort(",
    "keys(m)",    "split(s, \",\")",          "join(l, \"-\")",           "sub(s, ",    "tonumber(", "tostring(",
    "f(f(f(",     "s .. s",   "{{{{",      "))))",      "x = x + 1 ", "while true do ",           "for i = 1, 9223372036854775807 do ",
    "function f(n) return f(n + 1) end f(1) ",          "1.5",        "a:b()",      "...",       "[[x]]",
    "goto x",     "\x00",     "\xff",      "\n",        "--",
};

fn mutate(r: std.Random, alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, src);
    const n = r.intRangeAtMost(usize, 1, 6);
    for (0..n) |_| {
        const at = if (out.items.len == 0) 0 else r.uintLessThan(usize, out.items.len + 1);
        switch (r.uintLessThan(u8, 5)) {
            0 => try out.insertSlice(alloc, at, fragments[r.uintLessThan(usize, fragments.len)]),
            1 => if (out.items.len > 0) {
                const len = @min(r.intRangeAtMost(usize, 1, 20), out.items.len - @min(at, out.items.len));
                out.replaceRangeAssumeCapacity(@min(at, out.items.len), len, &.{});
            },
            2 => if (out.items.len > 1) {
                const from = r.uintLessThan(usize, out.items.len);
                const len = @min(r.intRangeAtMost(usize, 1, 30), out.items.len - from);
                const piece = try alloc.dupe(u8, out.items[from..][0..len]);
                try out.insertSlice(alloc, at, piece);
            },
            3 => if (out.items.len > 0) {
                out.items[@min(at, out.items.len - 1)] = r.int(u8);
            },
            else => try out.insertSlice(alloc, at, fragments[r.uintLessThan(usize, fragments.len)]),
        }
    }
    return out.items;
}

fn soup(r: std.Random, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const n = r.intRangeAtMost(usize, 1, 60);
    for (0..n) |_| try out.appendSlice(alloc, fragments[r.uintLessThan(usize, fragments.len)]);
    return out.items;
}

test "fuzz: every random or mutated source ends, finished or stopped, inside its budgets and its root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDirPath(io, "data/chat/channels/general/sessions");
    try tmp.dir.createDirPath(io, "auth");
    try tmp.dir.writeFile(io, .{ .sub_path = "auth/secret", .data = "s3cret" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data/chat/channels/general/sessions/plans.md", .data = "MSG_plans_1\nfrom: a\ndate: x\n\nhi" });
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    defer testing.allocator.free(root);

    const budgets: script.Budgets = .{ .steps = 20_000, .arena_bytes = 512 * 1024, .depth = 400, .nesting = 120, .output_bytes = 4096, .reads = 200, .read_bytes = 64 * 1024, .changes = 50, .change_bytes = 64 * 1024 };
    var out: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5ca1e);
    const r = prng.random();
    var finished: usize = 0;
    var stopped = std.EnumArray(script.diag.Class, usize).initFill(0);
    for (0..options.fuzz_runs) |run_index| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const src = if (run_index % 4 == 0) try soup(r, arena.allocator()) else try mutate(r, arena.allocator(), corpus[r.uintLessThan(usize, corpus.len)]);
        var result = script.run(io, testing.allocator, root, src, budgets, 0, &out);
        defer result.deinit();
        try testing.expect(result.output.len <= budgets.output_bytes);
        try testing.expect(result.arena_bytes <= budgets.arena_bytes);
        if (result.stop) |s| {
            stopped.getPtr(s.class).* += 1;
            if (s.class == .budget) try testing.expect(s.budget != null);
            try testing.expect(s.line >= 1);
        } else finished += 1;
    }
    // Nothing beside the root changed, whatever ran.
    const secret = try tmp.dir.readFileAlloc(io, "auth/secret", testing.allocator, .unlimited);
    defer testing.allocator.free(secret);
    try testing.expectEqualStrings("s3cret", secret);
    var top = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer top.close(io);
    var it = top.iterate();
    while (try it.next(io)) |e| try testing.expect(std.mem.eql(u8, e.name, "data") or std.mem.eql(u8, e.name, "auth"));
    // The runs reached both ends, and more than syntax.
    try testing.expect(finished > 0);
    try testing.expect(stopped.get(.syntax) + stopped.get(.refused) < options.fuzz_runs);
}

test "fuzz: the same source, store and now give the same output, the same stop and the same effects, byte for byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDirPath(io, "data");
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    defer testing.allocator.free(root);
    const src = "local m = {} for i = 1, 30 do m[\"k\" .. (i * 37 % 11)] = i replace(\"f\" .. (i % 3), tostring(i)) end for k in keys(m) do print(k, m[k], read(\"f\" .. (m[k] % 3))) end remove(\"nope\")";
    var out_a: [4096]u8 = undefined;
    var out_b: [4096]u8 = undefined;
    var a = script.run(io, testing.allocator, root, src, .{}, 7, &out_a);
    defer a.deinit();
    var b = script.run(io, testing.allocator, root, src, .{}, 7, &out_b);
    defer b.deinit();
    try testing.expectEqualStrings(a.output, b.output);
    try testing.expectEqual(a.steps, b.steps);
    try testing.expectEqualStrings(a.stop.?.message, b.stop.?.message);
    try testing.expectEqual(a.effects.len, b.effects.len);
    for (a.effects, b.effects) |x, y| {
        try testing.expectEqualStrings(x.op, y.op);
        try testing.expectEqualStrings(x.path, y.path);
        try testing.expectEqualStrings(x.outcome, y.outcome);
    }
}
