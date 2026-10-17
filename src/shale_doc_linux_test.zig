//! **SHALE-AGENTS.md'S `shale-linux` BLOCKS, RUN** (metal-vmm QUEUE 234,
//! 3): a block that needs the Linux prelude (`zig_rename`, `run`, git) is
//! fenced `shale-linux`, which the core's doc test (script/agent_test.zig)
//! passes by, and runs here instead: on a small checkout, as a dry run,
//! with the CLI's summary diffs, printing what the doc says it prints (`--
//! prints:`) or stopping as it says (`-- stops: class`).

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");

const Block = struct { line: usize, source: []const u8, prints: ?[]const u8, stops: ?[]const u8 };

fn blocks(a: std.mem.Allocator, doc: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var n: usize = 0;
    var start: ?usize = null;
    var body: std.ArrayList(u8) = .empty;
    while (lines.next()) |line| {
        n += 1;
        if (start == null) {
            if (std.mem.eql(u8, line, "```shale-linux")) start = n;
            continue;
        }
        if (!std.mem.eql(u8, line, "```")) {
            try body.appendSlice(a, line);
            try body.append(a, '\n');
            continue;
        }
        const text = body.items;
        body = .empty;
        defer start = null;
        if (std.mem.indexOf(u8, text, "\n-- stops: ")) |at| {
            try out.append(a, .{ .line = start.?, .source = text[0 .. at + 1], .prints = null, .stops = std.mem.trim(u8, text[at + "\n-- stops: ".len ..], " \n") });
            continue;
        }
        const mark = std.mem.indexOf(u8, text, "-- prints:\n") orelse {
            std.debug.print("docs/SHALE-AGENTS.md:{d}: a shale-linux block with no `-- prints:` or `-- stops:`\n", .{start.?});
            return error.TestUnexpectedResult;
        };
        var want: std.ArrayList(u8) = .empty;
        var rest = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text[mark + "-- prints:\n".len ..], "\n"), '\n');
        while (rest.next()) |l| {
            if (!std.mem.startsWith(u8, l, "-- ")) {
                std.debug.print("docs/SHALE-AGENTS.md:{d}: after `-- prints:`, only `-- ` lines\n", .{start.?});
                return error.TestUnexpectedResult;
            }
            try want.appendSlice(a, l[3..]);
            try want.append(a, '\n');
        }
        try out.append(a, .{ .line = start.?, .source = text[0..mark], .prints = want.items, .stops = null });
    }
    return out.items;
}

/// The checkout: agent_test's two tcp files, and a host that still
/// declares what the move recipe would qualify.
const files = [_][2][]const u8{
    .{ "src/tcp.zig", "//! TCP. The deadlines are in `tcp_timeouts.zig:2`.\nconst timeouts = @import(\"tcp_timeouts.zig\");\npub const pastDeadline = timeouts.pastDeadline;\n" },
    .{ "src/tcp_timeouts.zig", "pub fn pastDeadline(now: u64) bool {\n    return now > 100;\n}\n" },
    .{ "src/linux_host.zig", "pub const kept_write_deadline_ms = 5000;\nfn late(ms: u64) bool {\n    return ms > kept_write_deadline_ms;\n}\n" },
};

test "docs/SHALE-AGENTS.md: every shale-linux block runs with the Linux prelude on a checkout, as a dry run, as the doc says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const doc = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "docs/SHALE-AGENTS.md", a, .limited(1 << 20));
    const all = try blocks(a, doc);
    var wrong: usize = 0;
    for (all) |b| {
        var t: T = undefined;
        try t.init();
        defer t.deinit();
        t.preludes = &.{host_linux.linux_prelude};
        t.diffs = .summary;
        try t.tmp.dir.createDirPath(t.threaded.io(), "src");
        for (files) |f| try t.put(f[0], f[1]);
        var r = t.run(b.source, .dry_run);
        defer r.deinit();
        if (b.stops) |class| {
            if (r.stop == null or !std.mem.eql(u8, @tagName(r.stop.?.class), class)) {
                std.debug.print("docs/SHALE-AGENTS.md:{d}: does not stop as `{s}`\n", .{ b.line, class });
                wrong += 1;
            }
        } else if (r.stop) |s| {
            std.debug.print("docs/SHALE-AGENTS.md:{d}: stopped {d}:{d} {s}: {s}\n", .{ b.line, s.line, s.column, @tagName(s.class), s.message });
            wrong += 1;
        } else if (!std.mem.eql(u8, r.output, b.prints.?)) {
            std.debug.print("docs/SHALE-AGENTS.md:{d}: prints\n{s}-- not --\n{s}", .{ b.line, r.output, b.prints.? });
            wrong += 1;
        }
        // A dry run: the checkout is as it was.
        for (files) |f| try testing.expectEqualStrings(f[1], try t.file(f[0]));
    }
    try testing.expectEqual(@as(usize, 0), wrong);
    try testing.expect(all.len >= 2);
}
