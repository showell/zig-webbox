//! **THE CLI'S REPORT, ON RUNS** (metal-vmm QUEUE 233, chunk 1): terse,
//! and a prelude's line by the prelude's name (`cli.printReport`).

const std = @import("std");
const script = @import("script.zig");
const cli = script.cli;
const parse_mod = @import("parse.zig");
const testing = std.testing;
const printReport = cli.printReport;
const How = cli.How;

fn reported(source: []const u8, file_name: []const u8, preludes: []const parse_mod.Prelude, how: How) ![]const u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var out: [1024]u8 = undefined;
    var r = script.runWith(threaded.io(), testing.allocator, "/no/such/root", source, .{ .steps = 1000 }, 0, &out, .{ .preludes = preludes });
    defer r.deinit();
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    var h = how;
    h.budgets = .{ .steps = 1000 };
    try printReport(&r, file_name, preludes, h, &w.writer);
    return w.toOwnedSlice();
}

test "cli: terse: a run that finished well inside says nothing; a stop, where, the prelude's name too" {
    const quiet = try reported("print(1)", "a.shale", &.{}, .{});
    defer testing.allocator.free(quiet);
    try testing.expectEqualStrings("", quiet);
    const verbose = try reported("print(1)", "a.shale", &.{}, .{ .verbose = true, .records = &.{"run x -> exit 0 (1 ms)"} });
    defer testing.allocator.free(verbose);
    try testing.expectEqualStrings("── effects (0) ──\n── ran ──\nrun x -> exit 0 (1 ms)\n── finished (5 steps)\n── used: 5 of 1000 steps, 0 of 10000 reads, 0 of 67108864 read bytes, 2 of 262144 output bytes\n", verbose);
    // Past half a budget, the used line.
    const busy = try reported("local i = 0 while i < 100 do i = i + 1 end", "a.shale", &.{}, .{});
    defer testing.allocator.free(busy);
    try testing.expect(std.mem.startsWith(u8, busy, "── used: "));
    // A stop in a later prelude's function is that prelude's line.
    const pre = [_]parse_mod.Prelude{.{ .name = "the Linux prelude", .source = "function boom(x)\n  return x + {}\nend\n" }};
    const stop = try reported("\nboom(1)", "stdin", &pre, .{});
    defer testing.allocator.free(stop);
    try testing.expect(std.mem.startsWith(u8, stop, "── stopped at the Linux prelude:2:"));
    try testing.expect(std.mem.indexOf(u8, stop, "\n   called from stdin:2:1\n") != null);
    try testing.expect(std.mem.indexOf(u8, stop, "\n── used: ") != null);
}

test "cli: a run's changes are listed on --verbose, and only then" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);
    var out: [1024]u8 = undefined;
    var r = script.runWith(threaded.io(), testing.allocator, root, "replace(\"a.txt\", \"x\")", .{}, 0, &out, .{});
    defer r.deinit();
    var quiet: std.Io.Writer.Allocating = .init(testing.allocator);
    defer quiet.deinit();
    try printReport(&r, "a.shale", &.{}, .{}, &quiet.writer);
    try testing.expectEqualStrings("", quiet.written());
    var loud: std.Io.Writer.Allocating = .init(testing.allocator);
    defer loud.deinit();
    try printReport(&r, "a.shale", &.{}, .{ .verbose = true }, &loud.writer);
    try testing.expect(std.mem.startsWith(u8, loud.written(), "── effects (1) ──\nreplace a.txt: ok\n"));
}
