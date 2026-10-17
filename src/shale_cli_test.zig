//! **THE `shale` BINARY, TESTED AS RUN** (metal-vmm QUEUE 233): what a
//! shell sees of it, the build's own `shale`.

const std = @import("std");
const testing = std.testing;
const shale_exe = @import("shale_test_options").shale;

test "cli: stdout and stderr into one file (`> f 2>&1`) keep both, in order" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const out = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/both.txt", .{&tmp.sub_path});
    defer a.free(out);
    const script = try std.fmt.allocPrint(a, "'{s}' -e 'print(\"one line of output\") fail(\"x\")' > '{s}' 2>&1", .{ shale_exe, out });
    defer a.free(script);
    const r = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", script } });
    a.free(r.stdout);
    a.free(r.stderr);
    const both = try tmp.dir.readFileAlloc(io, "both.txt", a, .limited(1 << 16));
    defer a.free(both);
    try testing.expect(std.mem.startsWith(u8, both, "one line of output\n── stopped at -e:1:"));
}
