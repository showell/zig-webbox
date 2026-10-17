//! **THE LIBRARY'S NUMBER PARSES THAT NO REQUEST REACHES**, each with why.
//! An application checks every place a request carries a number (angry-gopher
//! router.zig's request edges), across its own source and the library's; a
//! library site named here is known without the application listing it, so a
//! change here that adds one says so here, not in each application. A site a
//! request does reach is the application's to cover, with a request.

const std = @import("std");
const Io = @import("host_io").Io;

pub const Site = struct { file: []const u8, func: []const u8, why: []const u8 };

pub const unreachable_from_requests = [_]Site{
    .{ .file = "script_route.zig", .func = "lastSequence", .why = "a sequence file the server wrote" },
    .{ .file = "shale_sign.zig", .func = "main", .why = "the signer, on the box, not the server" },
    .{ .file = "shale_fixture.zig", .func = "main", .why = "the program Shale's run tests spawn, not the server (zig-webbox, metal-vmm QUEUE 233)" },
    .{ .file = "shale_jobs.zig", .func = "parseRecord", .why = "a job's record its reaper wrote, read by the Linux shale CLI, not the server (zig-webbox, metal-vmm QUEUE 233)" },
    .{ .file = "shale_sign.zig", .func = "lastFor", .why = "the signer, on the box, not the server" },
    .{ .file = "log_view.zig", .func = "requestAt", .why = "the host's own log lines, not a request's" },
    .{ .file = "bus.zig", .func = "keepaliveSetting", .why = "the host's start-up setting, not a request's" },
    .{ .file = "counter.zig", .func = "current", .why = "a counter file the server wrote" },
    .{ .file = "linux_host.zig", .func = "portFrom", .why = "the environment" },
    .{ .file = "linux_fetch.zig", .func = "parseHead", .why = "the answer to the application's own fetch, not a request (zig-webbox, metal-vmm QUEUE 228)" },
    .{ .file = "site_secret.zig", .func = "previous", .why = "a secret file the server wrote" },
};

test "edge_sites: every site named is a function of that name in that file, which parses a number" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var src = try Io.Dir.cwd().openDir(io, "src", .{});
    defer src.close(io);
    for (unreachable_from_requests) |s| {
        errdefer std.debug.print("edge_sites: {s}'s {s} is not there\n", .{ s.file, s.func });
        const text = try src.readFileAlloc(io, s.file, arena.allocator(), .limited(4 << 20));
        const at = std.mem.indexOf(u8, text, try std.fmt.allocPrint(arena.allocator(), "fn {s}(", .{s.func})) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfPos(u8, text, at, "parseInt(") != null);
    }
}
