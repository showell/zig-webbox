//! **THE LINUX TOOL'S COMMAND LINE, READ** (metal-vmm QUEUE 229, chunk 4):
//! what `shale` was asked, pure, so it is tested here and the runner
//! (`src/script_runner.zig`) only does the I/O.
//!
//!     shale [--root DIR] [--write] [--budget NAME=N]... (FILE | -e SOURCE) [NAME=VALUE]...
//!
//! **A DRY RUN UNLESS `--write`**: the run's changes are checked, counted,
//! logged and, for `edit`, shown as a diff, and none is made.

const std = @import("std");
const interp = @import("interp.zig");
const builtins = @import("builtins.zig");
const process = @import("process.zig");

pub const usage =
    \\usage: shale [--root DIR] [--write] [--budget NAME=N]... (FILE | -e SOURCE) [NAME=VALUE]...
    \\  --root DIR        the folder the script's paths are relative to (SHALE_ROOT, or here)
    \\  --write           make the changes; without it the run is dry: they are logged, not made
    \\  --budget NAME=N   one budget: steps, reads, read_bytes, output_bytes, changes,
    \\                    change_bytes, arena_bytes, call_bytes, call_entries
    \\  -e SOURCE         the script itself, in place of a file
    \\  NAME=VALUE        a value the script reads with arg("NAME", default)
    \\
;

pub const Command = struct {
    /// The data root: `--root`, else the caller's `SHALE_ROOT`, else ".".
    root: []const u8,
    /// The file to read, or null for `-e`'s source.
    file: ?[]const u8 = null,
    source: ?[]const u8 = null,
    mode: process.Mode = .dry_run,
    budgets: interp.Budgets = .{},
    /// Into the caller's buffer.
    args: []const interp.Arg = &.{},
};

/// What went wrong reading it, said in `why`.
pub const Refused = struct { why: []const u8 };

/// The budgets a command line may set, by name.
const settable = [_][]const u8{ "steps", "reads", "read_bytes", "output_bytes", "changes", "change_bytes", "arena_bytes", "call_bytes", "call_entries" };

/// **THE COMMAND LINE** (`argv` past the program's name), the caller's
/// `SHALE_ROOT` if it has one, the `NAME=VALUE`s into `args_buf`; or why
/// not, in `why_buf`.
pub fn parse(argv: []const []const u8, env_root: ?[]const u8, args_buf: []interp.Arg, why_buf: []u8) union(enum) { command: Command, refused: Refused } {
    var c: Command = .{ .root = env_root orelse "." };
    var n_args: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--write")) {
            c.mode = .atomic;
        } else if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "--budget") or std.mem.eql(u8, a, "-e")) {
            if (i + 1 == argv.len) return refuse(why_buf, "{s} needs a value", .{a});
            i += 1;
            const v = argv[i];
            if (std.mem.eql(u8, a, "--root")) {
                c.root = v;
            } else if (std.mem.eql(u8, a, "-e")) {
                if (c.file != null or c.source != null) return refuse(why_buf, "one script: a file or -e, not both", .{});
                c.source = v;
            } else {
                const eq = std.mem.indexOfScalar(u8, v, '=') orelse return refuse(why_buf, "--budget {s}: it is NAME=N", .{v});
                const name = v[0..eq];
                const n = builtins.parseInteger(v[eq + 1 ..]) orelse return refuse(why_buf, "--budget {s}: {s} is not a number", .{ v, v[eq + 1 ..] });
                if (n < 1) return refuse(why_buf, "--budget {s}: a budget is at least 1", .{v});
                if (!setBudget(&c.budgets, name, @intCast(n))) return refuse(why_buf, "--budget {s}: no budget is called {s}", .{ v, name });
            }
        } else if (std.mem.startsWith(u8, a, "-")) {
            return refuse(why_buf, "{s} is not an option", .{a});
        } else if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            if (c.file == null and c.source == null) return refuse(why_buf, "{s} before the script: the script first, then NAME=VALUE", .{a});
            if (eq == 0) return refuse(why_buf, "{s}: a value needs a name", .{a});
            if (n_args == args_buf.len) return refuse(why_buf, "more than {d} values", .{args_buf.len});
            args_buf[n_args] = .{ .name = a[0..eq], .value = a[eq + 1 ..] };
            n_args += 1;
        } else {
            if (c.file != null or c.source != null) return refuse(why_buf, "one script: {s} is a second", .{a});
            c.file = a;
        }
    }
    if (c.file == null and c.source == null) return refuse(why_buf, "no script: a file, or -e SOURCE", .{});
    c.args = args_buf[0..n_args];
    return .{ .command = c };
}

fn refuse(buf: []u8, comptime fmt: []const u8, args: anytype) @typeInfo(@TypeOf(parse)).@"fn".return_type.? {
    return .{ .refused = .{ .why = std.fmt.bufPrint(buf, fmt, args) catch fmt } };
}

fn setBudget(b: *interp.Budgets, name: []const u8, n: u64) bool {
    inline for (settable) |field| {
        if (std.mem.eql(u8, name, field)) {
            const T = @TypeOf(@field(b, field));
            @field(b, field) = std.math.cast(T, n) orelse std.math.maxInt(T);
            return true;
        }
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parsed(argv: []const []const u8, env_root: ?[]const u8) !Command {
    const S = struct {
        var args: [8]interp.Arg = undefined;
        var why: [256]u8 = undefined;
    };
    return switch (parse(argv, env_root, &S.args, &S.why)) {
        .command => |c| c,
        .refused => error.Refused,
    };
}

fn refused(argv: []const []const u8) ![]const u8 {
    const S = struct {
        var args: [2]interp.Arg = undefined;
        var why: [256]u8 = undefined;
    };
    return switch (parse(argv, null, &S.args, &S.why)) {
        .command => error.NotRefused,
        .refused => |r| r.why,
    };
}

test "cli: a file and its values, a dry run rooted here unless told otherwise" {
    const c = try parsed(&.{ "count.shale", "dir=src", "n=3" }, null);
    try testing.expectEqualStrings(".", c.root);
    try testing.expectEqualStrings("count.shale", c.file.?);
    try testing.expectEqual(process.Mode.dry_run, c.mode);
    try testing.expectEqual(@as(usize, 2), c.args.len);
    try testing.expectEqualStrings("dir", c.args[0].name);
    try testing.expectEqualStrings("3", c.args[1].value);
}

test "cli: --root, SHALE_ROOT, --write, --budget, -e" {
    const c = try parsed(&.{ "--write", "--budget", "steps=99", "--budget", "reads=7", "-e", "print(1)", "x=" }, "/data");
    try testing.expectEqualStrings("/data", c.root);
    try testing.expectEqual(process.Mode.atomic, c.mode);
    try testing.expectEqual(@as(u64, 99), c.budgets.steps);
    try testing.expectEqual(@as(u64, 7), c.budgets.reads);
    try testing.expectEqualStrings("print(1)", c.source.?);
    try testing.expectEqualStrings("", c.args[0].value);
    const r = try parsed(&.{ "--root", "here", "s.shale" }, "/data");
    try testing.expectEqualStrings("here", r.root);
}

test "cli: what it refuses, said" {
    try testing.expectEqualStrings("no script: a file, or -e SOURCE", try refused(&.{}));
    try testing.expectEqualStrings("--wrte is not an option", try refused(&.{ "--wrte", "a.shale" }));
    try testing.expectEqualStrings("--budget stepz=3: no budget is called stepz", try refused(&.{ "--budget", "stepz=3", "a.shale" }));
    try testing.expectEqualStrings("--budget steps=x: x is not a number", try refused(&.{ "--budget", "steps=x", "a.shale" }));
    try testing.expectEqualStrings("--budget steps=0: a budget is at least 1", try refused(&.{ "--budget", "steps=0", "a.shale" }));
    try testing.expectEqualStrings("one script: b.shale is a second", try refused(&.{ "a.shale", "b.shale" }));
    try testing.expectEqualStrings("one script: a file or -e, not both", try refused(&.{ "a.shale", "-e", "x" }));
    try testing.expectEqualStrings("n=1 before the script: the script first, then NAME=VALUE", try refused(&.{ "n=1", "a.shale" }));
    try testing.expectEqualStrings("--root needs a value", try refused(&.{"--root"}));
    try testing.expectEqualStrings("more than 2 values", try refused(&.{ "a.shale", "a=1", "b=2", "c=3" }));
}
