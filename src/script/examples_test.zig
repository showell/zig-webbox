//! The example scripts, run against a store shaped like angry-gopher's
//! data (chat_paths.zig, chat_store.zig, chat_retire.zig).

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

const topics = @embedFile("examples/topics.shale");
const big_files = @embedFile("examples/big_files.shale");
const delete_topic = @embedFile("examples/delete_topic.shale");
const where_the_bytes_are = @embedFile("examples/where_the_bytes_are.shale");
const chat_topics = @embedFile("examples/chat_topics.shale");
const first_change = @embedFile("examples/first_change.shale");

const sep = "\n\n-------------\n";

fn transcript(alloc: std.mem.Allocator, sid: []const u8, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (1..n + 1) |i| {
        if (i > 1) try out.appendSlice(alloc, sep);
        try out.print(alloc, "MSG_{s}_{d}\nfrom: steve\ndate: 2026-10-13T12:00:00Z\n\nmessage {d}, a line of it\nand another", .{ sid, i, i });
    }
    return out.items;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        const io = self.threaded.io();
        const d = self.tmp.dir;
        for ([_][]const u8{ "data/chat/1_2/sessions", "data/chat/channels/general/sessions/plans.uploads", "data/chat/channels/random/sessions", "data/games" }) |p| try d.createDirPath(io, p);
        const files = [_]struct { path: []const u8, sid: []const u8, n: usize }{
            .{ .path = "data/chat/1_2/sessions/hello.md", .sid = "hello", .n = 3 },
            .{ .path = "data/chat/channels/general/sessions/plans.md", .sid = "plans", .n = 40 },
            .{ .path = "data/chat/channels/general/sessions/lunch.md", .sid = "lunch", .n = 1 },
            .{ .path = "data/chat/channels/random/sessions/misc.md", .sid = "misc", .n = 2 },
        };
        for (files) |f| try d.writeFile(io, .{ .sub_path = f.path, .data = try transcript(a, f.sid, f.n) });
        try d.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/hello.count", .data = "3\n" });
        try d.writeFile(io, .{ .sub_path = "data/chat/channels/general/sessions/plans.count", .data = "40\n" });
        try d.writeFile(io, .{ .sub_path = "data/chat/channels/general/sessions/plans.reactions.jsonl", .data = "{}\n" });
        try d.writeFile(io, .{ .sub_path = "data/chat/channels/general/sessions/plans.uploads/1.png", .data = "png" });
        try d.writeFile(io, .{ .sub_path = "data/chat/channels/general.channel", .data = "1\n2\n" });
        try d.writeFile(io, .{ .sub_path = "data/games/big.json", .data = "x" ** 5000 });
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, src: []const u8, out: []u8) script.Result {
        return self.runAt(src, 0, out);
    }

    fn runAt(self: *Fixture, src: []const u8, now: i64, out: []u8) script.Result {
        return script.run(self.threaded.io(), testing.allocator, self.root, src, .{}, now, out);
    }
};

var out_buf: [16 * 1024]u8 = undefined;

fn finished(r: *const script.Result) !void {
    if (r.stop) |s| {
        std.debug.print("stopped {d}:{d} {s}: {s}\n", .{ s.line, s.column, @tagName(s.class), s.message });
        return error.TestUnexpectedResult;
    }
}

test "example: every topic with its message count" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run(topics, &out_buf);
    defer r.deinit();
    try finished(&r);
    try testing.expectEqualStrings("1_2\thello\t3\n#general\tlunch\t1\n#general\tplans\t40\n#random\tmisc\t2\ntopics\t4\n", r.output);
    try testing.expectEqual(@as(usize, 0), r.effects.len);
}

test "example: files over a size" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run(big_files, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expect(std.mem.indexOf(u8, r.output, "chat/channels/general/sessions/plans.md") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "5000\tgames/big.json") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "lunch.md") == null);
    try testing.expect(std.mem.endsWith(u8, r.output, "files over 1000 bytes:\t2\n"));
}

test "example: delete one topic, its sidecars and uploads with it, every change in the effects log" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run(delete_topic, &out_buf);
    defer r.deinit();
    try finished(&r);
    const want = [_][2][]const u8{
        .{ "remove", "chat/channels/general/sessions/plans.md" },
        .{ "remove", "chat/channels/general/sessions/plans.count" },
        .{ "remove", "chat/channels/general/sessions/plans.reactions.jsonl" },
        .{ "remove_tree", "chat/channels/general/sessions/plans.uploads" },
    };
    try testing.expectEqual(want.len, r.effects.len);
    for (r.effects, want) |e, w| {
        try testing.expectEqualStrings(w[0], e.op);
        try testing.expectEqualStrings(w[1], e.path);
        try testing.expectEqualStrings("ok", e.outcome);
    }
    // The other topics stay; the topics script now sees three.
    var again = f.run(topics, &out_buf);
    defer again.deinit();
    try finished(&again);
    try testing.expect(std.mem.endsWith(u8, again.output, "topics\t3\n"));
    // And run twice, the second finds nothing to delete, and says so.
    var twice = f.run(delete_topic, &out_buf);
    defer twice.deinit();
    try finished(&twice);
    try testing.expectEqual(@as(usize, 0), twice.effects.len);
    try testing.expect(std.mem.startsWith(u8, twice.output, "no such topic"));
}

// ── 204(a)'s three scripts, in v31's builtins (metal-vmm QUEUE 206) ──────

test "example: where the bytes are, folder by folder, then the largest files" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run(where_the_bytes_are, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expectEqual(@as(usize, 0), r.effects.len);
    // The folders, the biggest first, then all of them.
    try testing.expect(std.mem.startsWith(u8, r.output, "folder  files  bytes  size     empty\n"));
    try testing.expect(std.mem.indexOf(u8, r.output, "\nchat        9  ") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\ngames       1   5000  4.9 KiB      0\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\nall        10  ") != null);
    // The largest: games/big.json, then the 40-message transcript.
    try testing.expect(std.mem.indexOf(u8, r.output, "the largest files:\nbytes  size     path\n 5000  4.9 KiB  games/big.json\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "chat/channels/general/sessions/plans.md") != null);
}

test "example: chat topics by messages, the quiet ones, the caches that disagree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A count cache that lies, for the last section.
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/chat/channels/general/sessions/plans.count", .data = "39\n" });
    // 2027-02-02: the transcripts' 2026-10-13 is more than 90 days before.
    var r = f.runAt(chat_topics, 1801526400, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expectEqual(@as(usize, 0), r.effects.len);
    try testing.expect(std.mem.startsWith(u8, r.output, "topics\t4\tmessages\t46\tbytes\t"));
    try testing.expect(std.mem.indexOf(u8, r.output, "topic           messages  bytes  last\n#general plans        40   4166  2026-10-13T12:00:00Z\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "quiet for 90 days (since 2026-11-04T00:00:00Z): 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "count caches that disagree: 1\ntopic           transcript  cache\n#general plans          40     39\n") != null);
    // The same run on the transcripts' own day: none is quiet.
    var today = f.runAt(chat_topics, 1791936000, &out_buf);
    defer today.deinit();
    try finished(&today);
    try testing.expect(std.mem.indexOf(u8, today.output, "): 0\n") != null);
}

test "example: the first change makes one folder and one file, and says what the last run wrote" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.runAt(first_change, 1791936000, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expectEqual(@as(usize, 2), r.effects.len);
    try testing.expectEqualStrings("mkdir", r.effects[0].op);
    try testing.expectEqualStrings("shale-check", r.effects[0].path);
    try testing.expectEqualStrings("replace", r.effects[1].op);
    try testing.expectEqualStrings("shale-check/first-run.txt", r.effects[1].path);
    try testing.expect(std.mem.startsWith(u8, r.output, "no shale-check/first-run.txt yet\n"));
    try testing.expect(std.mem.indexOf(u8, r.output, "at 2026-10-14T00:00:00Z\nconversations 1, channels 2\n") != null);
    // Again: the folder is there, only the file is replaced, and the
    // last run's text is printed first.
    var again = f.runAt(first_change, 1791936060, &out_buf);
    defer again.deinit();
    try finished(&again);
    try testing.expectEqual(@as(usize, 1), again.effects.len);
    try testing.expect(std.mem.startsWith(u8, again.output, "the last run wrote:\nwritten by a signed Shale script at 2026-10-14T00:00:00Z\n"));
}
