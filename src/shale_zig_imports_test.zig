//! **A ZIG FILE'S IMPORTS AND EMBEDS, TESTED** (metal-vmm QUEUE 235, 3):
//! `zig_imports` through the gate, on a small tree: each call's target, the
//! declaration it binds, its line, and whether its file is there.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{host_linux.linux_prelude};
}

test "zig_imports: each call, its target, its name, its line; a file found, missing (never passed by) or a module" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    try t.tmp.dir.createDirPath(t.threaded.io(), "sub");
    try t.put("top.zig", "");
    try t.put("sub/b.zig", "");
    try t.put("sub/prelude.shale", "");
    try t.put("sub/a.zig",
        \\const std = @import("std");
        \\const host_io = @import("host_io");
        \\const b = @import("b.zig");
        \\const gone = @import("gone.zig");
        \\const T = @import("b.zig").T;
        \\const p = @embedFile("prelude.shale");
        \\// const c = @import("c.zig");
        \\const s = @import(
        \\    "../top.zig",
        \\);
        \\const page = @embedFile("../missing.html");
        \\
    );
    try t.expectOutput(
        \\for r in zig_imports("sub/a.zig") do print(r.kind, r.target, r.name, r.line, r.file) end
    ,
        "import\tstd\tstd\t1\tmodule\n" ++
            "import\thost_io\thost_io\t2\tmodule\n" ++
            "import\tb.zig\tb\t3\tfound\n" ++
            "import\tgone.zig\tgone\t4\tmissing\n" ++
            "import\tb.zig\t\t5\tfound\n" ++
            "embed\tprelude.shale\tp\t6\tfound\n" ++
            "import\t../top.zig\ts\t8\tfound\n" ++
            "embed\t../missing.html\tpage\t11\tmissing\n",
    );
    try t.put("bad.zig", "const a = 1;\nconst = ;\n");
    try t.expectStop("zig_imports(\"bad.zig\")", .atomic, .argument, "line 2");
}

test "zig_imports: a step a token and a node, more for a file four times the size" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    var steps: [2]u64 = undefined;
    for ([_]usize{ 200, 800 }, 0..) |n, k| {
        var src: std.ArrayList(u8) = .empty;
        for (0..n) |i| try src.print(a, "const v{d} = x;\n", .{i});
        try t.put("n.zig", src.items);
        var r = t.run("local d = zig_imports(\"n.zig\")", .atomic);
        defer r.deinit();
        try testing.expect(r.stop == null);
        steps[k] = r.steps;
    }
    if (steps[1] < steps[0] + 7 * 600) {
        std.debug.print("{d} steps at 200 lines, {d} at 800: less than a step a token and a node more\n", .{ steps[0], steps[1] });
        return error.TestUnexpectedResult;
    }
}

test "zig_decls and zig_imports: a parse lives for its call; the run keeps only what the script is given" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    // A large file of the repo's own, read again and again, as test_roots.shale does.
    try t.put("big.zig", @embedFile("shale_host_linux.zig"));
    const Use = struct {
        fn of(tt: *T, call: []const u8, n: usize) !usize {
            var src: std.ArrayList(u8) = .empty;
            defer src.deinit(testing.allocator);
            try src.print(testing.allocator, "local kept = 0\nfor i = 1, {d} do kept = kept + #{s}(\"big.zig\") end\nprint(kept > 0)", .{ n, call });
            var r = tt.run(src.items, .atomic);
            defer r.deinit();
            if (r.stop) |s| {
                std.debug.print("{s}: {s}\n", .{ call, s.message });
                return error.TestUnexpectedResult;
            }
            return r.arena_bytes;
        }
    };
    const size = @embedFile("shale_host_linux.zig").len;
    for ([_][]const u8{ "zig_decls", "zig_imports" }) |call| {
        const one = try Use.of(&t, call, 1);
        const ten = try Use.of(&t, call, 10);
        // Each call's read, tokens and Ast go when it returns, and the run
        // keeps the list it gave: zig_decls kept about ten times the file a
        // call, and keeps under twice it.
        testing.expect((ten - one) / 9 < 2 * size) catch |e| {
            std.debug.print("{s}: a call keeps {d} bytes of a {d}-byte file\n", .{ call, (ten - one) / 9, size });
            return e;
        };
    }
}
