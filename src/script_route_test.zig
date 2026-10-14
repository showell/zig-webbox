//! The script route against a real store in a temporary folder: each
//! refusal the brief names, and runs that read, delete, and stop on a
//! budget with some of their effects done (metal-vmm QUEUE 200).

const std = @import("std");
const route = @import("script_route.zig");
const store = @import("store.zig");
const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

var out_buf: [64 * 1024]u8 = undefined;

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
        try store.replace(f.threaded.io(), a, f.paths.config, try std.fmt.allocPrint(a, "# the script route\npublic_key = {s}\ntarget = {s}\n", .{ &hex, target }), .{});
    }

    fn body(f: *Fixture, kp: Ed25519.KeyPair, target: []const u8, sequence: u64, expires: i64, source: []const u8) ![]u8 {
        const a = f.arena.allocator();
        const signed = try route.signedBytes(a, target, sequence, expires, source);
        const sig = try kp.sign(signed, null);
        return route.envelope(a, sig.toBytes(), signed);
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
            .ran => return error.TestUnexpectedResult,
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
