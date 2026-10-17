//! **THE FIXTURE PROGRAM** `run`'s tests run (metal-vmm QUEUE 233, chunk
//! 1: "red first against the fixture program the build makes, never
//! /bin/sh"). Each verb is one behaviour a test needs, and nothing else:
//!
//!     shale-fixture lines N [TEXT]   N lines, "TEXT i" (TEXT "line")
//!     shale-fixture exit CODE        exits CODE, printing nothing
//!     shale-fixture env NAME         the variable NAME's value, or "(unset)"
//!     shale-fixture cat              stdin to stdout
//!     shale-fixture sleep MS         sleeps, then prints "woke"
//!     shale-fixture pwd              the working directory
//!     shale-fixture stderr TEXT      TEXT on stderr
//!     shale-fixture kill-self        ends by SIGKILL, its own
//!     shale-fixture ignore-term MS   TERM ignored, then sleeps
//!     shale-fixture spill N          N bytes of 'x' with no newline

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &buf);
    const w = &ow.interface;
    defer w.flush() catch {};
    if (argv.len < 2) return 2;
    const verb = argv[1];
    const arg = if (argv.len > 2) argv[2] else "";
    if (std.mem.eql(u8, verb, "lines")) {
        const n = try std.fmt.parseInt(usize, arg, 10);
        const text = if (argv.len > 3) argv[3] else "line";
        for (1..n + 1) |i| try w.print("{s} {d}\n", .{ text, i });
    } else if (std.mem.eql(u8, verb, "exit")) {
        return try std.fmt.parseInt(u8, arg, 10);
    } else if (std.mem.eql(u8, verb, "env")) {
        try w.print("{s}\n", .{init.environ_map.get(arg) orelse "(unset)"});
    } else if (std.mem.eql(u8, verb, "cat")) {
        var in_buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().reader(io, &in_buf);
        _ = try r.interface.streamRemaining(w);
    } else if (std.mem.eql(u8, verb, "sleep")) {
        try io.sleep(.fromMilliseconds(try std.fmt.parseInt(i64, arg, 10)), .awake);
        try w.writeAll("woke\n");
    } else if (std.mem.eql(u8, verb, "pwd")) {
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.os.linux.getcwd(&path, path.len);
        try w.print("{s}\n", .{std.mem.sliceTo(path[0..n], 0)});
    } else if (std.mem.eql(u8, verb, "stderr")) {
        var eb: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &eb);
        try ew.interface.print("{s}\n", .{arg});
        try ew.interface.flush();
    } else if (std.mem.eql(u8, verb, "kill-self")) {
        try w.flush();
        _ = std.os.linux.kill(std.os.linux.getpid(), .KILL);
    } else if (std.mem.eql(u8, verb, "ignore-term")) {
        const ignore: std.os.linux.Sigaction = .{ .handler = .{ .handler = std.os.linux.SIG.IGN }, .mask = std.os.linux.sigemptyset(), .flags = 0 };
        _ = std.os.linux.sigaction(.TERM, &ignore, null);
        try w.writeAll("ignoring\n");
        try w.flush();
        try io.sleep(.fromMilliseconds(try std.fmt.parseInt(i64, arg, 10)), .awake);
    } else if (std.mem.eql(u8, verb, "spill")) {
        const n = try std.fmt.parseInt(usize, arg, 10);
        for (0..n) |_| try w.writeByte('x');
    } else return 2;
    return 0;
}
