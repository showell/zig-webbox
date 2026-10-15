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
const stale_caches = @embedFile("examples/stale_caches.shale");
const find_message = @embedFile("examples/find_message.shale");

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
        for (files) |f| {
            const text = try transcript(a, f.sid, f.n);
            try d.writeFile(io, .{ .sub_path = f.path, .data = text });
            // **THE SIDECAR AS THE SITE WRITES IT** (angry-gopher
            // chat_count.zig, writeCount): "<count> <size>", the
            // transcript's size when counted, then "<offset> <uid>": where
            // its last message's block begins, the separator before it (0
            // for a first message: chat_store.zig's `new_size -
            // stored.len`), and who sent it. misc has none, as a topic not
            // yet read since the server started.
            if (std.mem.eql(u8, f.sid, "misc")) continue;
            const last = if (f.n > 1) std.mem.lastIndexOf(u8, text, sep).? else 0;
            const sidecar = try std.fmt.allocPrint(a, "{d} {d}\n{d} 7\n", .{ f.n, text.len, last });
            try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.count", .{f.path[0 .. f.path.len - 3]}), .data = sidecar });
        }
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
    try testing.expect(std.mem.indexOf(u8, r.output, "\nchat       10   4780  4.7 KiB      0\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\ngames       1   5000  4.9 KiB      0\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\nall        11   9780  9.6 KiB      0\n") != null);
    // The largest: games/big.json, then the 40-message transcript.
    try testing.expect(std.mem.indexOf(u8, r.output, "the largest files:\nbytes  size     path\n 5000  4.9 KiB  games/big.json\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "chat/channels/general/sessions/plans.md") != null);
}

test "example: chat topics from their count caches, the quiet ones, the caches stale or missing, and no transcript read" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A cache taken before the last messages: stale, as the site's can be.
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/chat/channels/general/sessions/plans.count", .data = "39 4000\n3900 7\n" });
    // Far ahead of the fixture's files' times: every topic is quiet.
    var r = f.runAt(chat_topics, 253402300000, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expectEqual(@as(usize, 0), r.effects.len);
    // Counts from the caches: 3 + 39 + 1, and misc has none.
    try testing.expect(std.mem.startsWith(u8, r.output, "topics\t4\tmessages\t43\tbytes\t4.6 KiB\n"));
    try testing.expect(std.mem.indexOf(u8, r.output, "topic           messages  size     changed\n#general plans        39  4.1 KiB  ") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "unchanged since 9999-10-02T23:46:40Z): 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "): 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "count caches that are stale or missing (the server recounts them): 2\ntopic           bytes  cache\n#general plans   4166  39 at 4000\n#random misc      188  none\n") != null);
    // Not one transcript read: the walk's folders and the caches, read one each.
    try testing.expect(r.steps < 20_000);
    // On 2026-10-14, the files (written today or later) are not quiet.
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

// ── 208(d)'s cookbook ────────────────────────────────────────────────────

test "example: every count cache checked against its transcript's own separators, the stale and missing named, none read whole" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A cache taken before the last message, as a crash can leave it.
    try f.tmp.dir.writeFile(f.threaded.io(), .{ .sub_path = "data/chat/channels/general/sessions/plans.count", .data = "39 4000\n3900 7\n" });
    var r = f.run(stale_caches, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expectEqualStrings("topics checked\t4\tstale or missing\t2\n" ++
        \\topic           cache  counted  verdict
        \\#general lunch      1        1  ok
        \\#general plans     39       40  stale
        \\#random misc       -1        2  no cache
        \\1_2 hello           3        3  ok
        \\
    , r.output);
    // Every transcript scanned, none held: the arena stays small.
    try testing.expect(r.arena_bytes < 512 * 1024);
}

test "example: a phrase found in the chat, each topic's first message with it, and the run stops at its read budget saying how far it got" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var r = f.run(find_message, &out_buf);
    defer r.deinit();
    try finished(&r);
    errdefer std.debug.print("{s}", .{r.output});
    try testing.expect(std.mem.startsWith(u8, r.output, "\"line of it\" in 4 of 4 topics\n"));
    try testing.expect(std.mem.indexOf(u8, r.output, "#general plans  MSG_plans_1  steve  2026-10-13T12:00:00Z") != null);
    // With a read budget for about one topic: it stops, and says so.
    var short = script.run(f.threaded.io(), testing.allocator, f.root, find_message, .{ .read_bytes = 3000 }, 0, &out_buf);
    defer short.deinit();
    try finished(&short);
    try testing.expect(std.mem.indexOf(u8, short.output, "stopped at the read budget, after ") != null);
}

/// **THE SITE'S BUDGETS** (angry-gopher `zig-server/src/admin_script.zig`,
/// `budgets`, at v30): what the live route gives a signed script.
const site_budgets: script.Budgets = .{
    .steps = 2_000_000,
    .arena_bytes = 8 * 1024 * 1024,
    .reads = 500,
    .read_bytes = 16 * 1024 * 1024,
    .changes = 100,
};

test "every read-only script of the cookbook finishes on the site-shaped store inside the site's own budgets, changing nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const read_only = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "topics", .src = topics },
        .{ .name = "big_files", .src = big_files },
        .{ .name = "where_the_bytes_are", .src = where_the_bytes_are },
        .{ .name = "chat_topics", .src = chat_topics },
        .{ .name = "stale_caches", .src = stale_caches },
        .{ .name = "find_message", .src = find_message },
    };
    for (read_only) |ex| {
        var r = script.run(f.threaded.io(), testing.allocator, f.root, ex.src, site_budgets, 1791936000, &out_buf);
        defer r.deinit();
        errdefer std.debug.print("{s}\n", .{ex.name});
        try finished(&r);
        try testing.expectEqual(@as(usize, 0), r.effects.len);
    }
}

test "every cookbook script that walks gives the same answer walking in parts of three entries as in parts of 256 (metal-vmm QUEUE 211, the caps)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var whole_buf: [64 * 1024]u8 = undefined;
    for ([_][]const u8{ where_the_bytes_are, chat_topics, stale_caches, find_message }) |src| {
        var whole = script.run(f.threaded.io(), testing.allocator, f.root, src, .{}, 1791936000, &whole_buf);
        defer whole.deinit();
        try finished(&whole);
        var parts = script.run(f.threaded.io(), testing.allocator, f.root, src, .{ .call_entries = 3 }, 1791936000, &out_buf);
        defer parts.deinit();
        try finished(&parts);
        try testing.expectEqualStrings(whole.output, parts.output);
    }
}

// ── 209(b): docs/SHALE.md's snippets run ─────────────────────────────────

/// One ```shale block of the reference: its source, and what it must do,
/// from its last comment lines: `-- prints:` and the output, a line of it
/// each as `-- text` (or `--` for an empty line), or `-- stops: <class>`.
/// **A PASSING RUN PRINTS NOTHING THAT SAYS "FAILED"** (the box, 209): the
/// planted cases below expect these complaints, so they are kept quiet
/// there, and said only when a real doc check fails.
var quiet = false;

fn complain(comptime fmt: []const u8, args: anytype) void {
    if (!quiet) std.debug.print(fmt, args);
}

const Snippet = struct { line: usize, source: []const u8, prints: ?[]const u8, stops: ?[]const u8 };

fn snippets(a: std.mem.Allocator, doc: []const u8) ![]Snippet {
    var out: std.ArrayList(Snippet) = .empty;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var n: usize = 0;
    var in_block: ?[]const u8 = null;
    var start: usize = 0;
    var body: std.ArrayList(u8) = .empty;
    var prev_blank = true;
    while (lines.next()) |line| {
        n += 1;
        if (in_block) |lang| {
            if (std.mem.eql(u8, line, "```")) {
                in_block = null;
                if (std.mem.eql(u8, lang, "shale")) try out.append(a, try parseSnippet(a, start, body.items));
                body = .empty;
            } else if (std.mem.eql(u8, lang, "shale")) {
                try body.appendSlice(a, line);
                try body.append(a, '\n');
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            const lang = line[3..];
            if (lang.len == 0) {
                complain("docs/SHALE.md:{d}: a code block with no language: say what it is (shale, zig, sh, ebnf)\n", .{n});
                return error.TestUnexpectedResult;
            }
            in_block = lang;
            start = n;
            continue;
        }
        // A fence indented (inside a list) is never read as one here, so
        // its block would never run: fences start their line.
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            complain("docs/SHALE.md:{d}: an indented fence: start it at the line's start, outside the list\n", .{n});
            return error.TestUnexpectedResult;
        }
        // An indented code block would never run: every block is fenced.
        if (prev_blank and std.mem.startsWith(u8, line, "    ") and !std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "-")) {
            complain("docs/SHALE.md:{d}: an indented code block: fence it, with its language\n", .{n});
            return error.TestUnexpectedResult;
        }
        prev_blank = std.mem.trim(u8, line, " ").len == 0;
    }
    return out.items;
}

fn parseSnippet(a: std.mem.Allocator, line: usize, text: []const u8) !Snippet {
    if (std.mem.indexOf(u8, text, "\n-- stops: ")) |at| {
        const class = std.mem.trim(u8, text[at + "\n-- stops: ".len ..], " \n");
        return .{ .line = line, .source = text[0 .. at + 1], .prints = null, .stops = class };
    }
    const mark = std.mem.indexOf(u8, text, "-- prints:\n") orelse {
        complain("docs/SHALE.md:{d}: a shale block with no `-- prints:` or `-- stops:`: say what it does\n", .{line});
        return error.TestUnexpectedResult;
    };
    var want: std.ArrayList(u8) = .empty;
    const after = std.mem.trimEnd(u8, text[mark + "-- prints:\n".len ..], "\n");
    if (after.len == 0) return .{ .line = line, .source = text[0..mark], .prints = "", .stops = null };
    var rest = std.mem.splitScalar(u8, after, '\n');
    while (rest.next()) |l| {
        if (std.mem.eql(u8, l, "--")) {
            try want.append(a, '\n');
        } else if (std.mem.startsWith(u8, l, "-- ")) {
            try want.appendSlice(a, l[3..]);
            try want.append(a, '\n');
        } else {
            complain("docs/SHALE.md:{d}: after `-- prints:`, only `-- ` lines\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
    return .{ .line = line, .source = text[0..mark], .prints = want.items, .stops = null };
}

/// Every ```shale block of the reference, run on the site-shaped store at
/// 2026-10-14 (tabs written as `<TAB>` in the doc).
fn checkDoc(doc: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try snippets(a, doc);
    var wrong: usize = 0;
    for (all) |sn| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        var r = f.runAt(sn.source, 1791936000, &out_buf);
        defer r.deinit();
        if (sn.stops) |class| {
            const s = r.stop orelse {
                complain("docs/SHALE.md:{d}: finished, and should stop with {s}\n", .{ sn.line, class });
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, @tagName(s.class), class)) {
                complain("docs/SHALE.md:{d}: stopped {s} ({s}), not {s}\n", .{ sn.line, @tagName(s.class), s.message, class });
                return error.TestUnexpectedResult;
            }
            continue;
        }
        if (r.stop) |s| {
            complain("docs/SHALE.md:{d}: stopped {d}:{d} {s}: {s}\n", .{ sn.line, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        const got = try std.mem.replaceOwned(u8, a, r.output, "\t", "<TAB>");
        if (!std.mem.eql(u8, got, sn.prints.?)) {
            // Every block that differs is said, so a doc is fixed in one go.
            complain("docs/SHALE.md:{d}: prints\n{s}-- not --\n{s}", .{ sn.line, got, sn.prints.? });
            wrong += 1;
        }
    }
    if (wrong > 0) return error.TestUnexpectedResult;
    return all.len;
}

test "docs/SHALE.md: every shale block runs on the site-shaped store and prints what the doc says it prints; no block goes unchecked" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const doc = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "docs/SHALE.md", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(doc);
    try testing.expect(try checkDoc(doc) >= 8);
}

test "docs/SHALE.md's check fires: a snippet whose output is wrong, one with no expectation, an unfenced block, a block with no language, a fence indented in a list" {
    const planted = [_][]const u8{
        "```shale\nprint(1 + 1)\n-- prints:\n-- 3\n```\n",
        "```shale\nprint(1)\n```\n",
        "text\n\n    print(1)\n",
        "```\nprint(1)\n```\n",
        "```shale\nprint(1)\n-- stops: type\n```\n",
        "- an item\n\n  ```shale\n  print(1)\n  ```\n",
    };
    quiet = true;
    defer quiet = false;
    for (planted) |p| try testing.expectError(error.TestUnexpectedResult, checkDoc(p));
    try testing.expectEqual(@as(usize, 1), try checkDoc("```shale\nprint(1, 2)\n-- prints:\n-- 1<TAB>2\n```\n"));
}
