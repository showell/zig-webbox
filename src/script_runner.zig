//! **SHALE ON LINUX** (metal-vmm QUEUE 199; as an agent's tool, QUEUE 229;
//! dogfooded, QUEUE 233): a script run against a folder, a site's data or a
//! code checkout, inside its budgets, so whatever it does is bounded: its
//! steps, its reads, what it prints, what it changes, the programs it runs.
//!
//!     shale [--root DIR] [--write] [--verbose] [--budget NAME=N]... [FILE | -e SOURCE] [NAME=VALUE]...
//!     shale <<'SHALE' ... SHALE        (no FILE, no -e: the script is stdin)
//!     zig build script -- <the same>
//!
//! The root is `--root`, else `SHALE_ROOT`, else the working directory.
//! `now()` is the wall clock; `SHALE_NOW` pins it. **A DRY RUN UNLESS
//! `--write`**: changes are checked and logged, an `edit`'s diff printed,
//! none made, and no program run. The Linux host (`shale_host_linux.zig`)
//! is the core's seam: `host("run", ...)`, `host("real", ...)` and mount
//! paths (`runs:x`), the mounts from `SHALE_MOUNTS` or
//! `~/.config/shale/mounts`. **The preludes after the core's**: the Linux
//! prelude (`run`, `must`, `tail_lines`, ...), the repo's
//! (`.shale/prelude.shale` at the root) and the user's (the file
//! `SHALE_PRELUDE` names, `""` none, else `~/.config/shale/prelude.shale`).
//! The store's bases are set as a server sets
//! them, the root and `<root>/../auth`, so its path limits are measured as
//! the bare-metal host spells them. It prints what the script printed on
//! stdout, then, tersely, how the run ended on stderr (`cli.printReport`).
//! Exit 0 finished, 1 stopped, 2 a command line or a file it could not
//! take. Outside the script module: it may name the host.

const std = @import("std");
const webbox = @import("webbox");
const linux = @import("webbox_linux");
const script = webbox.script;
const cli = script.cli;
const shale_host = linux.shale_host_linux;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var err_buf: [1024]u8 = undefined;
    var ew = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &ew.interface;
    defer err.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    // **THE REAPER** (`shale --reap ...`): a job's, detached by
    // `job_start`; its environment is the job's.
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "--reap")) {
        const env = try shale_host.baseEnv(arena, init.environ_map);
        return linux.shale_jobs.reapMain(arena, argv[2..], env);
    }
    var args_buf: [64]script.Arg = undefined;
    var why_buf: [512]u8 = undefined;
    const c = switch (cli.parse(argv[1..], init.environ_map.get("SHALE_ROOT"), &args_buf, &why_buf)) {
        .command => |c| c,
        .refused => |r| {
            try err.print("shale: {s}\n{s}", .{ r.why, cli.usage });
            return 2;
        },
    };
    const now: i64 = if (init.environ_map.get("SHALE_NOW")) |t| script.builtins.parseInteger(t) orelse {
        try err.print("shale: SHALE_NOW={s} is not an integer\n", .{t});
        return 2;
    } else @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const source = if (c.source) |s| s else if (c.file) |f| std.Io.Dir.cwd().readFileAlloc(io, f, arena, .limited(c.budgets.source_bytes + 1)) catch |e| {
        try err.print("shale: cannot read {s}: {s}\n", .{ f, @errorName(e) });
        return 2;
    } else blk: {
        // A terminal on stdin with no script is a mistake, not a script.
        if (std.Io.File.stdin().isTty(io) catch false) {
            try err.print("shale: no script: a file, -e SOURCE, or the script on stdin\n{s}", .{cli.usage});
            return 2;
        }
        var in_buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().reader(io, &in_buf);
        break :blk r.interface.allocRemaining(arena, .limited(c.budgets.source_bytes + 1)) catch |e| {
            try err.print("shale: cannot read the script on stdin: {s}\n", .{@errorName(e)});
            return 2;
        };
    };
    const root = std.mem.trimEnd(u8, c.root, "/");
    const auth = try std.fs.path.join(gpa, &.{ root, "..", "auth" });
    defer gpa.free(auth);
    webbox.store.setBases(root, auth);

    // **THE LINUX HOST**: the mounts, the environment a program inherits,
    // the root and the working folder as absolute paths.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_abs = try arena.dupe(u8, std.mem.sliceTo(cwd_buf[0..cwd_len], 0));
    const home = init.environ_map.get("HOME") orelse "/";
    var mounts_why: []const u8 = "";
    const mounts = shale_host.loadMounts(arena, io, init.environ_map.get("SHALE_MOUNTS"), home, &mounts_why) catch |e| switch (e) {
        error.Malformed => {
            try err.print("shale: the mounts: {s}\n", .{mounts_why});
            return 2;
        },
        else => return e,
    };
    var host: shale_host.Host = .{
        .alloc = gpa,
        .root_abs = if (root.len == 0) "/" else if (std.fs.path.isAbsolute(root)) root else try std.fs.path.join(arena, &.{ cwd_abs, root }),
        .cwd_abs = cwd_abs,
        .mounts = mounts.mounts,
        .mounts_from = mounts.from,
        .env = try shale_host.baseEnv(arena, init.environ_map),
        .reaper = reaperPath(arena),
    };
    defer host.deinit();
    const seam = host.options();
    var preludes_why: []const u8 = "";
    const preludes = shale_host.loadPreludes(arena, io, host.root_abs, init.environ_map.get("SHALE_PRELUDE"), home, &preludes_why) catch |e| switch (e) {
        error.Malformed => {
            try err.print("shale: the preludes: {s}\n", .{preludes_why});
            return 2;
        },
        else => return e,
    };

    const out = try gpa.alloc(u8, c.budgets.output_bytes);
    defer gpa.free(out);
    var result = script.runWith(io, gpa, if (root.len == 0) "/" else root, source, c.budgets, now, out, .{ .mode = c.mode, .args = c.args, .host = seam.host, .path_hook = seam.path_hook, .preludes = preludes });
    defer result.deinit();

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &ow.interface;
    try w.writeAll(result.output);
    try w.flush();
    const records = try arena.alloc([]const u8, host.records.items.len);
    for (host.records.items, records) |r, *line| line.* = r.line;
    try cli.printReport(&result, cli.scriptName(c), preludes, .{ .verbose = c.verbose, .dry_run = c.mode == .dry_run, .records = records, .budgets = c.budgets }, err);
    return if (result.finished()) 0 else 1;
}

/// This program's own path, for the jobs' reaper: `/proc/self/exe`.
fn reaperPath(a: std.mem.Allocator) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return null;
    return a.dupe(u8, buf[0..n]) catch null;
}
