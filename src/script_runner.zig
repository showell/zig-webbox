//! **THE SHALE RUNNER, FOR LINUX** (metal-vmm QUEUE 199): how a script is
//! written and tried, against a copy of a site's data, before there is an
//! endpoint to send it to.
//!
//!     SHALE_ROOT=/path/to/a/copy/of/data zig build script -- examples/topics.shale
//!
//! `SHALE_ROOT` is the data root (required); `SHALE_NOW`, the integer
//! `now()` answers (default 0). The store's bases are set as a server sets
//! them, the root and `<root>/../auth`, so its path limits are measured as
//! the bare-metal host spells them. It prints what the script printed, the
//! effects log, and how the run ended. Exit 0 finished, 1 stopped, 2 a
//! runner's own error. Outside the script module: it may name the host.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var err_buf: [1024]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &err_buf);
    const err = &ew.interface;
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        try err.writeAll("usage: SHALE_ROOT=<data folder> shale <script.shale>  (SHALE_NOW=<integer> sets now())\n");
        return 2;
    }
    const root = init.environ_map.get("SHALE_ROOT") orelse {
        try err.writeAll("shale: SHALE_ROOT is not set: the data folder a script's paths are relative to\n");
        return 2;
    };
    const now: i64 = if (init.environ_map.get("SHALE_NOW")) |t| script.builtins.parseInteger(t) orelse {
        try err.print("shale: SHALE_NOW={s} is not an integer\n", .{t});
        return 2;
    } else 0;
    const source = std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(script.Budgets.default_source_bytes + 1)) catch |e| {
        try err.print("shale: cannot read {s}: {s}\n", .{ args[1], @errorName(e) });
        return 2;
    };
    defer gpa.free(source);

    const auth = try std.fs.path.join(gpa, &.{ root, "..", "auth" });
    defer gpa.free(auth);
    webbox.store.setBases(root, auth);

    const out = try gpa.alloc(u8, script.Budgets.default_output_bytes);
    defer gpa.free(out);
    var result = script.run(io, gpa, root, source, .{}, now, out);
    defer result.deinit();

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;
    try w.writeAll(result.output);
    try w.flush();
    try err.print("── effects ({d}) ──\n", .{result.effects.len});
    for (result.effects) |e| try err.print("{s} {s}: {s}\n", .{ e.op, e.path, e.outcome });
    if (result.stop) |s| {
        try err.print("── stopped at {s}:{d}:{d}: {s}{s}{s}: {s} ({d} steps)\n", .{ args[1], s.line, s.column, @tagName(s.class), if (s.budget != null) " " else "", if (s.budget) |b| @tagName(b) else "", s.message, result.steps });
        return 1;
    }
    try err.print("── finished ({d} steps)\n", .{result.steps});
    return 0;
}
