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

    // **THE SHALE RUNNER** (src/script_runner.zig): a script against a
    // data folder, for writing and trying scripts on Linux.
    //   SHALE_ROOT=<data> zig build script -- <file.shale>
    const runner = b.addExecutable(.{ .name = "shale", .root_module = b.createModule(.{
        .root_source_file = b.path("src/script_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "webbox", .module = webbox }},
    }) });
    b.installArtifact(runner);
    const run_script = b.addRunArtifact(runner);
    if (b.args) |a| run_script.addArgs(a);
    b.step("script", "run a Shale script: SHALE_ROOT=<data folder> zig build script -- <file.shale>").dependOn(&run_script.step);

    const test_step = b.step("test", "Run unit tests");
    // **THE SCRIPT FUZZER'S COUNT** (src/script/fuzz_test.zig): a few hundred
    // sources in the tests, as many as asked for with -Dscript-fuzz.
    const script_options = b.addOptions();
    script_options.addOption(u32, "fuzz_runs", b.option(u32, "script-fuzz", "how many random and mutated sources the script fuzzer runs (default 400)") orelse 400);
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
        unit.root_module.addImport("script_test_options", script_options.createModule());
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
