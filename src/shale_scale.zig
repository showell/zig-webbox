//! **THE SITE'S REAL SCALE** (metal-vmm QUEUE 209(g)): a store shaped like
//! angry-gopher's data, generated at a growing size, and each read-only
//! script of the cookbook run on it under the site's own budgets until it
//! no longer fits. It prints, for each script and each size of transcript,
//! the largest site that fits and what stops it past that:
//!
//!     zig build shale-scale            (ReleaseSafe; under .zig-cache/shale-scale)
//!
//! **THE GENERATOR** (`Site`): `topics` topics, spread over conversations
//! (`chat/<a>_<b>/sessions/`) and channels (`chat/channels/<name>/sessions/`,
//! each with its `<name>.channel`), each a transcript of `messages`
//! messages, its `.count` sidecar as the site writes it, a
//! `.reactions.jsonl` for one in three, and an `.uploads/` folder of
//! `upload_files` images for one in `uploads_every`. Every message's body
//! is about 200 bytes, and only a topic's last message has the phrase
//! `find_message.shale` looks for, so its search reads every transcript to
//! its end: the worst case, not the best.
//!
//! **SPARSE WHERE NOTHING READS IT:** a script that never reads a
//! transcript (`where_the_bytes_are`, `chat_topics`, `big_files`) is run on
//! a site whose transcripts and images are sparse files of their real
//! sizes, so a site of hundreds of thousands of files fits the disk.
//!
//! Outside the script module: it may name the host.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;

/// angry-gopher's `admin_script.zig`: the budgets a script runs under on
/// the live site.
const site_budgets: script.Budgets = .{
    .steps = 2_000_000,
    .arena_bytes = 8 * 1024 * 1024,
    .reads = 500,
    .read_bytes = 16 * 1024 * 1024,
    .changes = 100,
};

/// **A BACKGROUND RUN'S** (Steve, 2026-10-15): the site's, but for its
/// reads, which may be many, since it only fills the gaps between requests.
const background_budgets: script.Budgets = blk: {
    var b = site_budgets;
    b.reads = 10_000;
    break :blk b;
};

const Mode = struct { name: []const u8, budgets: script.Budgets };
const modes = [_]Mode{ .{ .name = "atomic", .budgets = site_budgets }, .{ .name = "background", .budgets = background_budgets } };

/// The fixture's clock (examples_test.zig): 2026-10-14.
const now: i64 = 1791936000;

const Script = struct { name: []const u8, src: []const u8, reads_transcripts: bool };

const scripts = [_]Script{
    .{ .name = "topics", .src = @embedFile("script/examples/topics.shale"), .reads_transcripts = true },
    .{ .name = "stale_caches", .src = @embedFile("script/examples/stale_caches.shale"), .reads_transcripts = true },
    .{ .name = "find_message", .src = @embedFile("script/examples/find_message.shale"), .reads_transcripts = true },
    .{ .name = "where_the_bytes_are", .src = @embedFile("script/examples/where_the_bytes_are.shale"), .reads_transcripts = false },
    .{ .name = "chat_topics", .src = @embedFile("script/examples/chat_topics.shale"), .reads_transcripts = false },
    .{ .name = "big_files", .src = @embedFile("script/examples/big_files.shale"), .reads_transcripts = false },
};

/// The sizes of transcript tried: messages a topic.
const profiles = [_]usize{ 10, 100, 1000 };

/// The most topics tried: past this the answer is "more than".
const most_topics = 200_000;

const sep = "\n\n-------------\n";
const conversations = 40;

const Site = struct {
    root: []const u8,
    messages: usize,
    sparse: bool,
    uploads_every: usize = 10,
    upload_files: usize = 5,
    upload_bytes: u64 = 120 * 1024,
    /// Topics made so far: a site only grows.
    topics: usize = 0,
    /// The transcripts' bytes.
    bytes: u64 = 0,

    fn convDir(a: std.mem.Allocator, c: usize) ![]u8 {
        return if (c % 2 == 0)
            std.fmt.allocPrint(a, "chat/{d}_{d}/sessions", .{ c + 1, c + 2 })
        else
            std.fmt.allocPrint(a, "chat/channels/c{d}/sessions", .{c});
    }

    fn init(self: *Site, io: std.Io, a: std.mem.Allocator) !void {
        const d = std.Io.Dir.cwd();
        d.deleteTree(io, self.root) catch {};
        for (0..conversations) |c| {
            const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.root, try convDir(a, c) });
            try d.createDirPath(io, p);
            if (c % 2 == 1) try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/chat/channels/c{d}.channel", .{ self.root, c }), .data = "1\n2\n3\n" });
        }
        try d.createDirPath(io, try std.fmt.allocPrint(a, "{s}/games", .{self.root}));
        try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/games/lynrummy.json", .{self.root}), .data = "{}" });
    }

    /// Topics added until there are `n`.
    fn grow(self: *Site, io: std.Io, gpa: std.mem.Allocator, n: usize) !void {
        const d = std.Io.Dir.cwd();
        while (self.topics < n) : (self.topics += 1) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const k = self.topics;
            const sid = try std.fmt.allocPrint(a, "t{d}", .{k});
            const base = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ self.root, try convDir(a, k % conversations), sid });
            var text: std.ArrayList(u8) = .empty;
            var last: usize = 0;
            for (1..self.messages + 1) |i| {
                if (i > 1) {
                    last = text.items.len;
                    try text.appendSlice(a, sep);
                }
                try text.print(a, "MSG_{s}_{d}\nfrom: steve\ndate: 2026-10-13T12:00:00Z\n\n", .{ sid, i });
                try text.appendSlice(a, "a message about the deploy, the disk and the dogs, written the way people write in a chat: a line, then another, and sometimes a third");
                try text.appendSlice(a, if (i == self.messages) ", a line of it\n" else ", and nothing more\n");
            }
            const md = try std.fmt.allocPrint(a, "{s}.md", .{base});
            if (self.sparse) {
                const f = try d.createFile(io, md, .{});
                defer f.close(io);
                try f.setLength(io, text.items.len);
            } else try d.writeFile(io, .{ .sub_path = md, .data = text.items });
            self.bytes += text.items.len;
            try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.count", .{base}), .data = try std.fmt.allocPrint(a, "{d} {d}\n{d} 1\n", .{ self.messages, text.items.len, last }) });
            if (k % 3 == 0) try d.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.reactions.jsonl", .{base}), .data = "{\"msg\":1,\"emoji\":\"+1\",\"uid\":2}\n" });
            if (k % self.uploads_every == 0) {
                const up = try std.fmt.allocPrint(a, "{s}.uploads", .{base});
                try d.createDirPath(io, up);
                for (0..self.upload_files) |i| {
                    const f = try d.createFile(io, try std.fmt.allocPrint(a, "{s}/{d}.png", .{ up, i }), .{});
                    defer f.close(io);
                    try f.setLength(io, self.upload_bytes);
                }
            }
        }
    }
};

const Outcome = struct { fits: bool, why: []const u8 };

fn tryScript(io: std.Io, gpa: std.mem.Allocator, root: []const u8, s: Script, budgets: script.Budgets, out: []u8, why_buf: []u8) Outcome {
    var r = script.run(io, gpa, root, s.src, budgets, now, out);
    defer r.deinit();
    if (r.stop) |stop| {
        const why = if (stop.budget) |b|
            std.fmt.bufPrint(why_buf, "budget {s}", .{@tagName(b)}) catch "budget"
        else
            std.fmt.bufPrint(why_buf, "{s}: {s}", .{ @tagName(stop.class), stop.message }) catch "stopped";
        return .{ .fits = false, .why = why };
    }
    // A script that stops itself at the read budget says so, and where the
    // next run goes on (QUEUE 229): a partial answer, which is not a fit.
    if (std.mem.indexOf(u8, r.output, "resume after ") != null or std.mem.indexOf(u8, r.output, "stopped at the read budget") != null) return .{ .fits = false, .why = "reads to its budget, then says what it found and where to resume" };
    return .{ .fits = true, .why = "" };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const out = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(out);
    var buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &buf);
    const w = &ow.interface;
    try w.print("| mode | script | messages a topic | largest site that fits | its transcripts | past it |\n|---|---|---|---|---|---|\n", .{});
    try w.flush();
    const root = ".zig-cache/shale-scale/data";
    for (modes) |mode| for (profiles) |m| {
        for ([_]bool{ true, false }) |reads| {
            var site: Site = .{ .root = root, .messages = m, .sparse = !reads };
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try site.init(io, arena.allocator());
            // Each script of the group: the last size it fit, and why the
            // next did not.
            var best: [scripts.len]?struct { topics: usize, bytes: u64 } = @splat(null);
            var why: [scripts.len][256]u8 = undefined;
            var why_len: [scripts.len]usize = @splat(0);
            var done: [scripts.len]bool = undefined;
            for (scripts, 0..) |s, i| done[i] = s.reads_transcripts != reads;
            var n: usize = 1;
            while (n <= most_topics) {
                try site.grow(io, gpa, n);
                var all_done = true;
                for (scripts, 0..) |s, i| {
                    if (done[i]) continue;
                    const o = tryScript(io, gpa, root, s, mode.budgets, out, &why[i]);
                    if (o.fits) {
                        best[i] = .{ .topics = n, .bytes = site.bytes };
                        all_done = false;
                    } else {
                        if (o.why.ptr != &why[i]) @memcpy(why[i][0..o.why.len], o.why);
                        why_len[i] = o.why.len;
                        done[i] = true;
                    }
                }
                if (all_done) break;
                // About 10% a step: the answer to within a tenth.
                n = @max(n + 1, n + n / 10);
            }
            for (scripts, 0..) |s, i| {
                if (s.reads_transcripts != reads) continue;
                var size_buf: [32]u8 = undefined;
                const fit = if (best[i]) |b| try std.fmt.bufPrint(&size_buf, "{d} topics", .{b.topics}) else "none";
                var bytes_buf: [32]u8 = undefined;
                const bytes = if (best[i]) |b| try human(&bytes_buf, b.bytes) else "";
                const past = if (why_len[i] > 0) why[i][0..why_len[i]] else "more than tried";
                var each_buf: [32]u8 = undefined;
                try w.print("| {s} | `{s}` | {d} (~{s} each) | {s} | {s} | {s} |\n", .{ mode.name, s.name, m, try human(&each_buf, site.bytes / @max(site.topics, 1)), fit, bytes, past });
                try w.flush();
            }
        }
    };
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/shale-scale") catch {};
}

fn human(buf: []u8, n: u64) ![]const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n});
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KiB", .{n / 1024});
    if (n < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MiB", .{@as(f64, @floatFromInt(n)) / (1024 * 1024)});
    return std.fmt.bufPrint(buf, "{d:.1} GiB", .{@as(f64, @floatFromInt(n)) / (1024 * 1024 * 1024)});
}
