//! **EACH TEST'S TIME** (`zig build test -Dtest-timing`): a test runner that
//! runs every test as zig's own does (a fresh `testing.allocator` and
//! `testing.io` each, leaks counted) and prints each one's wall time,
//! slowest first, then the total. A gate's cost is the sum of its tests', and
//! this says which tests it is. Runs in the build's "simple" mode: its output
//! is the run's, shown when the step ends.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

const Timed = struct { name: []const u8, ns: u64, ok: bool };

pub fn main(init: std.process.Init.Minimal) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const fns = builtin.test_functions;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const a = gpa.allocator();
    var times = try a.alloc(Timed, fns.len);
    var failed: usize = 0;
    var leaks: usize = 0;
    var total: u64 = 0;
    for (fns, 0..) |t, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        testing.environ = init.environ;
        const from = Io.Clock.now(.awake, io);
        const ok = if (t.func()) |_| true else |e| e == error.SkipZigTest;
        const ns: u64 = @intCast(from.durationTo(Io.Clock.now(.awake, io)).nanoseconds);
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) leaks += 1;
        if (!ok) {
            failed += 1;
            std.debug.print("FAIL {s}\n", .{t.name});
        }
        times[i] = .{ .name = t.name, .ns = ns, .ok = ok };
        total += ns;
    }
    std.mem.sort(Timed, times, {}, struct {
        fn slower(_: void, x: Timed, y: Timed) bool {
            return x.ns > y.ns;
        }
    }.slower);
    for (times) |t| std.debug.print("{d:>9.3} s  {s}\n", .{ @as(f64, @floatFromInt(t.ns)) / 1e9, t.name });
    std.debug.print("{d:>9.3} s  total, {d} tests, {d} failed, {d} leaked\n", .{ @as(f64, @floatFromInt(total)) / 1e9, fns.len, failed, leaks });
    if (failed != 0 or leaks != 0) std.process.exit(1);
}
