//! **SHALE ON LINUX** (metal-vmm QUEUE 199; as an agent's tool, QUEUE 229):
//! a script run against a folder, a site's data or a code checkout, inside
//! its budgets, so whatever it does is bounded: its steps, its reads, what
//! it prints, what it changes.
//!
//!     shale [--root DIR] [--write] [--budget NAME=N]... (FILE | -e SOURCE) [NAME=VALUE]...
//!     zig build script -- <the same>
//!
//! The root is `--root`, else `SHALE_ROOT`, else the working directory;
//! `SHALE_NOW` is the integer `now()` answers (0 unset). **A DRY RUN UNLESS
//! `--write`**: changes are checked and logged, an `edit`'s diff printed,
//! and none made. The store's bases are set as a server sets them, the root
//! and `<root>/../auth`, so its path limits are measured as the bare-metal
//! host spells them. It prints what the script printed on stdout, then the
//! effects and how the run ended on stderr. Exit 0 finished, 1 stopped, 2
//! a command line or a file it could not take. Outside the script module:
//! it may name the host.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const cli = script.cli;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var err_buf: [1024]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &err_buf);
    const err = &ew.interface;
    defer err.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
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
    } else 0;
    const source = if (c.source) |s| s else std.Io.Dir.cwd().readFileAlloc(io, c.file.?, init.arena.allocator(), .limited(c.budgets.source_bytes + 1)) catch |e| {
        try err.print("shale: cannot read {s}: {s}\n", .{ c.file.?, @errorName(e) });
        return 2;
    };
    const root = std.mem.trimEnd(u8, c.root, "/");
    const auth = try std.fs.path.join(gpa, &.{ root, "..", "auth" });
    defer gpa.free(auth);
    webbox.store.setBases(root, auth);

    const out = try gpa.alloc(u8, c.budgets.output_bytes);
    defer gpa.free(out);
    var result = script.runWith(io, gpa, if (root.len == 0) "/" else root, source, c.budgets, now, out, .{ .mode = c.mode, .args = c.args });
    defer result.deinit();

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;
    try w.writeAll(result.output);
    try w.flush();
    try script.report(&result, c.file orelse "-e", err);
    if (c.mode == .dry_run and result.effects.len > 0)
        try err.print("── a dry run: {d} change{s} logged, none made; --write makes them\n", .{ result.effects.len, if (result.effects.len == 1) "" else "s" });
    return if (result.finished()) 0 else 1;
}
