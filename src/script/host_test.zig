//! **THE SEAM** (metal-vmm QUEUE 233, chunk 1; the dogfood design's "The
//! architecture"): the core's one door out, `host(name, ...)`, forwarded
//! to `Options.host`, and its one hook on paths, `Options.path_hook`.
//! With neither (metal), `host` stops with class `host` and `pathArg` is
//! what it was. Every run here is the gate's: the VM held to the walker.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

var out_buf: [16 * 1024]u8 = undefined;

fn runWith(src: []const u8, options: script.Options) script.Result {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    return script.runWith(threaded.io(), testing.allocator, ".zig-cache/no-root", src, .{}, 0, &out_buf, options);
}

test "seam: with no host, `host` stops with class host, naming the call, on both engines" {
    var r = runWith("local x = host(\"run\", {\"zig\", \"build\"}, {})", .{});
    defer r.deinit();
    const s = r.stop orelse return error.TestUnexpectedResult;
    try testing.expectEqual(script.diag.Class.host, s.class);
    try testing.expectEqualStrings("`run`: not on this host", s.message);
    // Not caught by attempt? It is an error like any other: attempt catches it.
    var a = runWith("function f() return host(\"real\", \"runs:x\") end local r = attempt(f) print(r.ok, r.class)", .{});
    defer a.deinit();
    try testing.expectEqualStrings("false\thost\n", a.output);
}

/// A host that answers every call with its name and how many arguments it
/// was given, and counts its calls.
const Echo = struct {
    calls: usize = 0,

    fn call(ctx: *anyopaque, run: *script.interp.Run, pos: script.ast.Pos, name: []const u8, args: []const script.value.Value) script.interp.Error!script.value.Value {
        const self: *Echo = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try run.charge(pos, 1);
        const s = std.fmt.allocPrint(run.alloc, "{s}/{d}", .{ name, args.len }) catch return run.oom(pos);
        return .{ .string = s };
    }
};

test "seam: a host's answer is the call's value, the same through both engines" {
    var echo: Echo = .{};
    var r = runWith("print(host(\"run\", 1, 2), host(\"job_alive\"))", .{ .host = .{ .ctx = &echo, .call = Echo.call } });
    defer r.deinit();
    try testing.expectEqual(@as(?script.Stop, null), r.stop);
    try testing.expectEqualStrings("run/2\tjob_alive/0\n", r.output);
    // The gate ran it on the walker, the VM, and the VM in slices.
    try testing.expect(echo.calls >= 6);
    // `host`'s name must be a string.
    var bad = runWith("local x = host(1)", .{ .host = .{ .ctx = &echo, .call = Echo.call } });
    defer bad.deinit();
    try testing.expectEqual(script.diag.Class.type, bad.stop.?.class);
}

/// A path hook that takes `m:` paths to a folder of the test's.
const Mount = struct {
    dir: []const u8,

    fn resolve(ctx: *anyopaque, run: *script.interp.Run, pos: script.ast.Pos, path: []const u8) script.interp.Error!?[]const u8 {
        const self: *Mount = @ptrCast(@alignCast(ctx));
        if (!std.mem.startsWith(u8, path, "m:")) return null;
        return std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ self.dir, path[2..] }) catch run.oom(pos);
    }
};

test "seam: a path hook resolves the paths it knows; without it, the same path is refused as it was" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "note.txt", .data = "mounted\n" });
    const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(dir);
    var mount: Mount = .{ .dir = dir };
    var r = runWith("print(read(\"m:note.txt\"), exists(\"m:none\"))", .{ .path_hook = .{ .ctx = &mount, .resolve = Mount.resolve } });
    defer r.deinit();
    try testing.expectEqual(@as(?script.Stop, null), r.stop);
    try testing.expectEqualStrings("mounted\n\tfalse\n", r.output);
    var plain = runWith("print(read(\"m:note.txt\"))", .{});
    defer plain.deinit();
    try testing.expectEqual(script.diag.Class.argument, plain.stop.?.class);
    try testing.expect(std.mem.indexOf(u8, plain.stop.?.message, "is not a name") != null);
}
