//! **A TEST'S LINUX HOST** (metal-vmm QUEUE 233): a temporary root, the
//! host over it, the fixture program the build makes found along `PATH`,
//! and runs through the gate. Only the tests use it.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const testing = std.testing;
const Host = @import("shale_host_linux.zig").Host;
const fixture = @import("shale_test_options").fixture;
const shale_exe = @import("shale_test_options").shale;

var out_buf: [64 * 1024]u8 = undefined;

pub const T = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    host: Host,
    path_env: []const u8,
    /// The preludes after the core's each run is given.
    preludes: []const script.parse.Prelude = &.{},

    pub fn init(t: *T) !void {
        t.preludes = &.{};
        t.tmp = testing.tmpDir(.{});
        t.threaded = std.Io.Threaded.init(testing.allocator, .{});
        t.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = t.arena.allocator();
        var cwd: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.os.linux.getcwd(&cwd, cwd.len);
        const here = std.mem.sliceTo(cwd[0..n], 0);
        t.root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ here, &t.tmp.sub_path });
        const fixture_abs = if (std.fs.path.isAbsolute(fixture)) fixture else try std.fmt.allocPrint(a, "{s}/{s}", .{ here, fixture });
        t.path_env = try std.fmt.allocPrint(a, "PATH={s}:/usr/bin:/bin", .{std.fs.path.dirname(fixture_abs).?});
        const reaper = if (std.fs.path.isAbsolute(shale_exe)) shale_exe else try std.fmt.allocPrint(a, "{s}/{s}", .{ here, shale_exe });
        t.host = .{ .alloc = testing.allocator, .root_abs = t.root, .cwd_abs = try a.dupe(u8, here), .env = try a.dupe([]const u8, &.{t.path_env}), .reaper = reaper };
    }

    pub fn deinit(t: *T) void {
        t.host.deinit();
        t.arena.deinit();
        t.threaded.deinit();
        t.tmp.cleanup();
    }

    pub fn run(t: *T, src: []const u8, mode: script.process.Mode) script.Result {
        const o = t.host.options();
        return script.runWith(t.threaded.io(), testing.allocator, t.root, src, .{}, 0, &out_buf, .{ .mode = mode, .host = o.host, .path_hook = o.path_hook, .preludes = t.preludes });
    }

    /// One run of the VM, outside the gate: for a script whose effects
    /// on the world cannot happen three times alike (a commit, a push).
    pub fn runOnce(t: *T, src: []const u8, mode: script.process.Mode) script.Result {
        const o = t.host.options();
        return script.runOn(.vm, t.threaded.io(), testing.allocator, t.root, src, .{}, 0, &out_buf, .{ .mode = mode, .host = o.host, .path_hook = o.path_hook, .preludes = t.preludes });
    }

    pub fn expectOutput(t: *T, src: []const u8, want: []const u8) !void {
        var r = t.run(src, .atomic);
        defer r.deinit();
        if (r.stop) |s| {
            std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(want, r.output);
    }

    pub fn expectStop(t: *T, src: []const u8, mode: script.process.Mode, class: script.diag.Class, says: []const u8) !void {
        var r = t.run(src, mode);
        defer r.deinit();
        const s = r.stop orelse {
            std.debug.print("{s}: no stop\n", .{src});
            return error.TestUnexpectedResult;
        };
        errdefer std.debug.print("{s}: {s}: {s}\n", .{ src, @tagName(s.class), s.message });
        try testing.expectEqual(class, s.class);
        try testing.expect(std.mem.indexOf(u8, s.message, says) != null);
    }

    pub fn put(t: *T, name: []const u8, data: []const u8) !void {
        try t.tmp.dir.writeFile(t.threaded.io(), .{ .sub_path = name, .data = data });
    }

    pub fn file(t: *T, name: []const u8) ![]u8 {
        return t.tmp.dir.readFileAlloc(t.threaded.io(), name, t.arena.allocator(), .limited(1 << 20));
    }
};
