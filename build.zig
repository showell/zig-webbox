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
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "webbox_linux", .module = webbox_linux },
        },
    }) });
    b.installArtifact(runner);
    const run_script = b.addRunArtifact(runner);
    if (b.args) |a| run_script.addArgs(a);
    b.step("script", "run a Shale script: zig build script -- [--root DIR] [--write] [--verbose] [<file.shale> | -e SOURCE] [name=value ...]").dependOn(&run_script.step);

    // **SHALE'S HOT PATHS, TIMED** (src/script_bench.zig): no tier runs it.
    const script_bench = b.addExecutable(.{ .name = "script-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/script_bench.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "webbox", .module = b.addModule("webbox_release", .{
            .root_source_file = b.path("src/webbox.zig"),
            .imports = &.{.{ .name = "host_io", .module = host_io }},
        }) }},
    }) });
    b.step("script-bench", "time Shale's hot paths (ReleaseSafe)").dependOn(&b.addRunArtifact(script_bench).step);

    // **THE SITE'S REAL SCALE** (src/shale_scale.zig, metal-vmm QUEUE
    // 209(g)): the largest site each cookbook script fits. No tier runs it.
    const scale = b.addExecutable(.{ .name = "shale-scale", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shale_scale.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "webbox", .module = script_bench.root_module.import_table.get("webbox").? }},
    }) });
    b.step("shale-scale", "the largest site each cookbook script fits, under the site's budgets (ReleaseSafe)").dependOn(&b.addRunArtifact(scale).step);

    // **THE SHALE SIGNER** (src/shale_sign.zig, metal-vmm QUEUE 200): the
    // key pair, made once, and a script signed for a target.
    //   zig build shale-sign -- keygen | pubkey | sign <file.shale> <target> [minutes]
    const signer = b.addExecutable(.{ .name = "shale-sign", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shale_sign.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "webbox", .module = webbox }},
    }) });
    b.installArtifact(signer);
    const run_signer = b.addRunArtifact(signer);
    if (b.args) |a| run_signer.addArgs(a);
    b.step("shale-sign", "the Shale signer: zig build shale-sign -- keygen | pubkey | sign <file.shale> <target> [minutes]").dependOn(&run_signer.step);
    const signer_test = b.addTest(.{ .root_module = signer.root_module });

    const test_step = b.step("test", "Run unit tests");
    // **THE SCRIPT FUZZER'S COUNT** (src/script/fuzz_test.zig): a few hundred
    // sources in the tests, as many as asked for with -Dscript-fuzz.
    const fuzz_runs = b.option(u32, "script-fuzz", "how many random and mutated sources the script fuzzer runs (default 400)") orelse 400;
    // **THE EXPENSIVE ONES HUNT, NO GATE PAYS FOR THEM** (Steve, 2026-10-17:
    // fuzzers are for bug-hunting expeditions; each bug found becomes a
    // targeted unit test): a test named `expensive fuzz: ...` or `expensive
    // sweep: ...` is skipped by `zig build test` and counted as skipped, and
    // `zig build fuzz` runs those and nothing else.
    const options_of = struct {
        fn make(bb: *std.Build, runs: u32, expensive: bool) *std.Build.Module {
            const o = bb.addOptions();
            o.addOption(u32, "fuzz_runs", runs);
            o.addOption(bool, "expensive", expensive);
            return o.createModule();
        }
    }.make;
    const fuzz_step = b.step("fuzz", "The expensive fuzzes and sweeps (tests named `expensive ...`), for a bug hunt; no gate runs them");
    // **ONLY THE TESTS NAMED** (-Dtest-filter=<text>): a change's own tests
    // in seconds, before the whole suite.
    const test_filter = b.option([]const u8, "test-filter", "run only the tests whose names contain this");
    // **EACH TEST'S TIME** (-Dtest-timing, tools/timing_runner.zig): every
    // test's wall time, slowest first, so a suite's cost has names.
    const timing: ?std.Build.Step.Compile.TestRunner = if (b.option(bool, "test-timing", "print each test's time, slowest first") orelse false)
        .{ .path = b.path("tools/timing_runner.zig"), .mode = .simple }
    else
        null;
    // **THE FIXTURE PROGRAM** `run`'s tests run (src/shale_fixture.zig,
    // metal-vmm QUEUE 233): never /bin/sh. Its path reaches the tests as
    // `shale_test_options.fixture`.
    const fixture = b.addExecutable(.{ .name = "shale-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shale_fixture.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const shale_options = b.addOptions();
    shale_options.addOptionPath("fixture", fixture.getEmittedBin());
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
        unit.root_module.addImport("script_test_options", options_of(b, fuzz_runs, false));
        unit.root_module.addImport("shale_test_options", shale_options.createModule());
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    // The expensive tests are all reached from webbox.zig's test block.
    const hunt = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/webbox.zig"),
        .target = target,
        .optimize = optimize,
    }), .filters = b.dupeStrings(&.{"expensive "}), .test_runner = timing });
    hunt.root_module.addImport("webbox", webbox);
    hunt.root_module.addImport("webbox_linux", webbox_linux);
    hunt.root_module.addImport("host_io", host_io);
    hunt.root_module.addImport("script_test_options", options_of(b, fuzz_runs, true));
    hunt.root_module.addImport("shale_test_options", shale_options.createModule());
    fuzz_step.dependOn(&b.addRunArtifact(hunt).step);
    test_step.dependOn(&b.addRunArtifact(signer_test).step);

    // **THE APPLICATIONS, BUILT ON THIS TREE** (the box's essay "checks that
    // stopped checking", 2026-10-17): a webbox change broke angry-gopher's
    // checks for 14 hours, and the kernel's build and angry-gopher's again
    // the same day, each found only when someone ran that repo's checks.
    // `zig build consumers` runs each application's own, against this
    // checkout (they name it by path, `../zig-webbox`), one at a time,
    // cheapest first. A sibling that is not there fails the step by name.
    // Not in `test`: it needs the siblings, and minutes. Run before a webbox
    // change is pushed to master.
    const consumers = b.step("consumers", "Each application's own checks against this tree: the Observatory's and dog-park's tests, the kernel's gopher.elf, angry-gopher's ops/check_zig (needs the sibling checkouts)");
    const here = b.build_root.path orelse ".";
    var prev: ?*std.Build.Step = null;
    for ([_]struct { repo: []const u8, cmd: []const u8 }{
        .{ .repo = "observatory", .cmd = "zig build test" },
        .{ .repo = "dog-park", .cmd = "zig build test" },
        .{ .repo = "zig-metal-unikernel", .cmd = "zig build gopher" },
        .{ .repo = "angry-gopher", .cmd = "./ops/check_zig" },
    }) |c| {
        const dir = b.pathJoin(&.{ here, "..", c.repo });
        const run = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
            "cd '{s}' 2>/dev/null || {{ echo 'consumers: no {s} beside this checkout ({s})'; exit 1; }}; " ++
                "echo '==> {s}: {s}'; env -u ZIG_PROGRESS {s}",
            .{ dir, c.repo, dir, c.repo, c.cmd, c.cmd },
        ) });
        run.has_side_effects = true;
        run.stdio = .inherit;
        if (prev) |p| run.step.dependOn(p);
        prev = &run.step;
    }
    consumers.dependOn(prev.?);
}
