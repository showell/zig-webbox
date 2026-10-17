//! **SHALE'S HOT PATHS, TIMED** (metal-vmm QUEUE 208(a)): a few scripts
//! that each lean on one path of the interpreter (a loop's iteration, a
//! list's and a map's index, a call, building a string), each run as many
//! times as fit in about half a second, its time and its steps printed:
//!
//!     zig build script-bench        (ReleaseSafe)
//!
//! Each on the tree-walker and on the VM (metal-vmm QUEUE 211).
//!
//! Outside the script module: it may name the host.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;

const cases = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "a loop's iteration", .src =
    \\local x = 0
    \\for i = 1, 1000000 do x = x + i end
    \\print(x)
    },
    .{ .name = "a while loop", .src =
    \\local i = 0
    \\while i < 500000 do i = i + 1 end
    \\print(i)
    },
    .{ .name = "a list, built and indexed", .src =
    \\local l = {}
    \\for i = 1, 200000 do push(l, i) end
    \\local s = 0
    \\for i = 1, #l do s = s + l[i] end
    \\for x in l do s = s + x end
    \\print(s)
    },
    .{ .name = "a map's fields", .src =
    \\local m = {a = 1, b = 2, c = 3, size = 4}
    \\local s = 0
    \\for i = 1, 300000 do s = s + m.size + m["a"] end
    \\print(s)
    },
    .{ .name = "calls", .src =
    \\function fib(n)
    \\  if n < 2 then return n end
    \\  return fib(n - 1) + fib(n - 2)
    \\end
    \\print(fib(22))
    },
    .{ .name = "a string built by `..`", .src =
    \\local s = ""
    \\for i = 1, 5000 do s = s .. "line " .. i .. "\n" end
    \\print(#s)
    },
    .{ .name = "count_in over 8 MiB", .src =
    \\print(count_in("bench-8m", "ab"))
    },
    .{ .name = "read 8 MiB whole", .src =
    \\print(#read("bench-8m"))
    },
    .{ .name = "a string built by join", .src =
    \\local parts = {}
    \\for i = 1, 50000 do push(parts, "line " .. i) end
    \\print(#join(parts, "\n"))
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const out = try gpa.alloc(u8, 4096);
    defer gpa.free(out);
    var buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &buf);
    const w = &ow.interface;
    const budgets: script.Budgets = .{ .steps = 100_000_000, .arena_bytes = 256 * 1024 * 1024, .call_bytes = 64 * 1024 * 1024 };
    // The scans' file, in the working folder (the bench's root), removed
    // after.
    const big = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = "abc\n"[i % 4];
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "bench-8m", .data = big });
    defer std.Io.Dir.cwd().deleteFile(io, "bench-8m") catch {};
    for (cases) |c| {
        // **WALKER AGAINST VM** (metal-vmm QUEUE 211): the same case on
        // each engine; their steps are the same by the tests' gate.
        var ns_of: [2]f64 = undefined;
        for ([_]script.Engine{ .walker, .vm }, 0..) |engine, k| {
            var runs: u64 = 0;
            var steps: u64 = 0;
            var arena: usize = 0;
            const t0 = std.Io.Clock.awake.now(io).nanoseconds;
            while (runs < 3 or std.Io.Clock.awake.now(io).nanoseconds - t0 < std.time.ns_per_s / 2) : (runs += 1) {
                var r = script.runOn(engine, io, gpa, ".", c.src, budgets, 0, out, .{});
                defer r.deinit();
                if (r.stop) |s| {
                    try w.print("{s}: stopped {d}:{d}: {s}\n", .{ c.name, s.line, s.column, s.message });
                    break;
                }
                steps = r.steps;
                arena = r.arena_bytes;
            }
            const ns: f64 = @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds - t0);
            const per_run = ns / @as(f64, @floatFromInt(runs));
            ns_of[k] = per_run;
            try w.print("{s:<28} {s:<6} {d:>9.2} ms  {d:>10} steps  {d:>6.1} ns a step  {d:>8} KiB arena\n", .{ c.name, @tagName(engine), per_run / 1e6, steps, per_run / @as(f64, @floatFromInt(@max(steps, 1))), arena / 1024 });
        }
        try w.print("{s:<28} the VM in {d:.2}x the walker's time\n", .{ "", ns_of[1] / ns_of[0] });
        try w.flush();
    }
}
