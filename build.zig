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
    // **ONLY THE TESTS NAMED** (-Dtest-filter=<text>): a change's own tests
    // in seconds, before the whole suite.
    const test_filter = b.option([]const u8, "test-filter", "run only the tests whose names contain this");
    // **EACH TEST'S TIME** (-Dtest-timing, tools/timing_runner.zig): every
    // test's wall time, slowest first, so a suite's cost has names.
    const timing: ?std.Build.Step.Compile.TestRunner = if (b.option(bool, "test-timing", "print each test's time, slowest first") orelse false)
        .{ .path = b.path("tools/timing_runner.zig"), .mode = .simple }
    else
        null;
    for ([_][]const u8{ "src/store.zig", "src/counter.zig", "src/bus.zig", "src/mem_meter.zig", "src/host_facts.zig", "src/bind.zig", "src/webbox.zig", "src/webbox_linux.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }), .filters = if (test_filter) |t| b.dupeStrings(&.{t}) else &.{}, .test_runner = timing });
        // A file of the Linux host reaches the portable half as the module;
        // a file of the library, by path.
        unit.root_module.addImport("webbox", webbox);
        unit.root_module.addImport("webbox_linux", webbox_linux);
        unit.root_module.addImport("host_io", host_io);
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    // **THE APPLICATIONS, BUILT ON THIS TREE** (the box's essay "checks that
    // stopped checking", 2026-10-17): a webbox change broke angry-gopher's
    // checks for 14 hours, and the kernel's build and angry-gopher's again
    // the same day, each found only when someone ran that repo's checks.
    // `zig build consumers` runs each application's own, against this
    // checkout (they name it by path, `../zig-webbox`), one at a time,
    // cheapest first. A sibling that is not there fails the step by name.
    // Not in `test`: it needs the siblings, and minutes. Run before a webbox
    // change is pushed to master.
    const consumers = b.step("consumers", "This tree's own docs checked (by shale's doc check), then each consumer's own checks against this tree: shale's tests, metal-vmm's queue tool, the Observatory's and dog-park's tests, the kernel's gopher.elf, angry-gopher's ops/check_zig (needs the sibling checkouts)");
    const here = b.root.root_dir.path orelse ".";
    var prev: ?*std.Build.Step = null;
    for ([_]struct { repo: []const u8, cmd: []const u8 }{
        // **THE DOCS' CITED PATHS AND NAMES**, this tree's (shale's
        // tools/doc_check.shale, metal-vmm QUEUE 237): the cheapest first.
        .{ .repo = "shale", .cmd = "zig build doc-check -- only=zig-webbox" },
        .{ .repo = "shale", .cmd = "zig build test" },
        // metal-vmm's queue tool, by shale's `shale` on this tree.
        .{ .repo = "metal-vmm", .cmd = "(cd ../shale && zig build) && ../shale/zig-out/bin/shale --budget output_bytes=8388608 .shale/queue_test.shale > /dev/null" },
        .{ .repo = "observatory", .cmd = "zig build test" },
        .{ .repo = "dog-park", .cmd = "zig build test" },
        .{ .repo = "zig-metal-unikernel", .cmd = "zig build gopher" },
        .{ .repo = "angry-gopher", .cmd = "./ops/check_zig" },
    }) |c| {
        const dir = b.pathJoin(&.{ here, "..", c.repo });
        const run = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
            "cd '{s}' 2>/dev/null || {{ echo 'consumers: no {s} beside this checkout ({s})'; exit 1; }}; " ++
                "echo '==> {s}: {s}'; unset ZIG_PROGRESS; {s}",
            .{ dir, c.repo, dir, c.repo, c.cmd, c.cmd },
        ) });
        run.has_side_effects = true;
        run.stdio = .inherit;
        if (prev) |p| run.step.dependOn(p);
        prev = &run.step;
    }
    consumers.dependOn(prev.?);
}
