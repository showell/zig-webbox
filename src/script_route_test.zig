//! The script route against a real store in a temporary folder: each
//! refusal the brief names, and runs that read, delete, and stop on a
//! budget with some of their effects done (metal-vmm QUEUE 200).

const std = @import("std");
const route = @import("script_route.zig");
const store = @import("store.zig");
const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

var out_buf: [64 * 1024]u8 = undefined;
var status_buf: [64 * 1024]u8 = undefined;

const seed: [32]u8 = @splat(7);
const other_seed: [32]u8 = @splat(9);
const now: i64 = 1_800_000_000;

var durable_answer = true;
var durable_calls: usize = 0;
fn testDurable() bool {
    durable_calls += 1;
    return durable_answer;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    auth: []const u8,
    paths: route.Paths,
    saved: store.Bases,
    kp: Ed25519.KeyPair,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.threaded = std.Io.Threaded.init(testing.allocator, .{});
        f.arena = .init(testing.allocator);
        const a = f.arena.allocator();
        const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &f.tmp.sub_path });
        f.data = try std.fs.path.join(a, &.{ base, "data" });
        f.auth = try std.fs.path.join(a, &.{ base, "auth" });
        const io = f.threaded.io();
        try f.tmp.dir.createDir(io, "data", .default_dir);
        try f.tmp.dir.createDir(io, "auth", .default_dir);
        try f.tmp.dir.createDir(io, "data/chat", .default_dir);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/a.md", .data = "hello" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "data/chat/b.md", .data = "world!" });
        f.saved = store.saveBases();
        store.setBases(f.data, f.auth);
        f.paths = try route.Paths.under(a, f.auth);
        f.kp = try Ed25519.KeyPair.generateDeterministic(seed);
        durable_answer = true;
        durable_calls = 0;
        store.durable_now = testDurable;
        try f.configure("test.example", f.kp.public_key);
    }

    fn deinit(f: *Fixture) void {
        store.durable_now = null;
        f.saved.restore();
        f.arena.deinit();
        f.threaded.deinit();
        f.tmp.cleanup();
    }

    fn configure(f: *Fixture, target: []const u8, key: Ed25519.PublicKey) !void {
        const a = f.arena.allocator();
        const hex = std.fmt.bytesToHex(key.toBytes(), .lower);
        try route.installKey(f.threaded.io(), a, f.paths, try std.fmt.allocPrint(a, "# the script route\npublic_key = {s}\ntarget = {s}\n", .{ &hex, target }), 0);
    }

    fn body(f: *Fixture, kp: Ed25519.KeyPair, target: []const u8, sequence: u64, expires: i64, source: []const u8) ![]u8 {
        const a = f.arena.allocator();
        const signed = try route.signedBytes(a, target, sequence, expires, source);
        const sig = try kp.sign(signed, null);
        return route.envelope(a, sig.toBytes(), signed);
    }

    fn bodyIn(f: *Fixture, sequence: u64, mode: route.Mode, source: []const u8) ![]u8 {
        const a = f.arena.allocator();
        const signed = try route.signedBytesIn(a, "test.example", sequence, now + 600, mode, source);
        const sig = try f.kp.sign(signed, null);
        return route.envelope(a, sig.toBytes(), signed);
    }

    /// A request on a host that steps background runs, from the testing
    /// allocator: a leak of the run is the test's failure.
    fn sendHosted(f: *Fixture, b: []const u8) !route.Outcome {
        return route.handle(f.threaded.io(), f.arena.allocator(), b, .{ .paths = f.paths, .data_root = f.data, .budgets = .{}, .now = now, .out = &out_buf, .backing = testing.allocator });
    }

    fn status() ![]const u8 {
        var w: std.Io.Writer = .fixed(&status_buf);
        try route.writeBackgroundStatus(&w);
        return w.buffered();
    }

    fn send(f: *Fixture, b: []const u8) !route.Outcome {
        return route.handle(f.threaded.io(), f.arena.allocator(), b, .{ .paths = f.paths, .data_root = f.data, .budgets = .{}, .now = now, .out = &out_buf });
    }

    fn sendWith(f: *Fixture, b: []const u8, budgets: @import("script/script.zig").Budgets) !route.Outcome {
        return route.handle(f.threaded.io(), f.arena.allocator(), b, .{ .paths = f.paths, .data_root = f.data, .budgets = budgets, .now = now, .out = &out_buf });
    }

    fn expectRefused(f: *Fixture, b: []const u8, why: route.Refusal) !void {
        var o = try f.send(b);
        defer o.deinit();
        switch (o) {
            .refused => |r| if (r.why != why) {
                std.debug.print("refused {s} ({s}), not {s}\n", .{ @tagName(r.why), r.detail, @tagName(why) });
                return error.TestUnexpectedResult;
            },
            .ran, .started, .killed => return error.TestUnexpectedResult,
        }
    }

    fn reply(o: *const route.Outcome, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try route.writeReply(o, &w);
        return w.buffered();
    }

    fn log(f: *Fixture) ![]const u8 {
        return (try store.readOrNull(f.threaded.io(), f.arena.allocator(), f.paths.log, .unlimited)) orelse "";
    }

    fn last(f: *Fixture) !u64 {
        return route.lastSequence(f.threaded.io(), f.arena.allocator(), f.paths.sequence);
    }
};

test "a read-only script runs: its output, no effects, finished, and its start and end logged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var o = try f.send(try f.body(f.kp, "test.example", 1, now + 600, "for name in ls(\"chat\") do print(name) end\n"));
    defer o.deinit();
    try testing.expectEqual(std.http.Status.ok, o.status());
    var buf: [4096]u8 = undefined;
    const r = try Fixture.reply(&o, &buf);
    try testing.expect(std.mem.startsWith(u8, r, "a.md\nb.md\n── effects (0) ──\n── finished ("));
    try testing.expectEqual(@as(u64, 1), try f.last());
    const log = try f.log();
    try testing.expect(std.mem.indexOf(u8, log, "seq=1 sha256=") != null);
    try testing.expect(std.mem.endsWith(u8, log, "steps)\n"));
    try testing.expect(std.mem.indexOf(u8, log, "seq=1 finished (") != null);
    // Its source, kept under its number.
    const kept = try store.read(f.threaded.io(), f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.paths.runs, "1.shale" }), .unlimited);
    try testing.expectEqualStrings("for name in ls(\"chat\") do print(name) end\n", kept);
    try testing.expect(durable_calls >= 1);
}

test "a script that deletes: the file is gone, the effect said and logged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var o = try f.send(try f.body(f.kp, "test.example", 5, now + 60, "remove(\"chat/a.md\")\nprint(\"gone\")\n"));
    defer o.deinit();
    try testing.expectEqual(std.http.Status.ok, o.status());
    try testing.expect(o.ran.changedStore());
    var buf: [4096]u8 = undefined;
    const r = try Fixture.reply(&o, &buf);
    try testing.expect(std.mem.startsWith(u8, r, "gone\n── effects (1) ──\nremove chat/a.md: ok\n── finished ("));
    try testing.expect(!try store.has(f.threaded.io(), f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.data, "chat", "a.md" })));
    try testing.expect(std.mem.indexOf(u8, try f.log(), "seq=5 effect remove chat/a.md: ok\n") != null);
}

test "a script stopped by a budget, some of its effects done: 200, the effects so far, where it stopped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const src = "remove(\"chat/a.md\")\nremove(\"chat/b.md\")\nlocal i = 0\nwhile true do i = i + 1 end\n";
    var o = try f.sendWith(try f.body(f.kp, "test.example", 2, now + 60, src), .{ .steps = 1000 });
    defer o.deinit();
    try testing.expectEqual(std.http.Status.ok, o.status());
    var buf: [4096]u8 = undefined;
    const r = try Fixture.reply(&o, &buf);
    try testing.expect(std.mem.indexOf(u8, r, "── effects (2) ──\nremove chat/a.md: ok\nremove chat/b.md: ok\n── stopped at seq 2:4:") != null);
    try testing.expect(std.mem.indexOf(u8, r, "budget steps") != null);
    const log = try f.log();
    try testing.expect(std.mem.indexOf(u8, log, "seq=2 effect remove chat/b.md: ok\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "seq=2 stopped at 4:") != null);
}

test "refused: a signature by another key, or over other bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const other = try Ed25519.KeyPair.generateDeterministic(other_seed);
    try f.expectRefused(try f.body(other, "test.example", 1, now + 60, "print(1)\n"), .bad_signature);
    // A byte of the script changed after signing.
    const b = try f.body(f.kp, "test.example", 1, now + 60, "print(1)\n");
    b[b.len - 3] = '2';
    try f.expectRefused(b, .bad_signature);
    try testing.expectEqual(@as(u64, 0), try f.last());
    try testing.expectEqualStrings("", try f.log());
}

test "refused: signed for another target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectRefused(try f.body(f.kp, "lynrummy.com", 1, now + 60, "print(1)\n"), .wrong_target);
}

test "refused: a replay, and an older number" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = try f.body(f.kp, "test.example", 7, now + 60, "print(1)\n");
    var first = try f.send(b);
    first.deinit();
    try testing.expectEqual(@as(u64, 7), try f.last());
    try f.expectRefused(b, .replayed);
    try f.expectRefused(try f.body(f.kp, "test.example", 6, now + 60, "print(1)\n"), .replayed);
    try testing.expectEqual(@as(u64, 7), try f.last());
}

test "refused: expired, and an expiry too far ahead" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.expectRefused(try f.body(f.kp, "test.example", 1, now - 1, "print(1)\n"), .expired);
    try f.expectRefused(try f.body(f.kp, "test.example", 1, now + route.max_ahead_s + 1, "print(1)\n"), .expires_too_far);
}

test "refused: no key configured (the route never falls open), and a config that is not one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = try f.body(f.kp, "test.example", 1, now + 60, "print(1)\n");
    try store.remove(f.threaded.io(), f.arena.allocator(), f.paths.config);
    try f.expectRefused(b, .no_key);
    try store.replace(f.threaded.io(), f.arena.allocator(), f.paths.config, "public_key = zz\ntarget = test.example\n", .{});
    try f.expectRefused(b, .bad_config);
    try testing.expectEqual(@as(u64, 0), try f.last());
}

test "refused: a body that is not exactly one envelope" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const good = try f.body(f.kp, "test.example", 1, now + 60, "print(1)\n");
    try f.expectRefused("print(1)\n", .malformed);
    try f.expectRefused("", .malformed);
    // The second line spelled another way: a leading zero, a doubled space,
    // a capital in the host, a field missing.
    const nl = std.mem.indexOfScalar(u8, good, '\n').? + 1;
    const head = good[0..nl];
    const a = f.arena.allocator();
    for ([_][]const u8{
        "shale-1 target=test.example sequence=01 expires=1800000060\nprint(1)\n",
        "shale-1 target=test.example  sequence=1 expires=1800000060\nprint(1)\n",
        "shale-1 target=Test.example sequence=1 expires=1800000060\nprint(1)\n",
        "shale-1 target=test.example sequence=1\nprint(1)\n",
        "shale-2 target=test.example sequence=1 expires=1800000060\nprint(1)\n",
    }) |rest| try f.expectRefused(try std.mem.concat(a, u8, &.{ head, rest }), .malformed);
}

test "refused, and not run: the sequence cannot be made durable; its number is spent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    durable_answer = false;
    try f.expectRefused(try f.body(f.kp, "test.example", 3, now + 60, "remove(\"chat/a.md\")\n"), .not_recorded);
    try testing.expect(try store.has(f.threaded.io(), f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.data, "chat", "a.md" })));
    // No host said how: never true.
    store.durable_now = null;
    try testing.expect(!store.makeDurable());
}

test "the envelope reads back what was signed, and the header has one spelling" {
    const a = testing.allocator;
    const signed = try route.signedBytes(a, "lynrummy.com", 42, 1_800_000_000, "print(\"hi\")\n");
    defer a.free(signed);
    const sig: [64]u8 = @splat(0xab);
    const b = try route.envelope(a, sig, signed);
    defer a.free(b);
    const env = try route.parse(b);
    try testing.expectEqualStrings("lynrummy.com", env.target);
    try testing.expectEqual(@as(u64, 42), env.sequence);
    try testing.expectEqual(@as(i64, 1_800_000_000), env.expires);
    try testing.expectEqualStrings("print(\"hi\")\n", env.source);
    try testing.expectEqualSlices(u8, signed, env.signed);
    try testing.expectEqualSlices(u8, &sig, &env.signature);
}

test "refused, and not run: a key with no sequence file beside it (lost, never 0)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const a = f.arena.allocator();
    var first = try f.send(try f.body(f.kp, "test.example", 4, now + 60, "print(1)\n"));
    first.deinit();
    try store.remove(io, a, f.paths.sequence);
    try f.expectRefused(try f.body(f.kp, "test.example", 4, now + 60, "remove(\"chat/a.md\")\n"), .sequence_unreadable);
    try testing.expect(try store.has(io, a, try std.fs.path.join(a, &.{ f.data, "chat", "a.md" })));
}

test "installKey: the sequence rises to the clock and never falls, so a key set again reopens nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const a = f.arena.allocator();
    const hex = std.fmt.bytesToHex(f.kp.public_key.toBytes(), .lower);
    const conf = try std.fmt.allocPrint(a, "public_key = {s}\ntarget = test.example\n", .{&hex});
    // Signed before the key was set again, after the sequence was lost.
    const old = try f.body(f.kp, "test.example", 9, now + 60, "print(1)\n");
    try store.remove(io, a, f.paths.sequence);
    try route.installKey(io, a, f.paths, conf, now);
    try testing.expectEqual(@as(u64, now), try f.last());
    try f.expectRefused(old, .replayed);
    // Set again with an older clock: the sequence stays.
    try route.installKey(io, a, f.paths, conf, 5);
    try testing.expectEqual(@as(u64, now), try f.last());
    // Not a config: nothing written.
    try testing.expectError(error.BadConfig, route.installKey(io, a, f.paths, "public_key = zz\n", now + 100));
    try testing.expectEqual(@as(u64, now), try f.last());
}

test "refused: the auth root inside the data root, or the other way, or the same" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const b = try f.body(f.kp, "test.example", 1, now + 60, "print(1)\n");
    const inside = try route.Paths.under(a, try std.fs.path.join(a, &.{ f.data, "auth" }));
    for ([_]route.Request{
        .{ .paths = inside, .data_root = f.data, .budgets = .{}, .now = now, .out = &out_buf },
        .{ .paths = f.paths, .data_root = try std.fs.path.join(a, &.{ f.auth, "data" }), .budgets = .{}, .now = now, .out = &out_buf },
        .{ .paths = try route.Paths.under(a, try std.fmt.allocPrint(a, "{s}/", .{f.data})), .data_root = try std.fmt.allocPrint(a, "{s}/./", .{f.data}), .budgets = .{}, .now = now, .out = &out_buf },
    }) |req| {
        var o = try route.handle(f.threaded.io(), a, b, req);
        defer o.deinit();
        try testing.expectEqual(route.Refusal.bad_config, o.refused.why);
    }
    // Siblings whose names share a prefix do not nest.
    try testing.expect(!try route.nested(a, "x/data", "x/data2"));
    try testing.expect(!try route.nested(a, "data", "auth"));
    try testing.expect(try route.nested(a, "x/data", "x/data/auth"));
}

// ── background runs (metal-vmm QUEUE 211, step 5) ──────────────────────

const walk_source = "for e in walk(\"chat\") do print(e.path, e.size) end\n";

test "a background run is answered at once with its number, steps a slice at a time between requests, and prints what the atomic run prints" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer route.background.reset();
    var o = try f.sendHosted(try f.bodyIn(1, .background, walk_source));
    defer o.deinit();
    try testing.expectEqual(std.http.Status.accepted, o.status());
    try testing.expect(std.mem.startsWith(u8, try Fixture.status(), "background seq=1 running: 0 steps, 0 slices\n"));
    // The walk is one store call: a slice to its end, and one after.
    var slices: usize = 1;
    while (route.sliceBackground(f.threaded.io(), now + 1)) slices += 1;
    try testing.expectEqual(@as(usize, 2), slices);
    const st = try Fixture.status();
    try testing.expect(std.mem.startsWith(u8, st, "background seq=1 finished: background, 2 slices: finished ("));
    // The atomic run of the same script prints the same.
    var a = try f.send(try f.body(f.kp, "test.example", 2, now + 600, walk_source));
    defer a.deinit();
    try testing.expect(std.mem.endsWith(u8, st, a.ran.result.output));
    try testing.expectEqualStrings("chat/a.md\t5\nchat/b.md\t6\n", a.ran.result.output);
    const log = try f.log();
    try testing.expect(std.mem.indexOf(u8, log, "seq=1 sha256=") != null);
    try testing.expect(std.mem.indexOf(u8, log, " mode=background started\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "seq=1 background, ") != null);
}

test "a second background run is refused busy, its number unspent; a kill ends the first, everything given back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer route.background.reset();
    var o = try f.sendHosted(try f.bodyIn(1, .background, "local n = 0 while true do n = n + 1 end"));
    defer o.deinit();
    try testing.expect(route.sliceBackground(f.threaded.io(), now));
    try testing.expect(route.sliceBackground(f.threaded.io(), now));
    var second = try f.sendHosted(try f.bodyIn(2, .background, walk_source));
    defer second.deinit();
    try testing.expectEqual(route.Refusal.busy, second.refused.why);
    try testing.expectEqual(std.http.Status.service_unavailable, second.status());
    try testing.expectEqual(@as(u64, 1), try f.last());
    var kill = try f.sendHosted(try f.bodyIn(2, .kill, ""));
    defer kill.deinit();
    try testing.expectEqual(@as(u64, 1), kill.killed.sequence);
    try testing.expectEqual(@as(u64, 2), kill.killed.slices);
    try testing.expect(!route.sliceBackground(f.threaded.io(), now));
    try testing.expect(std.mem.startsWith(u8, try Fixture.status(), "background seq=1 killed: killed by seq=2 after "));
    try testing.expect(std.mem.indexOf(u8, try f.log(), "seq=1 killed by seq=2") != null);
    // Nothing running now: a kill has nothing to end, a run may start.
    var again = try f.sendHosted(try f.bodyIn(3, .kill, ""));
    defer again.deinit();
    try testing.expectEqual(route.Refusal.not_running, again.refused.why);
    var next = try f.sendHosted(try f.bodyIn(4, .background, walk_source));
    defer next.deinit();
    try testing.expectEqual(std.http.Status.accepted, next.status());
}

test "a background run that changes the store stops, naming atomic, and changes nothing; a host that steps none refuses one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer route.background.reset();
    var o = try f.sendHosted(try f.bodyIn(1, .background, "print(1) remove(\"chat/a.md\")"));
    defer o.deinit();
    while (route.sliceBackground(f.threaded.io(), now)) {}
    const st = try Fixture.status();
    try testing.expect(std.mem.indexOf(u8, st, "stopped at 1:10") != null);
    try testing.expect(std.mem.indexOf(u8, st, "`atomic`") != null);
    try testing.expect((try store.readOrNull(f.threaded.io(), f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.data, "chat", "a.md" }), .unlimited)) != null);
    try f.expectRefused(try f.bodyIn(2, .background, walk_source), .no_background);
    // `mode=atomic` is not a spelling: none is.
    const a = f.arena.allocator();
    const signed = try std.mem.concat(a, u8, &.{ "shale-1 target=test.example sequence=3 expires=1800000600 mode=atomic\n", walk_source });
    try f.expectRefused(try route.envelope(a, (try f.kp.sign(signed, null)).toBytes(), signed), .malformed);
}

test "a background run takes the background budgets when the host gives them, the atomic run the site's own" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer route.background.reset();
    const reads = "for e in walk(\"chat\") do print(e.path) end\n";
    const few: @import("script/script.zig").Budgets = .{ .reads = 2 };
    const many: @import("script/script.zig").Budgets = .{ .reads = 10_000 };
    var atomic = try route.handle(f.threaded.io(), f.arena.allocator(), try f.body(f.kp, "test.example", 1, now + 600, reads), .{ .paths = f.paths, .data_root = f.data, .budgets = few, .now = now, .out = &out_buf, .backing = testing.allocator, .background_budgets = many });
    defer atomic.deinit();
    try testing.expectEqual(@import("script/script.zig").diag.Budget.reads, atomic.ran.result.stop.?.budget.?);
    var bg = try route.handle(f.threaded.io(), f.arena.allocator(), try f.bodyIn(2, .background, reads), .{ .paths = f.paths, .data_root = f.data, .budgets = few, .now = now, .out = &out_buf, .backing = testing.allocator, .background_budgets = many });
    defer bg.deinit();
    while (route.sliceBackground(f.threaded.io(), now)) {}
    try testing.expect(std.mem.startsWith(u8, try Fixture.status(), "background seq=2 finished: "));
}

test "a background run owns its source: the request's memory gone, the run goes on (a crash on Dog Park's host, metal-vmm QUEUE 214)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer route.background.reset();
    // The request's body and everything it allocated, freed when it is
    // answered, as a host frees a request's arena; the run's names, keys
    // and strings must not live there.
    {
        // From the page allocator, as a host's is: freed is unmapped.
        var request: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer request.deinit();
        const a = request.allocator();
        const source = "local m = {a = \"one\", b = \"two\"}\nlocal n = 0\nfor e in walk(\"chat\") do n = n + 1 end\nprint(m.a, m[\"b\"], n)\n";
        const signed = try route.signedBytesIn(a, "test.example", 1, now + 600, .background, source);
        const sig = try f.kp.sign(signed, null);
        const body = try route.envelope(a, sig.toBytes(), signed);
        var o = try route.handle(f.threaded.io(), a, body, .{ .paths = f.paths, .data_root = f.data, .budgets = .{}, .now = now, .out = &out_buf, .backing = testing.allocator });
        o.deinit();
    }
    while (route.sliceBackground(f.threaded.io(), now)) {}
    const st = try Fixture.status();
    if (!std.mem.endsWith(u8, st, "one\ttwo\t2\n")) {
        std.debug.print("status: {s}\n", .{st});
        return error.TestUnexpectedResult;
    }
}

test "THE ROUTE'S REPLY, WHOLE, FROZEN (the dogfood design: its four readers, dog-park's test_shale.mjs, metal-vmm's script-refused.shape, judge_gopher.py and angry-gopher's tests, see nothing change)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [4096]u8 = undefined;
    // Finished, with output and an effect.
    var o = try f.send(try f.body(f.kp, "test.example", 1, now + 600, "print(\"a-\" .. 1)\nremove(\"chat/a.md\")\nprint(#ls(\"chat\"))\n"));
    defer o.deinit();
    try testing.expectEqualStrings(
        \\a-1
        \\1
        \\── effects (1) ──
        \\remove chat/a.md: ok
        \\── finished (37 steps)
        \\
    , try Fixture.reply(&o, &buf));
    // Stopped in a function, called from another: the trail's lines.
    var s = try f.send(try f.body(f.kp, "test.example", 2, now + 600, "function g(x) return x + {} end\nfunction f() return g(1) end\nprint(\"before\")\nf()\n"));
    defer s.deinit();
    try testing.expectEqualStrings(
        \\before
        \\── effects (0) ──
        \\── stopped at seq 2:1:24 (in `g`): type: `+` takes integers, and its right is an empty table (21 steps)
        \\   called from seq 2:2:21 (in `f`)
        \\   called from seq 2:4:1
        \\
    , try Fixture.reply(&s, &buf));
}
