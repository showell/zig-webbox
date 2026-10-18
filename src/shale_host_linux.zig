//! **SHALE'S LINUX HOST** (metal-vmm QUEUE 233, chunk 1; the dogfood
//! design's "The architecture", "Mounts", "Running a program"): what the
//! CLI hands the core through its seam. `host(name, ...)`
//! comes here (`call`): `run` a program under its options, `real` a Shale
//! path's OS path. Paths come here first (`resolve`): a path whose first
//! part has a `:` is a mount's (`runs:x/test.log`).
//!
//! Metal has none of this: the core it shares is unchanged, and with no
//! host its `host` stops and its paths are the root's.

const std = @import("std");
const webbox = @import("webbox");
const script = webbox.script;
const interp = script.interp;
const ast = script.ast;
const Value = script.value.Value;
const Run = interp.Run;
const Error = interp.Error;
const store = webbox.store;
const regex = script.regex;
const keep = @import("shale_keep.zig");
const spawn = @import("shale_spawn.zig");

/// **THE LINUX PRELUDE** (QUEUE 233, chunk 2): the names a script types
/// (`run`, `real`) over `host`, and the helpers only Linux has.
pub const linux_prelude: script.parse.Prelude = .{ .name = "the Linux prelude", .source = @embedFile("shale_prelude_linux.shale") };

/// **THE GIT PRELUDE** (QUEUE 233, chunk 3): git over `run`, after the
/// Linux prelude whose `run` and `real` it calls.
pub const git_prelude: script.parse.Prelude = .{ .name = "the git prelude", .source = @embedFile("shale_prelude_git.shale") };

/// The most programs a run may run (the design's "The CLI's defaults").
pub const runs_most = 64;

// ── mounts ───────────────────────────────────────────────────────────────

pub const Mount = struct {
    name: []const u8,
    dir: []const u8,
    /// ` ro` after the path (metal-vmm QUEUE 235): every change through it
    /// is refused before anything is written; reads and programs as ever.
    access: Access = .read_write,

    pub const Access = enum { read_write, read_only };
};

/// **THE MOUNTS FILE**: `name = value` a line, `#` comments and blank
/// lines; a value an absolute path or one from `~/`. What is wrong is said
/// with its line: a relative value, a name twice, a line that is neither.
pub fn parseMounts(alloc: std.mem.Allocator, text: []const u8, home: []const u8, why: *[]const u8) error{ OutOfMemory, Malformed }![]Mount {
    var out: std.ArrayList(Mount) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            why.* = try std.fmt.allocPrint(alloc, "line {d}: `{s}` is not `name = value`", .{ n, line });
            return error.Malformed;
        };
        const name = std.mem.trim(u8, line[0..eq], " \t");
        // The path, and ` ro` after it, or nothing.
        var words = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t");
        const value = words.next() orelse "";
        var access: Mount.Access = .read_write;
        if (words.next()) |w| {
            if (words.next() != null) {
                why.* = try std.fmt.allocPrint(alloc, "line {d}: `{s}`'s path has a space, or more than ` ro` follows it", .{ n, name });
                return error.Malformed;
            }
            if (!std.mem.eql(u8, w, "ro")) {
                why.* = try std.fmt.allocPrint(alloc, "line {d}: `{s}` after `{s}`'s path: only `ro` may follow it (and a path has no space)", .{ n, w, name });
                return error.Malformed;
            }
            access = .read_only;
        }
        if (name.len == 0 or !validName(name)) {
            why.* = try std.fmt.allocPrint(alloc, "line {d}: `{s}` is not a mount's name: letters, digits, `_` and `-`", .{ n, name });
            return error.Malformed;
        }
        for (out.items) |m| if (std.mem.eql(u8, m.name, name)) {
            why.* = try std.fmt.allocPrint(alloc, "line {d}: the mount `{s}` is named twice", .{ n, name });
            return error.Malformed;
        };
        const dir = if (std.mem.startsWith(u8, value, "~/"))
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, value[2..] })
        else if (value.len > 0 and value[0] == '/')
            try alloc.dupe(u8, value)
        else {
            why.* = try std.fmt.allocPrint(alloc, "line {d}: `{s}`'s value `{s}` is relative: an absolute path, or one from `~/`", .{ n, name, value });
            return error.Malformed;
        };
        try out.append(alloc, .{ .name = try alloc.dupe(u8, name), .dir = std.mem.trimEnd(u8, dir, "/"), .access = access });
    }
    return out.toOwnedSlice(alloc);
}

/// **WHERE THE MOUNTS ARE**: `SHALE_MOUNTS` names the file (the tests pin
/// it), else `~/.config/shale/mounts`. The default's absence is no mounts;
/// a file named and missing, or any file's mistake, is said with the file.
pub fn loadMounts(alloc: std.mem.Allocator, io: std.Io, pinned: ?[]const u8, home: []const u8, why: *[]const u8) error{ OutOfMemory, Malformed }!struct { mounts: []Mount, from: []const u8 } {
    const from = if (pinned) |p| p else try std.fmt.allocPrint(alloc, "{s}/.config/shale/mounts", .{home});
    const text = std.Io.Dir.cwd().readFileAlloc(io, from, alloc, .limited(64 * 1024)) catch |e| {
        if (pinned == null and e == error.FileNotFound) return .{ .mounts = &.{}, .from = from };
        why.* = try std.fmt.allocPrint(alloc, "{s}{s}: {s}", .{ if (pinned != null) "SHALE_MOUNTS=" else "", from, @errorName(e) });
        return error.Malformed;
    };
    var line_why: []const u8 = "";
    const mounts = parseMounts(alloc, text, home, &line_why) catch |e| {
        if (e == error.Malformed) why.* = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ from, line_why });
        return e;
    };
    // **A MOUNT'S OWN PATH, RESOLVED ONCE** (metal-vmm QUEUE 235): a link
    // in it (`~/zig` to `~/zig-0.16.0`) is the user's choice, taken here;
    // below it, the store follows none.
    for (mounts) |*m| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(io, m.dir, &buf) catch continue;
        m.dir = try alloc.dupe(u8, buf[0..n]);
    }
    return .{ .mounts = mounts, .from = from };
}

/// **THE PRELUDES AFTER THE CORE'S, IN ORDER** (the dogfood design's "The
/// architecture"): the Linux prelude and the git prelude; the repo's, `.shale/prelude.shale` at
/// the root, if it is there; the user's, the file `SHALE_PRELUDE` names
/// (`""` none, the tests' pin) or else `~/.config/shale/prelude.shale` if it
/// is there. Each is named as a stop shows its lines.
pub fn loadPreludes(alloc: std.mem.Allocator, io: std.Io, root_abs: []const u8, pinned: ?[]const u8, home: []const u8, why: *[]const u8) error{ OutOfMemory, Malformed }![]script.parse.Prelude {
    var out: std.ArrayList(script.parse.Prelude) = .empty;
    try out.append(alloc, linux_prelude);
    try out.append(alloc, git_prelude);
    const repo = try std.fmt.allocPrint(alloc, "{s}/.shale/prelude.shale", .{root_abs});
    if (try readPrelude(alloc, io, repo, false, "", why)) |src| try out.append(alloc, .{ .name = ".shale/prelude.shale", .source = src });
    if (pinned) |p| {
        if (p.len > 0) if (try readPrelude(alloc, io, p, true, "SHALE_PRELUDE=", why)) |src| try out.append(alloc, .{ .name = p, .source = src });
    } else {
        const user = try std.fmt.allocPrint(alloc, "{s}/.config/shale/prelude.shale", .{home});
        if (try readPrelude(alloc, io, user, false, "", why)) |src| try out.append(alloc, .{ .name = "~/.config/shale/prelude.shale", .source = src });
    }
    return out.toOwnedSlice(alloc);
}

/// A prelude's source; null for one not there that need not be.
fn readPrelude(alloc: std.mem.Allocator, io: std.Io, path: []const u8, required: bool, shown: []const u8, why: *[]const u8) error{ OutOfMemory, Malformed }!?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(interp.Budgets.default_source_bytes)) catch |e| {
        if (!required and e == error.FileNotFound) return null;
        why.* = try std.fmt.allocPrint(alloc, "{s}{s}: {s}", .{ shown, path, @errorName(e) });
        return error.Malformed;
    };
}

/// **A PROGRAM'S ENVIRONMENT**, inherited, `K=V` each, but for
/// `ZIG_PROGRESS`: a `zig build` that `run` runs writes its progress to a
/// pipe the build that ran the CLI holds, never to `run`'s output.
pub fn baseEnv(alloc: std.mem.Allocator, map: *const std.process.Environ.Map) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e);
        out.deinit(alloc);
    }
    var it = map.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "ZIG_PROGRESS")) continue;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }));
    }
    return out.toOwnedSlice(alloc);
}

fn validName(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

// ── the spawn, real or a test's ─────────────────────────────────────────

/// Where a program's output goes as it comes: the scrubber, then the log
/// and the keep (or `whole`).
pub const Sink = struct {
    host: *Host,
    scrub: *Scrub,
    pub const Error = error{OutOfMemory};
    pub fn write(s: *Sink, bytes: []const u8) Sink.Error!void {
        try s.scrub.write(bytes);
    }
};

/// **THE ONE THING A GATED TEST FAKES**: the spawn, bytes in and bytes
/// out. Everything around it (the options, the filter, the keep, the
/// charges) is the real code in both engines.
pub const Spawn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, spec: spawn.Spec, sink: *Sink) (spawn.Error || Sink.Error)!spawn.Outcome;

fn realSpawn(_: ?*anyopaque, alloc: std.mem.Allocator, spec: spawn.Spec, sink: *Sink) (spawn.Error || Sink.Error)!spawn.Outcome {
    return spawn.run(alloc, spec, sink);
}

/// What the host did that the CLI lists after the run: each program it
/// ran, with its want, and each log it wrote.
pub const Record = struct { line: []const u8 };

pub const Host = struct {
    alloc: std.mem.Allocator,
    /// The root as the CLI was given it, an absolute OS path. A mount
    /// inside it is taken against the run's own root, so a gated test's
    /// engines, each in a copy of the root, each use their own (the design's
    /// "The gate").
    root_abs: []const u8,
    /// The process's working folder: what a relative root is against.
    cwd_abs: []const u8,
    mounts: []const Mount = &.{},
    /// Where the mounts came from, for a stop that names them.
    mounts_from: []const u8 = "~/.config/shale/mounts",
    /// The environment a program inherits, `K=V` each (`ZIG_PROGRESS` out).
    env: []const []const u8 = &.{},
    /// The program a job runs under (`shale` itself, `--reap`): null, no
    /// jobs.
    reaper: ?[]const u8 = null,
    spawn_fn: Spawn = realSpawn,
    spawn_ctx: ?*anyopaque = null,
    records: std.ArrayList(Record) = .empty,

    pub fn deinit(h: *Host) void {
        for (h.records.items) |r| h.alloc.free(r.line);
        h.records.deinit(h.alloc);
    }

    pub fn options(h: *Host) struct { host: interp.Host, path_hook: interp.PathHook } {
        return .{ .host = .{ .ctx = h, .call = call }, .path_hook = .{ .ctx = h, .resolve = resolve, .may_change = mayChange } };
    }

    pub fn record(h: *Host, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(h.alloc, fmt, args) catch return;
        h.records.append(h.alloc, .{ .line = line }) catch h.alloc.free(line);
    }
};

// ── paths ────────────────────────────────────────────────────────────────

/// **A MOUNT'S PATH** (`runs:x/y`): the mount's folder and the rest, with
/// the root's rules on the rest (no `..`, no absolute path, FAT's names).
/// Any other path is the root's (null).
fn resolve(ctx: *anyopaque, run: *Run, pos: ast.Pos, path: []const u8) Error!?[]const u8 {
    const h: *Host = @ptrCast(@alignCast(ctx));
    const first_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const colon = std.mem.indexOfScalar(u8, path[0..first_end], ':') orelse {
        // The root's path: the root's rules are the core's; a link in it is
        // refused here, when its parts are names (else the core says why).
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| if (!store.fatName(part)) return null;
        try refuseLinks(run, pos, std.mem.trimEnd(u8, run.root, "/"), path, "");
        return null;
    };
    const name = path[0..colon];
    const rest = path[colon + 1 ..];
    const m = for (h.mounts) |m| {
        if (std.mem.eql(u8, m.name, name)) break m;
    } else {
        var names: std.ArrayList(u8) = .empty;
        for (h.mounts, 0..) |m, i| {
            if (i > 0) names.appendSlice(run.alloc, ", ") catch return run.oom(pos);
            names.print(run.alloc, "`{s}`", .{m.name}) catch return run.oom(pos);
        }
        if (h.mounts.len == 0) return run.fail(pos, .argument, "\"{s}\": `{s}:` is not a mount: there are none ({s})", .{ path, name, h.mounts_from });
        return run.fail(pos, .argument, "\"{s}\": `{s}:` is not a mount: the mounts are {s} ({s})", .{ path, name, names.items, h.mounts_from });
    };
    if (rest.len > 0 and rest[0] == '/') return run.fail(pos, .argument, "\"{s}\" is absolute inside its mount: a mount's paths are relative to it", .{path});
    if (rest.len > 0) {
        var it = std.mem.splitScalar(u8, rest, '/');
        while (it.next()) |part| if (!store.fatName(part)) return run.fail(pos, .argument, "\"{s}\" has a part (\"{s}\") that is not a name: no `.`, `..`, empty parts or characters FAT refuses", .{ path, part });
    }
    // A mount whose folder is not there, or cannot be opened, stops when
    // it is used, saying which.
    if (std.Io.Dir.cwd().openDir(run.io, m.dir, .{})) |d| d.close(run.io) else |e| switch (e) {
        error.FileNotFound, error.NotDir => return run.fail(pos, .store, "the mount `{s}` is {s}, which is not a folder there", .{ m.name, m.dir }),
        else => return run.fail(pos, .store, "the mount `{s}` is {s}, which cannot be opened: {s}", .{ m.name, m.dir, @errorName(e) }),
    }
    const inside = std.mem.startsWith(u8, m.dir, h.root_abs) and (m.dir.len == h.root_abs.len or m.dir[h.root_abs.len] == '/');
    const dir = if (inside) std.fmt.allocPrint(run.alloc, "{s}{s}", .{ try rootOf(h, run, pos), m.dir[h.root_abs.len..] }) catch return run.oom(pos) else m.dir;
    try refuseLinks(run, pos, dir, rest, path[0 .. colon + 1]);
    if (rest.len == 0) return dir;
    return std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ dir, rest }) catch run.oom(pos);
}

/// **THE STORE FOLLOWS NO LINK** (metal-vmm QUEUE 235; Steve: "refuse
/// any"): each part of `rest` below `base`, looked at without following
/// it (`lstat`, a component walk); a symbolic link stops the run, for a
/// read, a change, `exists`, `stat` and a listing alike. A part not there
/// ends the walk: what is below it is not there either. A step a part.
/// (`walk` passes the links it lists by: what a listing names is not a
/// path given.)
fn refuseLinks(run: *Run, pos: ast.Pos, base: []const u8, rest: []const u8, shown_prefix: []const u8) Error!void {
    if (rest.len == 0) return;
    var at: std.ArrayList(u8) = .empty;
    at.appendSlice(run.alloc, base) catch return run.oom(pos);
    var it = std.mem.splitScalar(u8, rest, '/');
    var shown_end: usize = 0;
    while (it.next()) |part| {
        try run.charge(pos, 1);
        at.append(run.alloc, '/') catch return run.oom(pos);
        at.appendSlice(run.alloc, part) catch return run.oom(pos);
        shown_end += part.len + @intFromBool(shown_end > 0);
        const st = std.Io.Dir.cwd().statFile(run.io, at.items, .{ .follow_symlinks = false }) catch return;
        if (st.kind == .sym_link) return run.fail(pos, .refused, "{s}{s} is a symbolic link: the store follows none", .{ shown_prefix, rest[0..shown_end] });
    }
}

/// **A CHANGE THROUGH A READ-ONLY MOUNT IS REFUSED** (metal-vmm QUEUE 235),
/// by the mount's name, or by its folder when a root path reaches into it.
fn mayChange(ctx: *anyopaque, run: *Run, pos: ast.Pos, rel: []const u8, full: []const u8) Error!void {
    const h: *Host = @ptrCast(@alignCast(ctx));
    const abs = try absolute(h, run, pos, std.mem.trimEnd(u8, full, "/"));
    for (h.mounts) |m| {
        if (m.access != .read_only) continue;
        const named = std.mem.startsWith(u8, rel, m.name) and rel.len > m.name.len and rel[m.name.len] == ':';
        const inside = std.mem.startsWith(u8, m.dir, h.root_abs) and (m.dir.len == h.root_abs.len or m.dir[h.root_abs.len] == '/');
        const dir = if (inside) std.fmt.allocPrint(run.alloc, "{s}{s}", .{ try rootOf(h, run, pos), m.dir[h.root_abs.len..] }) catch return run.oom(pos) else m.dir;
        const under = std.mem.startsWith(u8, abs, dir) and (abs.len == dir.len or abs[dir.len] == '/');
        if (named or under) return run.fail(pos, .refused, "{s}: mount `{s}` is read-only", .{ rel, m.name });
    }
}

/// The run's own root, absolute.
pub fn rootOf(h: *Host, run: *Run, pos: ast.Pos) Error![]const u8 {
    return absolute(h, run, pos, std.mem.trimEnd(u8, run.root, "/"));
}

fn absolute(h: *Host, run: *Run, pos: ast.Pos, p: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fmt.allocPrint(run.alloc, "{s}/{s}", .{ h.cwd_abs, p }) catch run.oom(pos);
}

/// A Shale path's OS path, through the mounts or the root, made absolute.
pub fn osPath(h: *Host, run: *Run, pos: ast.Pos, v: Value, allow_root: bool) Error![]const u8 {
    const p = try script.builtins_store.pathArg(run, pos, .host, v, allow_root);
    return absolute(h, run, pos, std.mem.trimEnd(u8, p.full, "/"));
}

// ── the host's calls ─────────────────────────────────────────────────────

fn call(ctx: *anyopaque, run: *Run, pos: ast.Pos, name: []const u8, args: []const Value) Error!Value {
    const h: *Host = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, name, "real")) {
        if (args.len != 1) return run.fail(pos, .argument, "`real` takes one path, given {d}", .{args.len});
        return .{ .string = try osPath(h, run, pos, args[0], true) };
    }
    if (std.mem.eql(u8, name, "run")) return runProgram(h, run, pos, args);
    if (std.mem.startsWith(u8, name, "job_")) return @import("shale_host_jobs.zig").call(h, run, pos, name, args);
    if (std.mem.eql(u8, name, "zig_rename")) return @import("shale_host_zig.zig").rename(h.alloc, run, pos, args);
    if (std.mem.eql(u8, name, "zig_decls")) return @import("shale_host_zig.zig").decls(h.alloc, run, pos, args);
    if (std.mem.eql(u8, name, "zig_move")) return @import("shale_host_zig.zig").move(h.alloc, run, pos, args);
    if (std.mem.eql(u8, name, "zig_imports")) return @import("shale_host_zig.zig").imports(h.alloc, run, pos, args);
    // Whether a path may change: what `edits_all` asks of every file first.
    if (std.mem.eql(u8, name, "may_change")) {
        if (args.len != 1) return run.fail(pos, .argument, "`may_change` takes one path, given {d}", .{args.len});
        try script.builtins_change.mayChange(run, pos, try script.builtins_store.pathArg(run, pos, .host, args[0], false));
        return .{ .boolean = true };
    }
    return run.fail(pos, .host, "`{s}`: not on this host", .{name});
}

/// What `run` refuses unless it is given a `want`, by argv[0]'s basename
/// with a version suffix dropped (`python3.12` is `python3`), or with its
/// trailing version digits dropped too (`bash5.2` is `bash`, `perl5` is
/// `perl`).
const refused = [_]struct { []const []const u8, []const u8 }{
    .{ &.{ "bash", "sh", "dash", "zsh", "busybox", "python", "python3", "perl", "node" }, "a shell or an interpreter: Shale is the script" },
    .{ &.{ "head", "tail", "grep", "sed", "awk", "gawk", "cut", "sort", "uniq", "wc", "cat", "tr" }, "a text tool: Shale's builtins and run's own filter and keep do this" },
    .{ &.{ "env", "xargs", "timeout", "nice", "nohup", "setsid", "stdbuf", "time" }, "a wrapper that runs another program: run that program, with run's own options" },
};

/// **WHAT `run` AND `job_start` REFUSE**, without a `want`: the lists
/// above, by basename, and a program by path that git does not track.
pub fn refuse(h: *Host, run: *Run, pos: ast.Pos, who: []const u8, argv0: []const u8, cwd: []const u8, want: ?[]const u8) Error!void {
    if (want != null) return;
    const base = baseName(argv0);
    const bare = std.mem.trimEnd(u8, base, "0123456789");
    for (refused) |group| for (group[0]) |n| if (std.mem.eql(u8, n, base) or (bare.len > 0 and std.mem.eql(u8, n, bare)))
        return run.fail(pos, .refused, "`{s}` of `{s}`: {s}; {{want = \"tag: why\"}} to run it anyway", .{ who, base, group[1] });
    if (std.mem.indexOfScalar(u8, argv0, '/') != null and !try tracked(h, run, pos, argv0, cwd))
        return run.fail(pos, .refused, "`{s}` of `{s}`: a program by path that git does not track (a script just written?); {{want = \"tag: why\"}} to run it anyway", .{ who, argv0 });
}

fn baseName(argv0: []const u8) []const u8 {
    var b = std.fs.path.basename(argv0);
    // `python3.12` is `python3`: a version's `.N` parts dropped.
    while (std.mem.lastIndexOfScalar(u8, b, '.')) |dot| {
        const tail = b[dot + 1 ..];
        if (tail.len == 0) break;
        for (tail) |c| if (!std.ascii.isDigit(c)) return b;
        b = b[0..dot];
    }
    return b;
}

const Opts = struct {
    timeout_ms: ?u64 = null,
    re: ?[]const u8 = null,
    not_re: ?[]const u8 = null,
    nocase: bool = false,
    before: usize = 0,
    after: usize = 0,
    head: ?usize = null,
    tail: ?usize = null,
    width: usize = 200,
    whole: ?usize = null,
    log: ?Value = null,
    cwd: ?Value = null,
    stdin: ?Value = null,
    env: ?*script.value.Table = null,
    secrets: ?*script.value.Table = null,
    want: ?[]const u8 = null,
};

pub fn intOpt(run: *Run, pos: ast.Pos, k: []const u8, x: Value) Error!u64 {
    return switch (x) {
        .int => |n| if (n < 0) run.fail(pos, .argument, "`run`: its `{s}` must be 0 or more, not {d}", .{ k, n }) else @intCast(n),
        else => run.fail(pos, .type, "`run`: its `{s}` must be an integer, not {s}", .{ k, x.typeName() }),
    };
}

pub fn strOpt(run: *Run, pos: ast.Pos, k: []const u8, x: Value) Error![]const u8 {
    return switch (x) {
        .string => |s| s,
        else => run.fail(pos, .type, "`run`: its `{s}` must be a string, not {s}", .{ k, x.typeName() }),
    };
}

pub fn mapOpt(run: *Run, pos: ast.Pos, k: []const u8, x: Value) Error!*script.value.Table {
    return switch (x) {
        .table => |t| if (t.kind == .list) run.fail(pos, .type, "`run`: its `{s}` must be a map, not a list", .{k}) else t,
        else => run.fail(pos, .type, "`run`: its `{s}` must be a map, not {s}", .{ k, x.typeName() }),
    };
}

fn readOpts(run: *Run, pos: ast.Pos, v: Value) Error!Opts {
    var o: Opts = .{};
    const m = switch (v) {
        .table => |t| if (t.kind == .list) return run.fail(pos, .type, "`run`'s options are a map, `{{timeout_ms = ..., tail = ...}}`, not a list", .{}) else t,
        else => return run.fail(pos, .type, "`run`'s options are a map, not {s}", .{v.typeName()}),
    };
    for (m.map.keys(), m.map.values()) |k, x| {
        if (std.mem.eql(u8, k, "timeout_ms")) o.timeout_ms = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "re")) o.re = try strOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "not_re")) o.not_re = try strOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "nocase")) o.nocase = switch (x) {
            .boolean => |b| b,
            else => return run.fail(pos, .type, "`run`: its `nocase` must be true or false, not {s}", .{x.typeName()}),
        } else if (std.mem.eql(u8, k, "before")) o.before = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "after")) o.after = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "head")) o.head = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "tail")) o.tail = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "width")) o.width = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "whole")) o.whole = try intOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "log")) o.log = x else if (std.mem.eql(u8, k, "cwd")) o.cwd = x else if (std.mem.eql(u8, k, "stdin")) o.stdin = x else if (std.mem.eql(u8, k, "env")) o.env = try mapOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "secrets")) o.secrets = try mapOpt(run, pos, k, x) else if (std.mem.eql(u8, k, "want")) o.want = try strOpt(run, pos, k, x) else return run.fail(pos, .argument, "`run` takes timeout_ms, re, not_re, nocase, before, after, head, tail, width, whole, log, cwd, stdin, env, secrets and want, not `{s}`", .{k});
    }
    if (o.timeout_ms == null) return run.fail(pos, .argument, "`run` needs `timeout_ms`: how long the program may take is the script's to say", .{});
    if (o.whole) |_| {
        if (o.re != null or o.not_re != null or o.head != null or o.tail != null or o.before > 0 or o.after > 0 or o.nocase)
            return run.fail(pos, .argument, "`run`'s `whole` keeps everything, and takes no filter or keep (`re`, `not_re`, `nocase`, `before`, `after`, `head`, `tail`)", .{});
    } else if (o.head == null and o.tail == null) return run.fail(pos, .argument, "`run` needs a keep: `head`, `tail` (or both), or `whole = N`: what to keep of the output is the script's to say", .{});
    if ((o.before > 0 or o.after > 0) and o.re == null) return run.fail(pos, .argument, "`run`'s `before` and `after` are a match's context, and need `re`", .{});
    return o;
}

/// **THE SCRUBBER**: a secret's bytes replaced by `<secret K>` in all a
/// program prints, before the filter, the keep and the log; a secret split
/// across reads is held back until it can be told.
pub const Scrub = struct {
    alloc: std.mem.Allocator,
    secrets: []const [2][]const u8 = &.{},
    carry: std.ArrayList(u8) = .empty,
    next: *Out,

    pub fn write(s: *Scrub, bytes: []const u8) Sink.Error!void {
        if (s.secrets.len == 0) return s.next.write(bytes);
        try s.carry.appendSlice(s.alloc, bytes);
        try s.scan(false);
    }

    /// The carry scrubbed and passed on, but for what may be a secret's
    /// start when more is to come (`last` false). At each place, a
    /// secret the rest is the start of is waited for, though a shorter one
    /// is whole there (`abc` and `abcdef`: `abc` at a read's end may go on
    /// to the longer); then the longest whole one is told, so a secret that
    /// begins another never tells the other's rest.
    fn scan(s: *Scrub, last: bool) Sink.Error!void {
        const buf = s.carry.items;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.alloc);
        var i: usize = 0;
        scan: while (i < buf.len) {
            const rest = buf[i..];
            if (!last) for (s.secrets) |kv| if (rest.len < kv[1].len and std.mem.startsWith(u8, kv[1], rest)) break :scan;
            var best: ?[2][]const u8 = null;
            for (s.secrets) |kv| if (std.mem.startsWith(u8, rest, kv[1]) and (best == null or kv[1].len > best.?[1].len)) {
                best = kv;
            };
            if (best) |kv| {
                // **OVERLAPS TOLD AS ONE**: a secret that starts inside this
                // one and runs past its end (`abc`, `bcdef` in `abcdef`)
                // widens what is told, so none of it is left raw; one that
                // may still go on in the next read is waited for.
                var end = i + kv[1].len;
                var j = i + 1;
                while (j < end) : (j += 1) for (s.secrets) |o| {
                    const at = buf[j..];
                    if (std.mem.startsWith(u8, at, o[1])) {
                        end = @max(end, j + o[1].len);
                    } else if (!last and at.len < o[1].len and std.mem.startsWith(u8, o[1], at)) break :scan;
                };
                try out.print(s.alloc, "<secret {s}>", .{kv[0]});
                i = end;
                continue :scan;
            }
            try out.append(s.alloc, buf[i]);
            i += 1;
        }
        try s.next.write(out.items);
        std.mem.copyForwards(u8, s.carry.items, buf[i..]);
        s.carry.shrinkRetainingCapacity(buf.len - i);
    }

    /// The output ended: what was held, scrubbed with nothing more to come.
    pub fn finish(s: *Scrub) Sink.Error!void {
        if (s.secrets.len == 0) return;
        try s.scan(true);
    }
};

/// The scrubbed output's two ends: the log, whole, and the keep or the
/// collected `whole`.
pub const Out = struct {
    alloc: std.mem.Allocator,
    log: ?*std.Io.File.Writer = null,
    log_failed: bool = false,
    keeper: ?*keep.Keep = null,
    whole: ?*std.ArrayList(u8) = null,
    whole_most: usize = 0,
    whole_over: bool = false,
    bytes: u64 = 0,

    fn write(o: *Out, bytes: []const u8) Sink.Error!void {
        o.bytes += bytes.len;
        if (o.log) |w| if (!o.log_failed) w.interface.writeAll(bytes) catch {
            o.log_failed = true;
        };
        if (o.keeper) |k| try k.feed(bytes);
        if (o.whole) |w| {
            if (w.items.len + bytes.len > o.whole_most) o.whole_over = true else try w.appendSlice(o.alloc, bytes);
        }
    }
};

fn runProgram(h: *Host, run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    if (args.len != 2) return run.fail(pos, .argument, "`run` takes argv and its options, `run({{\"zig\", \"build\"}}, {{timeout_ms = ..., tail = 20}})`, given {d} arguments", .{args.len});
    const a = run.alloc;
    const argv_t = switch (args[0]) {
        .table => |t| if (t.kind == .map) return run.fail(pos, .type, "`run`'s argv is a list of strings, not a map", .{}) else t,
        else => return run.fail(pos, .type, "`run`'s argv is a list of strings, `{{\"zig\", \"build\"}}`, not {s}", .{args[0].typeName()}),
    };
    if (argv_t.kind == .empty or argv_t.list.items.len == 0) return run.fail(pos, .argument, "`run` of an empty argv: name the program", .{});
    const argv = a.alloc([]const u8, argv_t.list.items.len) catch return run.oom(pos);
    for (argv_t.list.items, argv, 0..) |v, *s, i| s.* = switch (v) {
        .string => |x| x,
        else => return run.fail(pos, .type, "`run`'s argv[{d}] is {s}, not a string: every argument is one, written as the program takes it", .{ i + 1, v.typeName() }),
    };
    const o = try readOpts(run, pos, args[1]);
    try run.charge(pos, argv.len);

    if (run.host_runs >= runs_most) {
        run.stop = .{ .line = pos.line, .column = pos.column, .class = .budget, .budget = .runs, .function = run.function, .trail = run.calls.items, .message = std.fmt.allocPrint(a, "{d} programs a run, the most: run the rest in another", .{runs_most}) catch "too many programs in one run" };
        return error.Stop;
    }

    const cwd = if (o.cwd) |c| try osPath(h, run, pos, c, true) else try rootOf(h, run, pos);
    try refuse(h, run, pos, "run", argv[0], cwd, o.want);

    // The environment: inherited, `env` added, `secrets` read in.
    var env: std.ArrayList([]const u8) = .empty;
    var secrets: std.ArrayList([2][]const u8) = .empty;
    var shown_env: std.ArrayList(u8) = .empty;
    const extra = if (o.env) |t| t.map.keys() else &.{};
    const secret_keys = if (o.secrets) |t| t.map.keys() else &.{};
    for (h.env) |e| {
        const k = e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
        const over = for (extra) |x| {
            if (std.mem.eql(u8, x, k)) break true;
        } else for (secret_keys) |x| {
            if (std.mem.eql(u8, x, k)) break true;
        } else false;
        if (!over) env.append(a, e) catch return run.oom(pos);
    }
    if (o.env) |t| for (t.map.keys(), t.map.values()) |k, x| {
        const v = try strOpt(run, pos, "env", x);
        env.append(a, std.fmt.allocPrint(a, "{s}={s}", .{ k, v }) catch return run.oom(pos)) catch return run.oom(pos);
        shown_env.print(a, " {s}={s}", .{ k, v }) catch return run.oom(pos);
    };
    if (o.secrets) |t| for (t.map.keys(), t.map.values()) |k, x| {
        const path = try osPath(h, run, pos, x, false);
        const shown = switch (x) {
            .string => |s| s,
            else => "",
        };
        const bytes = std.Io.Dir.cwd().readFileAlloc(run.io, path, a, .limited(64 * 1024)) catch |e|
            return run.fail(pos, .store, "`run`: the secret `{s}`'s file {s} cannot be read: {s}", .{ k, shown, @errorName(e) });
        const v = std.mem.trim(u8, bytes, " \t\r\n");
        if (v.len == 0) return run.fail(pos, .argument, "`run`: the secret `{s}`'s file {s} is empty", .{ k, shown });
        env.append(a, std.fmt.allocPrint(a, "{s}={s}", .{ k, v }) catch return run.oom(pos)) catch return run.oom(pos);
        secrets.append(a, .{ k, v }) catch return run.oom(pos);
        shown_env.print(a, " {s}=<secret {s}>", .{ k, shown }) catch return run.oom(pos);
    };

    // stdin: a string, or a result of a `whole` run.
    const stdin: ?[]const u8 = if (o.stdin) |v| switch (v) {
        .string => |s| s,
        .table => |t| blk: {
            if (t.kind != .map) return run.fail(pos, .type, "`run`'s stdin is a string or a run's result, not a list", .{});
            const whole = t.map.get("whole") orelse break :blk null;
            if (whole != .boolean or !whole.boolean) break :blk null;
            break :blk switch (t.map.get("out") orelse Value.nil) {
                .string => |s| s,
                else => null,
            };
        },
        else => return run.fail(pos, .type, "`run`'s stdin is a string or a run's result, not {s}", .{v.typeName()}),
    } else null;
    if (o.stdin != null and stdin == null) return run.fail(pos, .argument, "`run`'s stdin is a kept result: its `out` is not the program's output (lines left out, lines cut); run it with `whole = N` to pipe it", .{});

    // **THE STREAM'S OWN MEMORY**: what grows as the output arrives (the
    // keep, `whole`'s buffer, the scrub's carry) grows by how the pipe's
    // reads fall, which is the scheduler's. In the run's arena that made
    // the arena's size the scheduler's too, and the gate, which holds the
    // engines' arenas equal, failed a 141 KB `git show` at random. So it
    // is the host's, live and capped (`Capped`), and only the results go
    // to the arena.
    var capped: Capped = .{ .backing = h.alloc, .most = run.budgets.arena_bytes -| run.budgeted.held };
    const sa = capped.allocator();
    // The output's ends: the log, the keep or `whole`.
    var out: Out = .{ .alloc = sa };
    var log_file: ?std.Io.File = null;
    var log_buf: [16 * 1024]u8 = undefined;
    var log_writer: std.Io.File.Writer = undefined;
    var log_shown: []const u8 = "";
    if (o.log) |l| {
        const path = try osPath(h, run, pos, l, false);
        log_shown = switch (l) {
            .string => |s| s,
            else => "",
        };
        const f = std.Io.Dir.cwd().createFile(run.io, path, .{ .truncate = true }) catch |e|
            return run.fail(pos, .store, "`run`: its log {s} cannot be written: {s}", .{ log_shown, @errorName(e) });
        log_file = f;
        log_writer = f.writer(run.io, &log_buf);
        out.log = &log_writer;
    }
    defer if (log_file) |f| {
        log_writer.interface.flush() catch {};
        f.close(run.io);
    };
    var whole_buf: std.ArrayList(u8) = .empty;
    defer whole_buf.deinit(sa);
    var compiled: [2]?regex.Program = .{ null, null };
    var scratches: [2]?regex.Scratch = .{ null, null };
    var keeper: keep.Keep = undefined;
    if (o.whole) |n| {
        out.whole = &whole_buf;
        out.whole_most = n;
    } else {
        var ko: keep.Options = .{ .head = o.head orelse 0, .tail = o.tail orelse 0, .width = o.width, .before = o.before, .after = o.after };
        for ([_]?[]const u8{ o.re, o.not_re }, 0..) |pat, i| if (pat) |p| {
            var why: regex.Refusal = undefined;
            compiled[i] = regex.compile(a, p, .{ .nocase = o.nocase }, &why) catch |e| switch (e) {
                error.OutOfMemory => return run.oom(pos),
                error.Refused => return run.fail(pos, .argument, "`run`'s `{s}`, at its byte {d}: {s}", .{ if (i == 0) "re" else "not_re", why.at + 1, why.message }),
            };
            scratches[i] = regex.Scratch.init(a, &compiled[i].?) catch return run.oom(pos);
            const pattern: keep.Pattern = .{ .program = &compiled[i].?, .scratch = &scratches[i].? };
            if (i == 0) ko.re = pattern else ko.not_re = pattern;
        };
        keeper = keep.Keep.init(sa, ko) catch return run.oom(pos);
        out.keeper = &keeper;
    }
    defer if (out.keeper) |k| k.deinit();
    var scrub: Scrub = .{ .alloc = sa, .secrets = secrets.items, .next = &out };
    defer scrub.carry.deinit(sa);
    var sink: Sink = .{ .host = h, .scrub = &scrub };

    run.host_runs += 1;
    const outcome = h.spawn_fn(h.spawn_ctx, h.alloc, .{ .argv = argv, .cwd = cwd, .env = env.items, .stdin = stdin, .timeout_ms = o.timeout_ms.? }, &sink) catch |e| switch (e) {
        error.OutOfMemory => return if (capped.hit) streamOver(run, pos, capped.most) else run.oom(pos),
        error.NotFound => return run.fail(pos, .host, "`run`: `{s}` is not found{s}", .{ argv[0], if (std.mem.indexOfScalar(u8, argv[0], '/') == null) " along PATH" else "" }),
        error.NotRunnable => return run.fail(pos, .host, "`run`: `{s}` is there but cannot be run (its permissions, or not a program)", .{argv[0]}),
        error.NoCwd => return run.fail(pos, .argument, "`run`: its cwd is not a folder that can be entered", .{}),
        error.Spawn => return run.fail(pos, .host, "`run`: the program could not be started (a pipe, a fork or a pidfd refused)", .{}),
    };
    scrub.finish() catch return if (capped.hit) streamOver(run, pos, capped.most) else run.oom(pos);

    // What the run spent: a step a 16 bytes read, as bulk work, in
    // read_bytes; and the filter's searches.
    try script.builtins.chargeBytes(run, pos, out.bytes);
    run.read_bytes += out.bytes;
    const joined = std.mem.join(a, " ", argv) catch return run.oom(pos);
    h.record("run {s}{s}{s}{s} -> {s}{s} ({d} ms)", .{
        joined,                                 shown_env.items,
        if (o.want != null) " (want: " else "", if (o.want) |w| std.fmt.allocPrint(a, "{s})", .{w}) catch w else "",
        @tagName(outcome.ended),                if (outcome.code) |c| std.fmt.allocPrint(a, " {d}", .{c}) catch "" else "",
        outcome.ms,
    });
    // Its last bytes flushed before the record says whether it is whole.
    if (log_file != null) log_writer.interface.flush() catch {
        out.log_failed = true;
    };
    if (o.log != null) h.record("log {s}{s}", .{ log_shown, if (out.log_failed) ": a write failed, the log is short" else "" });

    const r = try run.newTable(pos);
    r.kind = .map;
    const argv_list = try run.newTable(pos);
    argv_list.kind = .list;
    for (argv) |s| argv_list.list.append(a, .{ .string = s }) catch return run.oom(pos);
    r.map.put(a, "argv", .{ .table = argv_list }) catch return run.oom(pos);
    if (outcome.code) |c| if (outcome.ended == .exit) r.map.put(a, "code", .{ .int = c }) catch return run.oom(pos);
    r.map.put(a, "ended", .{ .string = switch (outcome.ended) {
        .exit => "exit",
        .timeout => "timeout",
        .signal => "signal",
        .interrupted => "signal",
    } }) catch return run.oom(pos);
    r.map.put(a, "ms", .{ .int = @intCast(outcome.ms) }) catch return run.oom(pos);
    if (o.whole) |n| {
        if (out.whole_over) return run.fail(pos, .argument, "`run`: the output passed `whole = {d}` bytes ({d}): a keep, `head` and `tail`, takes any size", .{ n, out.bytes });
        const lines = countLines(whole_buf.items);
        r.map.put(a, "out", .{ .string = a.dupe(u8, whole_buf.items) catch return run.oom(pos) }) catch return run.oom(pos);
        r.map.put(a, "whole", .{ .boolean = true }) catch return run.oom(pos);
        for ([_][]const u8{ "total_lines", "matched_lines", "kept_lines" }) |k| r.map.put(a, k, .{ .int = @intCast(lines) }) catch return run.oom(pos);
    } else {
        const kept = keeper.finish() catch return if (capped.hit) streamOver(run, pos, capped.most) else run.oom(pos);
        defer sa.free(kept.out);
        try run.charge(pos, kept.work);
        r.map.put(a, "out", .{ .string = a.dupe(u8, kept.out) catch return run.oom(pos) }) catch return run.oom(pos);
        r.map.put(a, "total_lines", .{ .int = @intCast(kept.total) }) catch return run.oom(pos);
        r.map.put(a, "matched_lines", .{ .int = @intCast(kept.matched) }) catch return run.oom(pos);
        r.map.put(a, "kept_lines", .{ .int = @intCast(kept.kept) }) catch return run.oom(pos);
    }
    if (run.read_bytes > run.budgets.read_bytes) return run.budgetStop(pos, .read_bytes);
    // An interrupted shale stops here, after the program's group is gone.
    if (outcome.ended == .interrupted) return run.fail(pos, .host, "`run`: shale was told to stop (TERM or HUP) while `{s}` ran; it was ended", .{argv[0]});
    return .{ .table = r };
}

/// **WHAT A RUN'S STREAM HOLDS, LIVE AND CAPPED**: the host's allocator,
/// every free given back, and at most `most` bytes live at once (what is
/// left of the run's arena budget). A tail of 3 over a 10 GB log holds three lines; a keep
/// that needs more than the budget stops the run (`streamOver`).
pub const Capped = struct {
    backing: std.mem.Allocator,
    most: usize,
    live: usize = 0,
    /// Whether an allocation was refused for the cap, not by the backing.
    hit: bool = false,

    pub fn allocator(c: *Capped) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn fits(c: *Capped, more: usize) bool {
        if (more <= c.most -| c.live) return true;
        c.hit = true;
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (!c.fits(len)) return null;
        const p = c.backing.rawAlloc(len, al, ra) orelse return null;
        c.live += len;
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and !c.fits(new_len - mem.len)) return false;
        if (!c.backing.rawResize(mem, al, new_len, ra)) return false;
        c.live = c.live - mem.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and !c.fits(new_len - mem.len)) return null;
        const p = c.backing.rawRemap(mem, al, new_len, ra) orelse return null;
        c.live = c.live - mem.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        c.backing.rawFree(mem, al, ra);
        c.live -= mem.len;
    }
};

fn streamOver(run: *Run, pos: ast.Pos, most: usize) Error {
    run.stop = .{ .line = pos.line, .column = pos.column, .class = .budget, .budget = .arena, .function = run.function, .trail = run.calls.items, .message = std.fmt.allocPrint(run.alloc, "`run`: what it holds of the output is past the arena budget ({d} bytes live): a smaller `before`, `head`, `tail` or `whole`", .{most}) catch "`run`: what it holds of the output is past the arena budget" };
    return error.Stop;
}

fn countLines(s: []const u8) usize {
    var n = std.mem.count(u8, s, "\n");
    if (s.len > 0 and s[s.len - 1] != '\n') n += 1;
    return n;
}

/// Whether git tracks the program at `path` (against `cwd`): a program
/// by path that git does not is refused without a `want`.
fn tracked(h: *Host, run: *Run, pos: ast.Pos, path: []const u8, cwd: []const u8) Error!bool {
    var nothing: Out = .{ .alloc = run.alloc };
    var scrub: Scrub = .{ .alloc = run.alloc, .next = &nothing };
    var sink: Sink = .{ .host = h, .scrub = &scrub };
    const o = h.spawn_fn(h.spawn_ctx, run.alloc, .{ .argv = &.{ "git", "ls-files", "--error-unmatch", "--", path }, .cwd = cwd, .env = h.env, .timeout_ms = 10_000 }, &sink) catch |e| switch (e) {
        error.OutOfMemory => return run.oom(pos),
        else => return false,
    };
    return o.ended == .exit and o.code == 0;
}

// ── tests: the fixture the build makes, found along PATH ─────────────────

const testing = std.testing;

const T = @import("shale_test_host.zig").T;

test "host: run keeps the head and tail of what a program prints, and says how it ended and what it counted" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput(
        \\local r = host("run", {"shale-fixture", "lines", "30"}, {timeout_ms = 10000, head = 2, tail = 2})
        \\print(r.ended, r.code, r.total_lines, r.matched_lines, r.kept_lines)
        \\print(r.out)
    , "exit\t0\t30\t30\t4\nline 1\nline 2\n… 26 lines left out …\nline 29\nline 30\n\n");
    // The filter: re, not_re, nocase; an exit code that is not 0.
    try t.expectOutput(
        \\local r = host("run", {"shale-fixture", "lines", "12", "Step"}, {timeout_ms = 10000, re = "step 1", not_re = "11", nocase = true, tail = 5})
        \\print(r.matched_lines, r.out)
        \\print(host("run", {"shale-fixture", "exit", "3"}, {timeout_ms = 10000, tail = 1}).code)
    , "3\tStep 1\nStep 10\nStep 12\n\n3\n");
}

test "host: what run keeps costs the run's arena the same however its output arrives (the gate holds the engines' arenas equal)" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    // The same 200,000 bytes, 1,000 or 9,999 at a time: the same argv's
    // length, the same output. Once each, outside the gate: its arenas
    // are what is compared.
    for ([_][]const u8{ "whole = 300000", "tail = 3", "head = 2, re = \"x\"" }) |keep_with| {
        var arena: [2]usize = undefined;
        for ([_][]const u8{ "1000", "9999" }, 0..) |size, k| {
            const src = try std.fmt.allocPrint(t.arena.allocator(), "local r = host(\"run\", {{\"shale-fixture\", \"chunks\", \"200000\", \"{s}\"}}, {{timeout_ms = 20000, {s}}}) print(r.total_lines)", .{ size, keep_with });
            var r = t.runOnce(src, .atomic);
            defer r.deinit();
            try testing.expect(r.stop == null);
            try testing.expectEqualStrings("2000\n", r.output);
            arena[k] = r.arena_bytes;
        }
        if (arena[0] != arena[1]) {
            std.debug.print("{s}: {d} arena bytes in pieces of 1,000, {d} in pieces of 9,999\n", .{ keep_with, arena[0], arena[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "host: what run holds of a stream is its live bytes, capped by the arena budget: lines it drops are given back, and a keep that needs more stops" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    // 20,000 lines of about 1 KB: 20 MB through the keep, more than the
    // 16 MiB arena budget. With 100 lines of context held, it finishes: the
    // lines dropped were given back.
    const long = "x" ** 1000;
    var r = t.runOnce("local r = host(\"run\", {\"shale-fixture\", \"lines\", \"20000\", \"" ++ long ++ "\"}, {timeout_ms = 60000, re = \"^nothing\", before = 100, tail = 1, width = 2000}) print(r.total_lines, r.kept_lines)", .atomic);
    defer r.deinit();
    if (r.stop) |s| std.debug.print("stopped: {s}\n", .{s.message});
    try testing.expectEqualStrings("20000\t0\n", r.output);
    // With 18,000 held (about 18 MB live), the budget stops it, named.
    var big = t.runOnce("host(\"run\", {\"shale-fixture\", \"lines\", \"20000\", \"" ++ long ++ "\"}, {timeout_ms = 60000, re = \"^nothing\", before = 18000, tail = 1, width = 2000})", .atomic);
    defer big.deinit();
    const s = big.stop orelse return error.TestUnexpectedResult;
    try testing.expectEqual(script.diag.Class.budget, s.class);
    try testing.expect(std.mem.indexOf(u8, s.message, "past the arena budget") != null);
}

test "host: run's options are the script's to say; what it is given wrong stops, saying what to give" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {tail = 1})", .atomic, .argument, "needs `timeout_ms`");
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {timeout_ms = 10})", .atomic, .argument, "needs a keep");
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {timeout_ms = 10, whole = 10, tail = 1})", .atomic, .argument, "takes no filter or keep");
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {timeout_ms = 10, tail = 1, after = 2})", .atomic, .argument, "need `re`");
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {timeout_ms = 10, tail = 1, color = true})", .atomic, .argument, "not `color`");
    try t.expectStop("host(\"run\", {}, {timeout_ms = 10, tail = 1})", .atomic, .argument, "empty argv");
    try t.expectStop("host(\"run\", {\"shale-fixture\", 3}, {timeout_ms = 10, tail = 1})", .atomic, .type, "argv[2]");
    try t.expectStop("host(\"run\", {\"no-such-program-here\"}, {timeout_ms = 1000, tail = 1})", .atomic, .host, "not found along PATH");
    try t.expectStop("host(\"run\", {\"shale-fixture\"}, {timeout_ms = 10, tail = 1, re = \"a{2}\"})", .atomic, .argument, "`run`'s `re`");
    try t.expectStop("host(\"jobs\", 1)", .atomic, .host, "`jobs`: not on this host");
}

test "host: what run refuses without a want, by name and by an untracked path; a want runs it" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    for ([_][]const u8{ "bash", "/usr/bin/python3.12", "grep", "xargs", "sed", "bash5.2", "perl5", "/usr/bin/python3" }) |name| {
        var src: [256]u8 = undefined;
        try t.expectStop(try std.fmt.bufPrint(&src, "host(\"run\", {{\"{s}\", \"x\"}}, {{timeout_ms = 1000, tail = 1}})", .{name}), .atomic, .refused, "want =");
    }
    // A program by path that git does not track: the fixture, by its path.
    var buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const path = t.path_env["PATH=".len..std.mem.indexOfScalar(u8, t.path_env, ':').?];
    try t.expectStop(try std.fmt.bufPrint(&buf, "host(\"run\", {{\"{s}/shale-fixture\", \"lines\", \"1\"}}, {{timeout_ms = 10000, tail = 1}})", .{path}), .atomic, .refused, "git does not track");
    try t.expectOutput(try std.fmt.bufPrint(&buf, "print(host(\"run\", {{\"{s}/shale-fixture\", \"lines\", \"1\"}}, {{timeout_ms = 10000, tail = 1, want = \"test: the fixture\"}}).out)", .{path}), "line 1\n\n");
    // The want is in what the CLI lists.
    try testing.expect(std.mem.indexOf(u8, t.host.records.items[t.host.records.items.len - 1].line, "(want: test: the fixture)") != null);
}

test "host: a timeout is a result" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput(
        \\local r = host("run", {"shale-fixture", "sleep", "20000"}, {timeout_ms = 200, tail = 1})
        \\print(r.ended, has_key(r, "code"), r.ms < 5000)
    , "timeout\tfalse\ttrue\n");
}

test "host: env adds to what a program inherits; a secret reaches it and never comes back, in out or in the log" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.put("key.txt", "s3cret-value\n");
    try t.expectOutput(
        \\local r = host("run", {"shale-fixture", "env", "MODE"}, {timeout_ms = 10000, tail = 1, env = {MODE = "pci"}})
        \\print(r.out)
        \\local s = host("run", {"shale-fixture", "env", "API_KEY"}, {timeout_ms = 10000, tail = 1, secrets = {API_KEY = "key.txt"}, log = "run.log"})
        \\print(s.out)
    , "pci\n\n<secret API_KEY>\n\n");
    try testing.expectEqualStrings("<secret API_KEY>\n", try t.file("run.log"));
    for (t.host.records.items) |r| try testing.expect(std.mem.indexOf(u8, r.line, "s3cret") == null);
    try testing.expect(std.mem.indexOf(u8, t.host.records.items[t.host.records.items.len - 2].line, "API_KEY=<secret key.txt>") != null);
    // A secret split across the pipe's reads is still scrubbed.
    var scrub_out: Out = .{ .alloc = testing.allocator, .whole = undefined, .whole_most = 1 << 20 };
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    scrub_out.whole = &got;
    var scrub: Scrub = .{ .alloc = testing.allocator, .secrets = &.{.{ "K", "abcdef" }}, .next = &scrub_out };
    defer scrub.carry.deinit(testing.allocator);
    for ([_][]const u8{ "x ab", "cd", "ef y abc", "Z abcde" }) |piece| try scrub.write(piece);
    try scrub.finish();
    try testing.expectEqualStrings("x <secret K> y abcZ abcde", got.items);
}

test "host: the scrubber: a secret that begins another is never told for it, whole or split, nor left raw at the end" {
    const Case = struct { pieces: []const []const u8, want: []const u8 };
    for ([_]Case{
        .{ .pieces = &.{"x abcdef y"}, .want = "x <secret LONG> y" },
        .{ .pieces = &.{ "x abc", "def y" }, .want = "x <secret LONG> y" },
        .{ .pieces = &.{ "x abc", "dX y" }, .want = "x <secret SHORT>dX y" },
        .{ .pieces = &.{"x abc"}, .want = "x <secret SHORT>" },
        .{ .pieces = &.{ "x ab", "c" }, .want = "x <secret SHORT>" },
    }) |c| {
        var out: Out = .{ .alloc = testing.allocator, .whole = undefined, .whole_most = 1 << 20 };
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        out.whole = &got;
        var scrub: Scrub = .{ .alloc = testing.allocator, .secrets = &.{ .{ "SHORT", "abc" }, .{ "LONG", "abcdef" } }, .next = &out };
        defer scrub.carry.deinit(testing.allocator);
        for (c.pieces) |piece| try scrub.write(piece);
        try scrub.finish();
        try testing.expectEqualStrings(c.want, got.items);
    }
}

test "host: the scrubber: secrets that overlap are told as one, none of either left raw, whole or split" {
    const Case = struct { pieces: []const []const u8, want: []const u8 };
    for ([_]Case{
        .{ .pieces = &.{"x abcdef y"}, .want = "x <secret A> y" },
        .{ .pieces = &.{ "x abcd", "ef y" }, .want = "x <secret A> y" },
        .{ .pieces = &.{"x abcdX y"}, .want = "x <secret A>dX y" },
        .{ .pieces = &.{"x bcdef y"}, .want = "x <secret B> y" },
    }) |c| {
        var out: Out = .{ .alloc = testing.allocator, .whole = undefined, .whole_most = 1 << 20 };
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        out.whole = &got;
        var scrub: Scrub = .{ .alloc = testing.allocator, .secrets = &.{ .{ "A", "abc" }, .{ "B", "bcdef" } }, .next = &out };
        defer scrub.carry.deinit(testing.allocator);
        for (c.pieces) |piece| try scrub.write(piece);
        try scrub.finish();
        try testing.expectEqualStrings(c.want, got.items);
    }
}

test "host: whole keeps everything up to its bound and pipes into stdin; a kept result is refused as stdin" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.expectOutput(
        \\local a = host("run", {"shale-fixture", "lines", "3"}, {timeout_ms = 10000, whole = 1000})
        \\local b = host("run", {"shale-fixture", "cat"}, {timeout_ms = 10000, whole = 1000, stdin = a})
        \\local c = host("run", {"shale-fixture", "cat"}, {timeout_ms = 10000, tail = 1, stdin = "typed\n"})
        \\print(b.out .. c.out, a.total_lines)
    , "line 1\nline 2\nline 3\ntyped\n\t3\n");
    try t.expectStop("host(\"run\", {\"shale-fixture\", \"lines\", \"300\"}, {timeout_ms = 10000, whole = 100})", .atomic, .argument, "passed `whole = 100` bytes");
    try t.expectStop("local a = host(\"run\", {\"shale-fixture\", \"lines\", \"3\"}, {timeout_ms = 10000, tail = 1}) host(\"run\", {\"shale-fixture\", \"cat\"}, {timeout_ms = 10000, tail = 1, stdin = a})", .atomic, .argument, "a kept result");
    // The log is the whole stream, whatever is kept.
    try t.expectOutput("print(host(\"run\", {\"shale-fixture\", \"lines\", \"5\"}, {timeout_ms = 10000, tail = 1, log = \"five.log\"}).out)", "… 4 lines left out …\nline 5\n\n");
    try testing.expectEqualStrings("line 1\nline 2\nline 3\nline 4\nline 5\n", try t.file("five.log"));
}

test "host: mounts: a mount's paths, real() for argv, an unknown mount or a missing folder named; the mounts file's mistakes, by line" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.createDirPath(t.threaded.io(), "elsewhere/logs");
    const a = t.arena.allocator();
    var why: []const u8 = "";
    const mounts = try parseMounts(a, try std.fmt.allocPrint(a, "# where things are\n\nruns = {s}/elsewhere\nhome = ~/\ngone = /no/such/folder\n", .{t.root}), "/home/someone", &why);
    try testing.expectEqualStrings("/home/someone", mounts[1].dir);
    t.host.mounts = mounts;
    try t.expectOutput(
        \\replace("runs:logs/a.txt", "via the mount")
        \\print(read("runs:logs/a.txt"), exists("runs:"), sub(host("real", "runs:logs"), -14), sub(host("real", ""), 1, 1))
    , "via the mount\ttrue\telsewhere/logs\t/\n");
    try testing.expectEqualStrings("via the mount", try t.file("elsewhere/logs/a.txt"));
    // A program's cwd and log through a mount.
    try t.expectOutput("print(sub(host(\"run\", {\"shale-fixture\", \"pwd\"}, {timeout_ms = 10000, tail = 1, cwd = \"runs:logs\"}).out, -15))", "elsewhere/logs\n\n");
    // (The pwd's log would differ per gate copy: a fixed program's, instead.)
    try t.expectOutput("print(host(\"run\", {\"shale-fixture\", \"lines\", \"2\"}, {timeout_ms = 10000, tail = 1, log = \"runs:two.log\"}).kept_lines)", "1\n");
    try testing.expectEqualStrings("line 1\nline 2\n", try t.file("elsewhere/two.log"));
    try t.expectStop("read(\"nope:x\")", .atomic, .argument, "the mounts are `runs`, `home`, `gone`");
    try t.expectStop("read(\"gone:x\")", .atomic, .store, "not a folder there");
    try t.expectStop("read(\"runs:../x\")", .atomic, .argument, "not a name");
    try t.expectStop("read(\"runs:/etc/passwd\")", .atomic, .argument, "absolute inside its mount");
    for ([_]struct { []const u8, []const u8 }{
        .{ "runs = relative/path\n", "line 1: `runs`'s value `relative/path` is relative" },
        .{ "a = /x\na = /y\n", "line 2: the mount `a` is named twice" },
        .{ "# c\njust words\n", "line 2: `just words` is not `name = value`" },
        .{ "bad name = /x\n", "is not a mount's name" },
    }) |c| {
        try testing.expectError(error.Malformed, parseMounts(a, c[0], "/home/x", &why));
        try testing.expect(std.mem.indexOf(u8, why, c[1]) != null);
    }
}

test "host: the CLI's environment: inherited, ZIG_PROGRESS out" {
    var m: std.process.Environ.Map = .init(testing.allocator);
    defer m.deinit();
    try m.put("HOME", "/home/x");
    try m.put("ZIG_PROGRESS", "3");
    try m.put("PATH", "/bin");
    const env = try baseEnv(testing.allocator, &m);
    defer {
        for (env) |e| testing.allocator.free(e);
        testing.allocator.free(env);
    }
    try testing.expectEqual(@as(usize, 2), env.len);
    try testing.expectEqualStrings("HOME=/home/x", env[0]);
    try testing.expectEqualStrings("PATH=/bin", env[1]);
}

test "host: the mounts file: SHALE_MOUNTS pins it; the default's absence is no mounts, a pinned one's a mistake" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const io = t.threaded.io();
    var why: []const u8 = "";
    const none = try loadMounts(a, io, null, "/no/such/home", &why);
    try testing.expectEqual(@as(usize, 0), none.mounts.len);
    try testing.expectEqualStrings("/no/such/home/.config/shale/mounts", none.from);
    try testing.expectError(error.Malformed, loadMounts(a, io, "/no/such/mounts", "/h", &why));
    try testing.expectEqualStrings("SHALE_MOUNTS=/no/such/mounts: FileNotFound", why);
    try t.tmp.dir.writeFile(io, .{ .sub_path = "mounts", .data = "runs = ~/runs\n" });
    const file = try std.fmt.allocPrint(a, "{s}/mounts", .{t.root});
    const got = try loadMounts(a, io, file, "/h", &why);
    try testing.expectEqualStrings("/h/runs", got.mounts[0].dir);
    try testing.expectEqualStrings(file, got.from);
    try t.tmp.dir.writeFile(io, .{ .sub_path = "mounts", .data = "runs = runs\n" });
    try testing.expectError(error.Malformed, loadMounts(a, io, file, "/h", &why));
    try testing.expect(std.mem.startsWith(u8, why, file));
    try testing.expect(std.mem.endsWith(u8, why, ": line 1: `runs`'s value `runs` is relative: an absolute path, or one from `~/`"));
}

/// A spawn that runs nothing: the bytes it is told to give, every time.
const Fake = struct {
    out: []const u8,
    calls: usize = 0,
    fn spawnFn(ctx: ?*anyopaque, _: std.mem.Allocator, _: spawn.Spec, sink: *Sink) (spawn.Error || Sink.Error)!spawn.Outcome {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.calls += 1;
        try sink.write(f.out);
        return .{ .ended = .exit, .code = 0, .ms = 1 };
    }
};

test "host: the gate's fake spawn: the same bytes into both engines, the keep and the charges the real code's; the cap on a run's programs" {
    var t: T = undefined;
    try t.init();
    defer t.deinit();
    var fake: Fake = .{ .out = "alpha\nbeta\ngamma\n" };
    t.host.spawn_fn = Fake.spawnFn;
    t.host.spawn_ctx = &fake;
    try t.expectOutput("print(host(\"run\", {\"anything\"}, {timeout_ms = 10, re = \"a$\", head = 1, tail = 1}).out)", "alpha\n… 1 line left out …\ngamma\n\n");
    // A want lets a refused name through to the spawn.
    try t.expectOutput("print(host(\"run\", {\"bash\", \"-c\", \"x\"}, {timeout_ms = 10, tail = 1, want = \"test: a fake\"}).out)", "… 2 lines left out …\ngamma\n\n");
    // 64 programs a run, the 65th a stop, counted per run (per engine).
    try t.expectStop("for i = 1, 65 do host(\"run\", {\"x\"}, {timeout_ms = 10, tail = 1}) end", .atomic, .budget, "64 programs a run");
    try t.expectOutput("for i = 1, 64 do host(\"run\", {\"x\"}, {timeout_ms = 10, tail = 1}) end print(\"ok\")", "ok\n");
}
