//! **SHALE-GATE, TESTED** (metal-vmm QUEUE 233, chunk 5): the design's
//! grammar, each form it passes and each way it refuses.

const std = @import("std");
const testing = std.testing;
const gate = @import("shale_gate.zig");

fn passes(cmd: []const u8) !void {
    switch (gate.classify(cmd)) {
        .launch => {},
        else => |v| {
            std.debug.print("refused or escaped: {s}\n  {any}\n", .{ cmd, v });
            return error.TestUnexpectedResult;
        },
    }
}

fn refuses(cmd: []const u8, says: []const u8) !void {
    switch (gate.classify(cmd)) {
        .refused => |why| {
            errdefer std.debug.print("{s}\n  said: {s}\n", .{ cmd, why });
            try testing.expect(std.mem.indexOf(u8, why, says) != null);
        },
        else => {
            std.debug.print("passed: {s}\n", .{cmd});
            return error.TestUnexpectedResult;
        },
    }
}

test "gate: the launch, every form the design names" {
    try passes("shale count.shale");
    try passes("shale --verbose rename.shale from=old to=new");
    try passes("shale --budget steps=99 --verbose x.shale");
    try passes("/home/x/zig-webbox/zig-out/bin/shale a.shale");
    try passes("cd ../dog-park && shale a.shale");
    try passes("shale <<'SHALE'\nprint(1)\nSHALE");
    try passes("cd /home/x && shale <<'END_IT'\nprint(\"a $b `c` ; | & < > ( ) * ?\")\nEND_IT  ");
    try passes("shale n=3 <<'SHALE'\nprint(arg(\"n\", 0))\nSHALE\n");
}

test "gate: what it refuses, naming both forms" {
    const both = "`shale [--verbose] [FILE] [NAME=VALUE]... <<'TAG'`";
    try refuses("ls -la", both);
    try refuses("ls -la", "`# want: <tag>: <text>`");
    try refuses("shale -e 'print(1)'", both);
    try refuses("shale a.shale; rm -rf x", both);
    try refuses("shale a.shale && echo done", both);
    try refuses("shale $FILE", both);
    try refuses("shale a.shale | head", both);
    try refuses("shale `x`", both);
    try refuses("SHALE_ROOT=x shale a.shale", both);
    try refuses("/usr/bin/shalex a.shale", both);
    try refuses("shale --budget", both);
    try refuses("shale --budget steps", both);
    try refuses("shale --root here a.shale", both);
    // No dry run, so no `--write` (Steve, 2026-10-17).
    try refuses("shale --write a.shale", both);
    try refuses("cd a b && shale x.shale", both);
    try refuses("cd $HOME && shale x.shale", both);
    try refuses("shale a.shale\nrm x", both);
    try refuses("", both);
}

test "gate: a heredoc's failure modes: unquoted, a lower-case tag, no closer, a closer met twice, text after it" {
    const both = "`shale [--verbose] [FILE] [NAME=VALUE]... <<'TAG'`";
    try refuses("shale <<SHALE\nprint(1)\nSHALE", both);
    try refuses("shale <<\"SHALE\"\nprint(1)\nSHALE", both);
    try refuses("shale <<'shale'\nprint(1)\nshale", both);
    try refuses("shale <<'SHALE'\nprint(1)\n", "no last line `SHALE`");
    try refuses("shale <<'SHALE'\nprint(1)\nSHALE\nrm -rf /\nSHALE", "`SHALE` twice");
    try refuses("shale <<'SHALE'\nprint(1)\nSHALE\nrm -rf /", "no last line `SHALE`");
    try refuses("shale <<'SHALE' x.shale\nprint(1)\nSHALE", both);
    try refuses("shale <<'SHALE'", "no last line `SHALE`");
}

test "gate: the escape, a want or an out-of-scope, its tag and text read" {
    switch (gate.classify("# want: sed-in-place: one replacement in a big file\nsed -i s/a/b/ x")) {
        .escape => |e| {
            try testing.expectEqualStrings("want", e.kind);
            try testing.expectEqualStrings("sed-in-place", e.tag);
            try testing.expectEqualStrings("one replacement in a big file", e.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (gate.classify("# out-of-scope: qemu: a KVM gate\nsudo ./gates.sh")) {
        .escape => |e| try testing.expectEqualStrings("out-of-scope", e.kind),
        else => return error.TestUnexpectedResult,
    }
    const both = "`# want: <tag>: <text>`";
    try refuses("# want: Bad_Tag: x\nls", both);
    try refuses("# want: tag:\nls", both);
    try refuses("# want: tag\nls", both);
    try refuses("# wanted: tag: x\nls", both);
    try refuses(" # want: tag: x\nls", both);
}

test "gate: a log line is one line, tabs and newlines shown, the command's first 160 bytes" {
    var buf: [4096]u8 = undefined;
    const cmd = "# want: t: why\tnot\n" ++ "x" ** 300;
    const line = gate.logLine(&buf, "2026-10-17T12:00:00Z", "sess-1", .{ .kind = "want", .tag = "t", .text = "why\tnot" }, cmd);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(std.mem.startsWith(u8, line, "2026-10-17T12:00:00Z\tsess-1\twant\tt\twhy\\tnot\t# want: t: why\\tnot\\n"));
    try testing.expect(line.len < 4096);
    // A text past the line's room is cut, never the line.
    const long = "y" ** 5000;
    const cut = gate.logLine(&buf, "d", "s", .{ .kind = "want", .tag = "t", .text = long }, "c");
    try testing.expect(cut.len < 4096 and std.mem.endsWith(u8, cut, "\n"));
}

test "gate: the hook's input: the command of Bash and Monitor, any other tool passed, input it cannot read refused" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const h = gate.readHook(a.allocator(), "{\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"shale x.shale\",\"timeout\":5}}").?;
    try testing.expectEqualStrings("shale x.shale", h.command.?);
    try testing.expectEqualStrings("s1", h.session);
    const m = gate.readHook(a.allocator(), "{\"session_id\":\"s1\",\"tool_name\":\"Monitor\",\"tool_input\":{\"command\":\"tail -f x\"}}").?;
    try testing.expectEqualStrings("tail -f x", m.command.?);
    const r = gate.readHook(a.allocator(), "{\"session_id\":\"s1\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}").?;
    try testing.expect(r.command == null);
    try testing.expect(!h.subagent);
    // A subagent's call carries its `agent_id` (the hooks reference,
    // "Common input fields"): local cold agents are exempt (Steve).
    const sub = gate.readHook(a.allocator(), "{\"session_id\":\"s1\",\"agent_id\":\"a-9\",\"agent_type\":\"Explore\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}").?;
    try testing.expect(sub.subagent);
    // `agent_type` alone is a top-level `--agent` session: held.
    try testing.expect(!gate.readHook(a.allocator(), "{\"agent_type\":\"x\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}").?.subagent);
    try testing.expect(!gate.readHook(a.allocator(), "{\"agent_id\":\"\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}").?.subagent);
    try testing.expect(gate.readHook(a.allocator(), "not json") == null);
    try testing.expect(gate.readHook(a.allocator(), "{\"tool_name\":\"Bash\",\"tool_input\":{}}") == null);
}

/// The wrapper on `json`, with `SHALE_GATE` (null: the build's) and a
/// temporary HOME: its exit code and what it said.
fn wrapped(io: std.Io, home: []const u8, bin: []const u8, json: []const u8) !struct { code: u8, err: []u8 } {
    const a = testing.allocator;
    const input = try std.fmt.allocPrint(a, "{s}/input.json", .{home});
    defer a.free(input);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = json });
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("SHALE_GATE", bin);
    try env.put("PATH", "/usr/bin:/bin");
    const script = try std.fmt.allocPrint(a, "sh tools/shale-gate.sh < '{s}'", .{input});
    defer a.free(script);
    const r = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", script }, .environ_map = &env });
    a.free(r.stdout);
    return .{ .code = switch (r.term) {
        .exited => |c| c,
        else => 255,
    }, .err = r.stderr };
}

test "gate: the wrapper: a launch passes, a refusal refuses, an escape is logged once, and a missing binary refuses" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.getcwd(&cwd, cwd.len);
    const here = std.mem.sliceTo(cwd[0..n], 0);
    const home = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ here, &tmp.sub_path });
    defer testing.allocator.free(home);
    const bin = @import("shale_gate_options").shale_gate;
    const launch = try wrapped(io, home, bin, "{\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"shale a.shale\"}}");
    defer testing.allocator.free(launch.err);
    try testing.expectEqual(@as(u8, 0), launch.code);
    const no = try wrapped(io, home, bin, "{\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}");
    defer testing.allocator.free(no.err);
    try testing.expectEqual(@as(u8, 2), no.code);
    try testing.expect(std.mem.indexOf(u8, no.err, "`# want: <tag>: <text>`") != null);
    const want = try wrapped(io, home, bin, "{\"session_id\":\"s7\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"# want: sed-in-place: one edit\\nsed -i s/a/b/ x\"}}");
    defer testing.allocator.free(want.err);
    try testing.expectEqual(@as(u8, 0), want.code);
    const log = try tmp.dir.readFileAlloc(io, ".local/state/shale/wants.tsv", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(log);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "\n"));
    try testing.expect(std.mem.indexOf(u8, log, "\ts7\twant\tsed-in-place\tone edit\t# want: sed-in-place: one edit\\nsed -i s/a/b/ x\n") != null);
    const sub = try wrapped(io, home, bin, "{\"session_id\":\"s\",\"agent_id\":\"a1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}");
    defer testing.allocator.free(sub.err);
    try testing.expectEqual(@as(u8, 0), sub.code);
    const junk = try wrapped(io, home, bin, "not json");
    defer testing.allocator.free(junk.err);
    try testing.expectEqual(@as(u8, 2), junk.code);
    // No binary at all: refused, never passed.
    const gone = try wrapped(io, home, "/no/such/shale-gate", "{\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"shale a.shale\"}}");
    defer testing.allocator.free(gone.err);
    try testing.expectEqual(@as(u8, 2), gone.code);
    try testing.expect(std.mem.indexOf(u8, gone.err, "so the call is refused") != null);
}
