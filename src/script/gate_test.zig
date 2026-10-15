//! **THE GATE** (metal-vmm QUEUE 211): in the tests, every `script.run` is
//! the VM's, on the store it was given, and the tree-walker's, on a copy
//! of that store made before; the two must agree on everything a run
//! shows: the output, the effects, the stop (its class, budget, place,
//! function and message), the steps, the work, the arena held, and the
//! store each leaves. A difference panics with both runs: the test it
//! happened in is the reproduction. So every interpreter, builtin,
//! example, cookbook and fuzz test holds the VM to the walker.

const std = @import("std");
const script = @import("script.zig");
const Io = std.Io;

pub fn run(io: Io, backing: std.mem.Allocator, root: []const u8, source: []const u8, budgets: script.Budgets, now: i64, out: []u8) script.Result {
    var paths: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer paths.deinit();
    const a = paths.allocator();
    const d = Io.Dir.cwd();
    // **THE COPY'S PATH IS AS LONG AS THE ROOT'S**: a store call's full
    // path is made in the arena, so a longer one would stop the walker on
    // the arena budget sooner. A sibling, its name's last byte changed.
    const copy = sibling(io, a, root, "~_#@");
    const cut_copy = sibling(io, a, root, "=+%^");
    const has_root = if (d.openDir(io, root, .{})) |dir| blk: {
        dir.close(io);
        break :blk true;
    } else |_| false;
    if (has_root) {
        copyTree(io, a, root, copy) catch |e| std.debug.panic("the gate can't copy {s}: {t}", .{ root, e });
        copyTree(io, a, root, cut_copy) catch |e| std.debug.panic("the gate can't copy {s}: {t}", .{ root, e });
    }
    defer if (has_root) {
        d.deleteTree(io, copy) catch {};
        d.deleteTree(io, cut_copy) catch {};
    };

    const walker_out = std.testing.allocator.alloc(u8, out.len) catch @panic("the gate's output");
    defer std.testing.allocator.free(walker_out);
    // The walker's memory is its own, so a test that measures the backing
    // allocator measures the VM's run alone.
    var w = script.runOn(.walker, io, std.testing.allocator, if (has_root) copy else root, source, budgets, now, walker_out);
    defer w.deinit();
    const v = script.runOn(.vm, io, backing, root, source, budgets, now, out);

    // **THE SAME RUN, CUT INTO SLICES** (QUEUE 211): a pause between any
    // two ops changes nothing, so the VM in slices of 1 to 29 steps (by the
    // source) is the uncut VM in every respect.
    const cut_out = std.testing.allocator.alloc(u8, out.len) catch @panic("the gate's output");
    defer std.testing.allocator.free(cut_out);
    const slice = 1 + std.hash.Wyhash.hash(0, source) % 29;
    var cut = script.runOn(.{ .vm_sliced = slice }, io, std.testing.allocator, if (has_root) cut_copy else root, source, budgets, now, cut_out);
    defer cut.deinit();
    if (!std.mem.eql(u8, v.output, cut.output) or v.steps != cut.steps or v.work != cut.work or v.arena_bytes != cut.arena_bytes or !sameStop(v.stop, cut.stop) or v.effects.len != cut.effects.len or
        (has_root and !(sameTree(io, a, root, cut_copy) catch false)))
    {
        std.debug.print("\n── THE GATE: the VM in slices of {d} differs from the VM in one piece ──\n{s}\n", .{ slice, source });
        for ([_]struct { name: []const u8, r: *const script.Result }{ .{ .name = "whole", .r = &v }, .{ .name = "cut", .r = &cut } }) |x| {
            std.debug.print("── {s}: {d} steps, {d} work, {d} arena, {d} effects\n", .{ x.name, x.r.steps, x.r.work, x.r.arena_bytes, x.r.effects.len });
            if (x.r.stop) |st| std.debug.print("   stopped {d}:{d} ({s}) {t} {?t}: {s}\n", .{ st.line, st.column, st.function, st.class, st.budget, st.message });
        }
        @panic("the VM in slices differs from the VM whole (metal-vmm QUEUE 211's gate)");
    }

    var why: ?[]const u8 = null;
    // **A SCRIPT THAT YIELDS** (QUEUE 211, M1): the VM copies what it keeps
    // into a fresh arena at each `yield`, charged as steps, and the walker
    // keeps everything. Their steps, work and arena differ by that, and so
    // may a stop on the steps, the arena or what is kept; all else is the
    // same.
    const yields = std.mem.indexOf(u8, source, "yield") != null;
    const arena_shaped = yields and (isArenaShaped(v.stop) or isArenaShaped(w.stop));
    if (!arena_shaped) {
        if (!std.mem.eql(u8, v.output, w.output)) why = "the output";
        if (!sameStop(v.stop, w.stop)) why = "the stop";
    }
    if (!yields) {
        if (v.steps != w.steps) why = "the steps";
        if (v.work != w.work) why = "the work";
        if (v.arena_bytes != w.arena_bytes) why = "the arena";
    }
    if (v.effects.len != w.effects.len) {
        why = "the effects";
    } else for (v.effects, w.effects) |x, y| {
        if (!std.mem.eql(u8, x.op, y.op) or !std.mem.eql(u8, x.path, y.path) or !std.mem.eql(u8, x.outcome, y.outcome)) why = "the effects";
    }
    if (why == null and has_root) {
        if (!(sameTree(io, a, root, copy) catch false)) why = "the store left";
    }
    if (why) |what| {
        std.debug.print("\n── THE GATE: the VM and the walker differ in {s} ──\n{s}\n", .{ what, source });
        for ([_]struct { name: []const u8, r: *const script.Result }{ .{ .name = "vm", .r = &v }, .{ .name = "walker", .r = &w } }) |x| {
            std.debug.print("── {s}: {d} steps, {d} work, {d} arena, {d} effects\n", .{ x.name, x.r.steps, x.r.work, x.r.arena_bytes, x.r.effects.len });
            if (x.r.stop) |s| std.debug.print("   stopped {d}:{d} ({s}) {t} {?t}: {s}\n", .{ s.line, s.column, s.function, s.class, s.budget, s.message });
            std.debug.print("   output: {s}\n", .{x.r.output[0..@min(x.r.output.len, 400)]});
        }
        @panic("the VM and the tree-walker differ (metal-vmm QUEUE 211's gate)");
    }
    return v;
}

/// A sibling of `root` with a name as long as its own: its last byte the
/// first of `bytes` no sibling has.
fn sibling(io: Io, a: std.mem.Allocator, root: []const u8, bytes: []const u8) []u8 {
    const p = a.dupe(u8, std.mem.trimEnd(u8, root, "/")) catch @panic("the gate's path");
    for (bytes) |c| {
        p[p.len - 1] = c;
        if (Io.Dir.cwd().access(io, p, .{})) |_| continue else |_| break;
    }
    return p;
}

fn isArenaShaped(s: ?script.Stop) bool {
    const b = (s orelse return false).budget orelse return false;
    return b == .steps or b == .arena or b == .kept;
}

fn sameStop(x: ?script.Stop, y: ?script.Stop) bool {
    if (x == null or y == null) return x == null and y == null;
    const a = x.?;
    const b = y.?;
    return a.line == b.line and a.column == b.column and a.class == b.class and a.budget == b.budget and
        std.mem.eql(u8, a.function, b.function) and std.mem.eql(u8, a.message, b.message);
}

/// `src` to `dst`, links as links (their targets unread).
fn copyTree(io: Io, a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const d = Io.Dir.cwd();
    try d.createDirPath(io, dst);
    var dir = try d.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const from = try std.fs.path.join(a, &.{ src, e.name });
        const to = try std.fs.path.join(a, &.{ dst, e.name });
        switch (e.kind) {
            .directory => {
                try copyTree(io, a, from, to);
                try keepTime(io, from, to);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const n = try d.readLink(io, from, &buf);
                try d.symLink(io, buf[0..n], to, .{});
            },
            else => {
                const data = try d.readFileAlloc(io, from, a, .unlimited);
                try d.writeFile(io, .{ .sub_path = to, .data = data });
                try keepTime(io, from, to);
            },
        }
    }
}

/// `to` modified when `from` was: a script reads the times (`walk`,
/// `stat`), so the copy keeps them.
fn keepTime(io: Io, from: []const u8, to: []const u8) !void {
    const d = Io.Dir.cwd();
    const st = try d.statFile(io, from, .{});
    try d.setTimestamps(io, to, .{ .modify_timestamp = .{ .new = st.mtime } });
}

/// Whether two trees hold the same names, kinds, bytes and links.
fn sameTree(io: Io, a: std.mem.Allocator, x: []const u8, y: []const u8) !bool {
    const d = Io.Dir.cwd();
    const xs = try listing(io, a, x);
    const ys = try listing(io, a, y);
    if (xs.len != ys.len) return false;
    for (xs, ys) |p, q| {
        if (!std.mem.eql(u8, p.name, q.name) or p.kind != q.kind) return false;
        const from = try std.fs.path.join(a, &.{ x, p.name });
        const to = try std.fs.path.join(a, &.{ y, q.name });
        switch (p.kind) {
            .directory => if (!try sameTree(io, a, from, to)) return false,
            .sym_link => {
                var b1: [4096]u8 = undefined;
                var b2: [4096]u8 = undefined;
                if (!std.mem.eql(u8, b1[0..try d.readLink(io, from, &b1)], b2[0..try d.readLink(io, to, &b2)])) return false;
            },
            else => if (!std.mem.eql(u8, try d.readFileAlloc(io, from, a, .unlimited), try d.readFileAlloc(io, to, a, .unlimited))) return false,
        }
    }
    return true;
}

const Named = struct { name: []const u8, kind: Io.File.Kind };

fn listing(io: Io, a: std.mem.Allocator, path: []const u8) ![]Named {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(Named) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| try out.append(a, .{ .name = try a.dupe(u8, e.name), .kind = e.kind });
    std.mem.sort(Named, out.items, {}, struct {
        fn lt(_: void, p: Named, q: Named) bool {
            return std.mem.lessThan(u8, p.name, q.name);
        }
    }.lt);
    return out.items;
}
