//! **EVERY BUILTIN CHARGES AT LEAST IN PROPORTION TO ITS WORK** (metal-vmm
//! QUEUE 208(e)): for each builtin whose work grows with its input, the
//! call's own steps (the whole script's, less its setup's) at size N and at
//! 4N, and the growth must be at least a step for each byte or item added.
//! A builtin whose work does not grow is listed as constant, with why. The
//! table must name every builtin (checked at compile time), so a builtin
//! added to the language is added here too.

const std = @import("std");
const script = @import("script.zig");
const ast = script.ast;
const testing = std.testing;

const Grows = enum {
    /// The work grows with N: at least a step a unit of N.
    scales,
    /// The work is the same whatever N (the reason is in `why`).
    constant,
};

/// What the store holds for a case: nothing, a file `big` of N bytes, or
/// a folder `many` of N files.
const Setup = enum { none, big_file, many_files };

const Case = struct {
    b: ast.Builtin,
    grows: Grows,
    /// Run first, alone, to subtract: what the call needs made. `N` in it
    /// is the size.
    setup: []const u8 = "",
    /// The call, after the setup. `N` in it is the size.
    call: []const u8 = "",
    store: Setup = .none,
    why: []const u8 = "",
    /// How many units of N a step must cover at most: 1, or for bulk byte
    /// work (`bi.bytes_per_step`) 16.
    per: u64 = 1,
};

const cases = [_]Case{
    // the store
    .{ .b = .ls, .grows = .scales, .store = .many_files, .call = "local x = ls(\"many\")" },
    .{ .b = .stat, .grows = .constant, .why = "one stat, its path's bytes charged" },
    .{ .b = .exists, .grows = .constant, .why = "one lookup, its path's bytes charged" },
    .{ .b = .is_dir, .grows = .constant, .why = "one stat, its path's bytes charged" },
    .{ .b = .read, .grows = .scales, .per = script.builtins.bytes_per_step, .store = .big_file, .call = "local x = read(\"big\")" },
    .{ .b = .count_lines, .grows = .scales, .per = script.builtins.bytes_per_step, .store = .big_file, .call = "local x = count_lines(\"big\")" },
    .{ .b = .count_in, .grows = .scales, .per = script.builtins.bytes_per_step, .store = .big_file, .call = "local x = count_in(\"big\", \"ab\")" },
    .{ .b = .find_in, .grows = .scales, .per = script.builtins.bytes_per_step, .store = .big_file, .call = "local x = find_in(\"big\", \"zz\")" },
    .{ .b = .replace, .grows = .scales, .setup = "local s = rep(\"x\", N)", .call = "replace(\"out\", s)" },
    .{ .b = .append, .grows = .scales, .setup = "local s = rep(\"x\", N)", .call = "append(\"out\", s)" },
    .{ .b = .mkdir, .grows = .constant, .why = "one folder, its path's bytes charged" },
    .{ .b = .remove, .grows = .constant, .why = "one file, its path's bytes charged" },
    .{ .b = .remove_tree, .grows = .constant, .why = "the tree's size is the store's to bound (max_depth, the volume); a script may call it at most `changes` times" },
    .{ .b = .walk, .grows = .scales, .store = .many_files, .call = "local x = walk(\"many\")" },
    // strings
    .{ .b = .split, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a,\", N)", .call = "local x = split(s, \",\")" },
    .{ .b = .join, .grows = .scales, .setup = "local l = {} for i = 1, N do push(l, \"ab\") end", .call = "local x = join(l, \",\")" },
    .{ .b = .starts_with, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a\", N)", .call = "local x = starts_with(s, \"b\")" },
    .{ .b = .ends_with, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a\", N)", .call = "local x = ends_with(s, \"b\")" },
    .{ .b = .contains, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a\", N)", .call = "local x = contains(s, \"b\")" },
    .{ .b = .find, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a\", N)", .call = "local x = find(s, \"b\")" },
    .{ .b = .sub, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = sub(s, 1, -1)" },
    .{ .b = .trim, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = trim(s)" },
    .{ .b = .path, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = path(s, s)" },
    .{ .b = .basename, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = basename(s)" },
    .{ .b = .strip_suffix, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = strip_suffix(s, s)" },
    .{ .b = .upper, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = upper(s)" },
    .{ .b = .lower, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = lower(s)" },
    .{ .b = .tostring, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = tostring(s)" },
    .{ .b = .tonumber, .grows = .scales, .setup = "local s = rep(\"0\", N) .. \"1\"", .call = "local x = tonumber(s)" },
    .{ .b = .lines, .grows = .scales, .setup = "local s = rep(\"a\\n\", N)", .call = "local x = lines(s)" },
    .{ .b = .words, .grows = .scales, .setup = "local s = rep(\"a \", N)", .call = "local x = words(s)" },
    .{ .b = .like, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "local x = like(s, \"*b\")" },
    .{ .b = .rep, .grows = .scales, .call = "local x = rep(\"ab\", N)" },
    .{ .b = .substitute, .grows = .scales, .per = script.builtins.bytes_per_step, .setup = "local s = rep(\"a\", N)", .call = "local x = substitute(s, \"a\", \"b\")" },
    // numbers
    .{ .b = .min, .grows = .constant, .why = "at most four integers" },
    .{ .b = .max, .grows = .constant, .why = "at most four integers" },
    .{ .b = .abs, .grows = .constant, .why = "one integer" },
    // dates and formatting
    .{ .b = .date, .grows = .constant, .why = "one integer to twenty bytes" },
    .{ .b = .seconds, .grows = .constant, .why = "a time is at most a few dozen bytes; longer is refused, its bytes charged" },
    .{ .b = .human, .grows = .constant, .why = "one integer" },
    .{ .b = .pad, .grows = .scales, .call = "local x = pad(\"a\", N)" },
    .{ .b = .table, .grows = .scales, .setup = "local rows = {} for i = 1, N do push(rows, {a = i}) end", .call = "local x = table(rows, {\"a\"})" },
    // lists and maps
    .{ .b = .push, .grows = .constant, .why = "one item, amortized" },
    .{ .b = .sort, .grows = .scales, .setup = "local l = {} for i = 1, N do push(l, N - i) end", .call = "sort(l)" },
    .{ .b = .keys, .grows = .scales, .setup = "local m = {} for i = 1, N do m[\"k\" .. i] = i end", .call = "local x = keys(m)" },
    .{ .b = .has_key, .grows = .scales, .setup = "local m = {a = 1} local k = rep(\"k\", N)", .call = "local x = has_key(m, k)" },
    .{ .b = .count, .grows = .constant, .why = "a length the table keeps" },
    .{ .b = .reverse, .grows = .scales, .setup = "local l = {} for i = 1, N do push(l, i) end", .call = "reverse(l)" },
    .{ .b = .take, .grows = .scales, .setup = "local l = {} for i = 1, N do push(l, i) end", .call = "local x = take(l, N)" },
    // the host
    .{ .b = .now, .grows = .constant, .why = "an integer the host handed in" },
    .{ .b = .budget, .grows = .constant, .why = "six counters" },
    .{ .b = .yield, .grows = .constant, .why = "its argument checked; in the VM the copy it makes is charged a step a value and a step for 16 bytes, by collect.zig" },
    .{ .b = .print, .grows = .scales, .setup = "local s = rep(\"a\", N)", .call = "print(s)" },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(ast.Builtin)) |b| {
        var n = 0;
        for (cases) |c| {
            if (c.b == b) n += 1;
        }
        if (n != 1) @compileError("charge_test.zig: the builtin `" ++ @tagName(b) ++ "` needs exactly one case");
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    root: []const u8,

    fn init(self: *Fixture, store: Setup, n: usize) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        const io = self.threaded.io();
        try self.tmp.dir.createDirPath(io, "data/many");
        switch (store) {
            .none => {},
            .big_file => {
                const data = try testing.allocator.alloc(u8, n);
                defer testing.allocator.free(data);
                for (data, 0..) |*c, i| c.* = "ab\n"[i % 3];
                try self.tmp.dir.writeFile(io, .{ .sub_path = "data/big", .data = data });
            },
            .many_files => for (0..n) |i| {
                var name: [64]u8 = undefined;
                try self.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "data/many/f{d:0>6}", .{i}), .data = "x" });
            },
        }
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    /// The steps `src` (with `N` as `n`) takes; it must finish.
    fn steps(self: *Fixture, src: []const u8, n: usize) !u64 {
        return (try self.measure(src, n)).steps;
    }

    const Measured = struct { steps: u64, work: u64 };

    /// The steps `src` takes, and the work it does (`Run.work`).
    fn measure(self: *Fixture, src: []const u8, n: usize) !Measured {
        var num: [24]u8 = undefined;
        const text = try std.mem.replaceOwned(u8, testing.allocator, src, "N", try std.fmt.bufPrint(&num, "{d}", .{n}));
        defer testing.allocator.free(text);
        const out = try testing.allocator.alloc(u8, 256 * 1024);
        defer testing.allocator.free(out);
        var r = script.run(self.threaded.io(), testing.allocator, self.root, text, .{}, 0, out);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d}: {s}\n", .{ text, s.line, s.column, s.message });
            return error.TestUnexpectedResult;
        }
        return .{ .steps = r.steps, .work = r.work };
    }
};

/// The call's own steps at size `n`: the whole script's less its setup's.
fn callSteps(c: Case, n: usize) !u64 {
    var f: Fixture = undefined;
    try f.init(c.store, n);
    defer f.deinit();
    const setup = try f.steps(c.setup, n);
    const whole_src = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ c.setup, c.call });
    defer testing.allocator.free(whole_src);
    return try f.steps(whole_src, n) - setup;
}

/// **THE OPERATORS, TOO** (209): what grows with a value's size, as the
/// builtins are held to.
const op_cases = [_]struct { name: []const u8, setup: []const u8, call: []const u8 }{
    .{ .name = "a map's key, read", .setup = "local k = rep(\"k\", N) local m = {} m[k] = 1", .call = "local x = m[k]" },
    .{ .name = "a map's key, set", .setup = "local k = rep(\"k\", N) local m = {}", .call = "m[k] = 1" },
    .{ .name = "`..`", .setup = "local s = rep(\"a\", N)", .call = "local x = s .. s" },
    .{ .name = "`<` on strings", .setup = "local s = rep(\"a\", N) local t = rep(\"a\", N)", .call = "local x = s < t" },
    .{ .name = "`==` on strings", .setup = "local s = rep(\"a\", N) local t = rep(\"a\", N)", .call = "local x = s == t" },
};

test "every operator whose work grows with a value charges at least a step a byte more" {
    const n = 500;
    for (op_cases) |c| {
        const case: Case = .{ .b = .now, .grows = .scales, .setup = c.setup, .call = c.call };
        const small = try callSteps(case, n);
        const large = try callSteps(case, 4 * n);
        if (large < small + 3 * n) {
            std.debug.print("{s}: {d} steps at {d}, {d} at {d}: less than a step a unit more\n", .{ c.name, small, n, large, 4 * n });
            return error.TestUnexpectedResult;
        }
    }
}

test "every builtin whose work grows charges at least a step for each byte or item more, or for each 16 of bulk byte work (each constant one says why)" {
    const n = 500;
    for (cases) |c| switch (c.grows) {
        .constant => try testing.expect(c.why.len > 0),
        .scales => {
            const small = try callSteps(c, n);
            const large = try callSteps(c, 4 * n);
            if (large < small + 3 * n / c.per) {
                std.debug.print("`{s}`: {d} steps at {d}, {d} at {d}: less than a step for {d} units more\n", .{ @tagName(c.b), small, n, large, 4 * n, c.per });
                return error.TestUnexpectedResult;
            }
        },
    };
}

/// The call's own steps and work at size `n`: the whole script's less its
/// setup's.
fn callMeasure(store: Setup, setup: []const u8, call: []const u8, n: usize) !Fixture.Measured {
    var f: Fixture = undefined;
    try f.init(store, n);
    defer f.deinit();
    const before = try f.measure(setup, n);
    const whole_src = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ setup, call });
    defer testing.allocator.free(whole_src);
    const all = try f.measure(whole_src, n);
    return .{ .steps = all.steps - before.steps, .work = all.work - before.work };
}

/// **THE UPPER BOUND** (209(c)): the most units of work a step may buy.
/// A unit is a byte touched, a compare, a place a search stops, an item
/// made; bulk byte work buys 16 a step, and a search's stops and compares
/// sit on top. An uncharged loop's work grows with nothing to match it.
const work_per_step_most = 40;

/// Shapes that are hard on the searches and scans: dense matches, near
/// misses, many pieces.
const hard_cases = [_]struct { name: []const u8, store: Setup = .none, setup: []const u8, call: []const u8 }{
    .{ .name = "substitute, a match a byte", .setup = "local s = rep(\"a\", N)", .call = "local x = substitute(s, \"a\", \"\")" },
    .{ .name = "split, a piece a byte", .setup = "local s = rep(\"a\", N)", .call = "local x = split(s, \"a\")" },
    .{ .name = "find, a near-match at every byte", .setup = "local s = rep(\"a\", N)", .call = "local x = find(s, \"aaaab\")" },
    .{ .name = "contains, a long near-match", .setup = "local s = rep(\"a\", N)", .call = "local x = contains(s, rep(\"a\", 40) .. \"b\")" },
    .{ .name = "count_in, a match every three bytes", .store = .big_file, .setup = "", .call = "local x = count_in(\"big\", \"a\")" },
    .{ .name = "count_lines", .store = .big_file, .setup = "", .call = "local x = count_lines(\"big\")" },
    .{ .name = "find_in, a near-match", .store = .big_file, .setup = "", .call = "local x = find_in(\"big\", \"ab\\nab\\nab\\nX\")" },
    .{ .name = "lines, a line a byte", .setup = "local s = rep(\"\\n\", N)", .call = "local x = lines(s)" },
    .{ .name = "like, backtracking", .setup = "local s = rep(\"a\", N)", .call = "local x = like(s, \"*a*a*b\")" },
    .{ .name = "sort, strings sharing a prefix", .setup = "local l = {} for i = 1, N do push(l, rep(\"x\", 20) .. (N - i)) end", .call = "sort(l)" },
};

test "steps bound the work: no builtin or operator does more than a fixed amount of work a step, on its hardest shapes (209(c))" {
    const n = 2000;
    var worst: f64 = 0;
    for (cases) |c| if (c.grows == .scales) {
        const m = try callMeasure(c.store, c.setup, c.call, n);
        try within(@tagName(c.b), m, &worst);
    };
    for (op_cases) |c| try within(c.name, try callMeasure(.none, c.setup, c.call, n), &worst);
    for (hard_cases) |c| try within(c.name, try callMeasure(c.store, c.setup, c.call, n), &worst);
    // Said only when a case breaks the bound (`within`), never on a pass
    // (the box, 209): the worst today is 30.3, well inside it.
    try testing.expect(worst <= work_per_step_most);
}

fn within(name: []const u8, m: Fixture.Measured, worst: *f64) !void {
    const ratio = @as(f64, @floatFromInt(m.work)) / @as(f64, @floatFromInt(@max(m.steps, 1)));
    worst.* = @max(worst.*, ratio);
    if (m.work > work_per_step_most * @max(m.steps, 1)) {
        std.debug.print("{s}: {d} work for {d} steps\n", .{ name, m.work, m.steps });
        return error.TestUnexpectedResult;
    }
}
