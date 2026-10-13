const std = @import("std");

// The `webbox` library: what an application imports as modules, never by path.
//
//   zig build test   -> the library's unit tests
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // **TWO MODULES**: `webbox`, portable, which everything imports; and
    // `webbox_linux` (src/webbox_linux.zig), the Linux host, which only a
    // Linux `main` imports and which reaches the portable half as `webbox`.
    //
    // **`host_io`, THE ONE FILE THAT NAMES THE HOST**: every file takes its
    // `Io` from it (`@import("host_io").Io`). Here it is src/host_io_std.zig,
    // the standard library's; zig-metal-unikernel's build hands the same
    // sources its own, the machine's. Exported, so an application's build
    // hands its own code the same one.
    const host_io = b.addModule("host_io", .{ .root_source_file = b.path("src/host_io_std.zig") });
    const webbox = b.addModule("webbox", .{
        .root_source_file = b.path("src/webbox.zig"),
        .imports = &.{.{ .name = "host_io", .module = host_io }},
    });
    const webbox_linux = b.addModule("webbox_linux", .{
        .root_source_file = b.path("src/webbox_linux.zig"),
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "host_io", .module = host_io },
        },
    });

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/store.zig", "src/counter.zig", "src/bus.zig", "src/mem_meter.zig", "src/host_facts.zig", "src/bind.zig", "src/webbox.zig", "src/webbox_linux.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        // A file of the Linux host reaches the portable half as the module;
        // a file of the library, by path.
        unit.root_module.addImport("webbox", webbox);
        unit.root_module.addImport("webbox_linux", webbox_linux);
        unit.root_module.addImport("host_io", host_io);
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
