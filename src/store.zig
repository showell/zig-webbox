//! store: every file an application keeps, through one seam. Part of the
//! `webbox` library.
//!
//! An application's data lives under two roots, `data/` and `auth/` (secrets),
//! as named files in folders. This module is the only way to reach them, so
//! the rules of the disk the data may end up on are kept in one place:
//!
//! **THE RULES ARE FAT'S, ON EVERY HOST** (for a path under the host's roots:
//! one under neither, as with no roots in a development run, is not
//! measured). On the bare-metal host the data is a
//! FAT volume. On Linux it is not, and a Linux that allowed what FAT refuses
//! would hide the difference until the data moved. So the Store keeps FAT's
//! rules here too:
//!
//!   - **A name FAT can hold**, or the call is refused with `error.BadName`:
//!     1 to 96 bytes (`max_name`), printable ASCII, none of
//!     `" * / : < > ? \ |`, not `.` or `..`, not ending in a dot or a space.
//!   - **Case does not tell two names apart; it is kept for display.** A name
//!     that differs from an existing one only in case IS that one (Steve,
//!     2026-10-02, option 1): reading `Plan.md` finds `plan.md`, and writing
//!     `Plan.md` writes `plan.md`, where FAT would. A new name keeps the case
//!     it was given.
//!
//! The rules apply to the names a call would CREATE and to the names it looks
//! up. The roots themselves (configured paths, often absolute and long on
//! Linux) are the host's and are not checked: a path that exists is taken as
//! it is, and only a name that is not found is looked for in another case.
//!
//! **A FOLDER HOLDS AT MOST 65,536 ENTRIES ON FAT** (the spec's 2 MiB; a long
//! name takes 2 to 4 of them). The bare-metal host refuses to grow a folder
//! past it: the write that needed the room fails as a full disk would
//! (`error.NoSpaceLeft`). Linux has no such limit, and this Store does not
//! count entries on every write, so at that bound the two hosts would differ.
//! An application says how far its folders can grow, and fans a folder out
//! before it nears the bound.
//!
//! **AN ERROR IS NOT AN EMPTY FILE.** `readOrEmpty` says the difference between
//! a file that is not there ("nothing yet") and one that will not read.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// The longest name the bare-metal host reads and writes (its
/// disk_fat_dirent.zig's max_name).
pub const max_name = 96;

/// The longest path the bare-metal host holds a file by (its io.zig's max_path).
pub const max_path = 256;

/// How deep the bare-metal host removes a tree and checks a volume at boot
/// (its disk_fat.zig's max_tree_depth). A path is held to it from the
/// volume's root.
pub const max_depth = 16;

pub const Error = error{ BadName, PathTooLong, PathTooDeep };

// ── the paths the bare-metal host would hold ─────────────────────────────────
//
// **FAT'S PATH LIMITS, ON EVERY HOST, MEASURED AS THE BARE-METAL HOST SPELLS
// THE PATH.** There the data is `data/...` and `auth/...` on the volume; on
// Linux the same files are under configured roots, often absolute and long.
// So a path under a root is measured as if the root were spelled `data` or
// `auth`: what the bare-metal host would be asked to hold. A path under
// neither root (a test's temporary folder, the site's own files) is not
// measured.

/// The two roots, as this host spells them; null until the host sets them.
pub var data_base: ?[]const u8 = null;
pub var auth_base: ?[]const u8 = null;

/// The host's two directories, set as it starts.
pub fn setBases(data_dir: []const u8, auth_dir: []const u8) void {
    data_base = data_dir;
    auth_base = auth_dir;
}

/// The two roots as they were, to put back (`defer saved.restore()`): for a
/// test that moves them.
pub const Bases = struct {
    data: ?[]const u8,
    auth: ?[]const u8,
    pub fn restore(self: Bases) void {
        data_base = self.data;
        auth_base = self.auth;
    }
};

pub fn saveBases() Bases {
    return .{ .data = data_base, .auth = auth_base };
}

/// `path`'s length and depth as the bare-metal host would spell it, or null
/// when it is under neither root.
fn metalShape(path: []const u8) ?struct { len: usize, depth: usize, empty_part: bool } {
    for ([_]struct { ?[]const u8, []const u8 }{ .{ data_base, "data" }, .{ auth_base, "auth" } }) |pair| {
        const base = std.mem.trimEnd(u8, pair[0] orelse continue, "/");
        if (!std.mem.startsWith(u8, path, base)) continue;
        const rest = path[base.len..];
        if (rest.len != 0 and rest[0] != '/') continue; // "data2" is not under "data"
        var depth: usize = 1;
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |_| depth += 1;
        const empty_part = (rest.len > 0 and rest[rest.len - 1] == '/') or std.mem.indexOf(u8, rest, "//") != null;
        return .{ .len = pair[1].len + rest.len, .depth = depth, .empty_part = empty_part };
    }
    return null;
}

/// Refuses a path the bare-metal host could not hold: longer than max_path or
/// deeper than max_depth, measured as it would spell it; or one with an
/// empty part (a doubled or trailing slash), which metal refuses
/// (the bare-metal host's `ab6dd01`) and `metalShape`'s count of parts skipped
/// (metal-vmm QUEUE 156(i)): `BadName`, on both hosts alike.
fn withinLimits(path: []const u8) Error!void {
    const shape = metalShape(path) orelse return;
    if (shape.empty_part) return error.BadName;
    if (shape.len > max_path) return error.PathTooLong;
    if (shape.depth > max_depth) return error.PathTooDeep;
}

/// Whether FAT, as the bare-metal host holds it, can store `name`.
pub fn fatName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c < 0x20 or c > 0x7E) return false;
        switch (c) {
            '"', '*', '/', ':', '<', '>', '?', '\\', '|' => return false,
            else => {},
        }
    }
    const last = name[name.len - 1];
    return last != '.' and last != ' ';
}

// ── finding a name in another case ──────────────────────────────────────────

/// The name in `dir` that is `name` apart from case, if there is one. Only
/// reached when `name` itself was not found, so it costs a listing on a miss
/// and nothing on a hit.
fn sibling(io: Io, alloc: Alloc, dir: []const u8, name: []const u8) !?[]const u8 {
    var d = Io.Dir.cwd().openDir(io, if (dir.len == 0) "." else dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return try alloc.dupe(u8, entry.name);
    }
    return null;
}

/// `path` as it is on disk: the first component that is not found, and every
/// one after it, is looked for in another case. Components that do not exist
/// in any case are kept as given, so a path to something new resolves to the
/// existing folders it is under, in their case, and its own new names.
pub fn resolve(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {
    if (exists(io, path)) return path;
    const parent = std.fs.path.dirname(path) orelse "";
    const name = std.fs.path.basename(path);
    const dir = if (parent.len == 0) parent else try resolve(io, alloc, parent);
    const found = (try sibling(io, alloc, dir, name)) orelse name;
    if (dir.len == 0) return found;
    return std.fs.path.join(alloc, &.{ dir, found });
}

/// `path` resolved for a call that may create its last component: that name
/// must be one FAT holds.
fn forWrite(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {
    if (!fatName(std.fs.path.basename(path))) return error.BadName;
    try withinLimits(path);
    return resolve(io, alloc, path);
}

/// `path` resolved for a call that creates folders: every component past the
/// existing part must be a name FAT holds.
fn forMakeDir(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {
    try withinLimits(path);
    const p = try resolve(io, alloc, path);
    var rest = p;
    while (!exists(io, rest)) {
        if (!fatName(std.fs.path.basename(rest))) return error.BadName;
        rest = std.fs.path.dirname(rest) orelse break;
    }
    return p;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A lookup that missed: the same path in another case, or null when there is
/// no such thing in any case. Any other answer for the other spelling is the
/// caller's: a path through a file in another case is NotDir here, as FAT,
/// which folds case, answers it on the bare-metal host.
fn retry(io: Io, alloc: Alloc, path: []const u8) !?[]const u8 {
    const p = try resolve(io, alloc, path);
    if (std.mem.eql(u8, p, path)) return null;
    // statFile, not access: zig's access answers a path through a file as
    // FileNotFound, where statFile says NotDir.
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return p;
}

// ── reading ─────────────────────────────────────────────────────────────────

/// The whole file, up to `limit`.
pub fn read(io: Io, alloc: Alloc, path: []const u8, limit: Io.Limit) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, limit) catch |e| switch (e) {
        error.FileNotFound => {
            const p = (try retry(io, alloc, path)) orelse return e;
            return Io.Dir.cwd().readFileAlloc(io, p, alloc, limit);
        },
        else => e,
    };
}

/// The file's bytes, or "" when there is no such file. **Any other failure is
/// the caller's to deal with** -- usually by leaving alone whatever it was
/// about to overwrite.
pub fn readOrEmpty(io: Io, alloc: Alloc, path: []const u8, limit: Io.Limit) ![]u8 {
    return read(io, alloc, path, limit) catch |e| switch (e) {
        error.FileNotFound => try alloc.alloc(u8, 0),
        else => e,
    };
}

/// The file's bytes, or null when there is nothing there: a path not found,
/// through a file, or with a name too long for any file (as `has` answers
/// no). **Any other failure is the caller's**: a disk that failed a read is
/// not an absent file (metal-vmm QUEUE 105).
pub fn readOrNull(io: Io, alloc: Alloc, path: []const u8, limit: Io.Limit) !?[]u8 {
    return read(io, alloc, path, limit) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.NameTooLong => null,
        else => e,
    };
}

/// What `stat` answers, or null when there is nothing there (as
/// `readOrNull`). Any other failure is the caller's.
pub fn statOrNull(io: Io, alloc: Alloc, path: []const u8) !?Stat {
    return stat(io, alloc, path) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.NameTooLong => null,
        else => e,
    };
}

/// Up to `buf.len` bytes from `offset`; how many arrived.
pub fn readAt(io: Io, alloc: Alloc, path: []const u8, offset: u64, buf: []u8) !usize {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            const p = (try retry(io, alloc, path)) orelse return e;
            break :blk try Io.Dir.cwd().openFile(io, p, .{});
        },
        else => return e,
    };
    defer f.close(io);
    return f.readPositionalAll(io, buf, offset);
}

pub const Kind = enum { file, directory, other };

pub const Stat = struct {
    size: u64,
    kind: Kind,
    /// Nanoseconds since the epoch.
    mtime: i96,
};

/// The host's kind of entry as ours. **`anytype`, on purpose**: std.Io and
/// the bare-metal host's io name the type differently, and both have these tags.
fn kindOf(k: anytype) Kind {
    return switch (k) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

pub fn stat(io: Io, alloc: Alloc, path: []const u8) !Stat {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            const p = (try retry(io, alloc, path)) orelse return e;
            break :blk try Io.Dir.cwd().statFile(io, p, .{});
        },
        else => return e,
    };
    return .{ .size = st.size, .kind = kindOf(st.kind), .mtime = st.mtime.nanoseconds };
}

/// Whether there is a file or folder at `path`, in any case.
///
/// **"NO" ONLY FOR WHAT IS NOT THERE**: a path not found, through a file, or
/// with a name too long for any file to have it. Any other failure is the
/// caller's, who says what it means there; a disk that failed a read is not
/// an absent file.
pub fn has(io: Io, alloc: Alloc, path: []const u8) !bool {
    _ = stat(io, alloc, path) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.NameTooLong => return false,
        else => return e,
    };
    return true;
}

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// What a folder holds, in the order the disk gives it. A folder that is not
/// there holds nothing.
pub fn list(io: Io, alloc: Alloc, dir_path: []const u8) ![]Entry {
    var d = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => blk: {
            const p = (try retry(io, alloc, dir_path)) orelse return &.{};
            break :blk try Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        },
        else => return e,
    };
    defer d.close(io);
    var out: std.ArrayList(Entry) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        try out.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .kind = kindOf(entry.kind) });
    }
    return out.items;
}

// ── writing ─────────────────────────────────────────────────────────────────

pub const WriteOptions = struct {
    /// Readable by this user only, where the host has permissions (Linux).
    /// FAT has none: on the bare-metal host the volume is the boundary.
    private: bool = false,
};

/// Makes `path` hold exactly `data`, making the folders above it.
pub fn write(io: Io, alloc: Alloc, path: []const u8, data: []const u8, opts: WriteOptions) !void {
    const p = try forWrite(io, alloc, path);
    if (std.fs.path.dirname(p)) |d| try makeDir(io, alloc, d);
    // The flags are spelled in place, not named: std.Io and the bare-metal
    // host's io call their type differently.
    if (opts.private) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data, .flags = .{ .permissions = @enumFromInt(0o600) } });
    } else {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
    }
}

/// **MAKES `path` HOLD EXACTLY `data`, SO THAT NO STOP LOSES IT.** `write`
/// empties the file and then fills it (on the bare-metal host it removes
/// the entry and writes a new one), so a machine that stops between the two
/// has lost the record. This writes `data` to a sibling with a temporary name first,
/// then renames it over `path`:
///   - stopped before the rename: `path` is the old record, whole, and the
///     sibling is left over (the next replace writes over it);
///   - the rename itself: on Linux one atomic step; on the bare-metal host,
///     disk_fat.rename's order, which leaves the old record or the new, whole,
///     and at worst leaked clusters (the boot-time disk check reports them).
/// A `path` that does not exist yet is made as `write` makes it. It keeps the
/// name it has, in its case, as `write` does.
///
/// Not a lock: two replaces of one path at once share the sibling's name, so
/// the callers that need one order (a counter, a sidecar) hold their own.
/// Nothing is flushed: on Linux the rename is atomic in the namespace, but a
/// power cut can still lose recent data that the kernel had not written.
pub fn replace(io: Io, alloc: Alloc, path: []const u8, data: []const u8, opts: WriteOptions) !void {
    const p = try forWrite(io, alloc, path);
    const dir = std.fs.path.dirname(p);
    if (dir) |d| try makeDir(io, alloc, d);
    const tmp_name = try siblingName(alloc, std.fs.path.basename(p));
    const tmp = if (dir) |d| try std.fs.path.join(alloc, &.{ d, tmp_name }) else tmp_name;
    if (opts.private) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = @enumFromInt(0o600) } });
    } else {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    }
    // A rename refused (onto a folder) leaves no temporary behind; one a
    // stop interrupts does, and the next replace writes over it.
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), p, io) catch |e| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return e;
    };
}

/// **MAKES `path` HOLD `data` ONLY IF NOTHING IS THERE, WHOLE OR NOT AT
/// ALL.** Written to a temporary sibling with a name of its own (`~`, eight
/// random hex digits, `.new`, so two callers at once never share one), then
/// renamed into place without replacing: of two callers at once, one makes
/// `path` and the other is told `error.PathAlreadyExists`, its temporary
/// removed. A stop part-way leaves only the temporary. Something already at
/// `path`, in any case, is `error.PathAlreadyExists` as well.
///
/// **LINUX ONLY FOR NOW**: the bare-metal host's io has a rename that
/// replaces and none that does not, so a program that calls this does not
/// build there. Nothing the bare-metal host serves calls it (site_secret's
/// `create`, for a new site's first secret, is its one caller).
pub fn createNew(io: Io, alloc: Alloc, path: []const u8, data: []const u8, opts: WriteOptions) !void {
    const p = try forWrite(io, alloc, path);
    const dir = std.fs.path.dirname(p);
    if (dir) |d| try makeDir(io, alloc, d);
    var r: [4]u8 = undefined;
    io.random(&r);
    const tmp_name = try std.fmt.allocPrint(alloc, "~{x:0>8}.new", .{std.mem.readInt(u32, &r, .little)});
    const tmp = if (dir) |d| try std.fs.path.join(alloc, &.{ d, tmp_name }) else tmp_name;
    if (opts.private) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = @enumFromInt(0o600), .exclusive = true } });
    } else {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .exclusive = true } });
    }
    Io.Dir.cwd().renamePreserve(tmp, Io.Dir.cwd(), p, io) catch |e| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return e;
    };
}

/// The temporary name `replace` writes beside `name`: `~` and eight hex digits
/// of a hash of the name, then `.tmp`. Thirteen bytes whatever the name's
/// length, so it fits where the name does, and one per name, so replaces of
/// two files in one folder do not meet.
fn siblingName(alloc: Alloc, name: []const u8) ![]u8 {
    var lower: [max_name]u8 = undefined;
    const folded = std.ascii.lowerString(lower[0..@min(name.len, max_name)], name[0..@min(name.len, max_name)]);
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, folded));
    return std.fmt.allocPrint(alloc, "~{x:0>8}.tmp", .{h});
}

/// Adds `bytes` at the end of `path`, making it and the folders above it if
/// needed, and answers its size afterwards. One positional write at the end.
pub fn append(io: Io, alloc: Alloc, path: []const u8, bytes: []const u8) !u64 {
    const p = try forWrite(io, alloc, path);
    if (std.fs.path.dirname(p)) |d| try makeDir(io, alloc, d);
    var file = try Io.Dir.cwd().createFile(io, p, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
    return st.size + bytes.len;
}

/// Makes the folder `path` and every folder above it that is missing.
pub fn makeDir(io: Io, alloc: Alloc, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, try forMakeDir(io, alloc, path));
}

/// Removes the file at `path`. Not there is not an error: the caller wanted
/// it gone, and it is.
pub fn remove(io: Io, alloc: Alloc, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {
            const p = (try retry(io, alloc, path)) orelse return;
            try Io.Dir.cwd().deleteFile(io, p);
        },
        else => return e,
    };
}

/// Removes `path` and everything under it. **Refuses a path whose last name
/// is not one FAT holds** (an empty or blank id joined onto a root would
/// otherwise name the root itself).
pub fn removeTree(io: Io, alloc: Alloc, path: []const u8) !void {
    if (!fatName(std.fs.path.basename(path))) return error.BadName;
    const p = (try retry(io, alloc, path)) orelse path;
    try Io.Dir.cwd().deleteTree(io, p);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A temp directory and an arena. The thread pool each test needs is made in
/// the test itself: outside a `test` block the host's Io is out of bounds
/// (tools/lint_portable.py), since this module is in the route table's reach.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.tmp = testing.tmpDir(.{});
        // tmpDir() makes .zig-cache/tmp/<sub_path> through Io.Dir.cwd(), which
        // is what every call here resolves against.
        self.base = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
    fn p(self: *Fixture, rel: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.base, rel }) catch unreachable;
    }
};

test "names FAT holds, and names it refuses" {
    for ([_][]const u8{ "a", "plan.md", "Plan-2.reactions.jsonl", "0f3a.png", "_session_secret", "a b", "x" ** 96 }) |ok|
        try testing.expect(fatName(ok));
    for ([_][]const u8{ "", ".", "..", "what?", "a:b", "a/b", "a\\b", "trailing.", "trailing ", "caf\xc3\xa9", "tab\t", "x" ** 97 }) |bad|
        try testing.expect(!fatName(bad));
}

test "write, read, append, readAt, stat, list, remove" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try write(io, a, f.p("data/chat/1_2/sessions/topic.md"), "hello", .{});
    try testing.expectEqualStrings("hello", try read(io, a, f.p("data/chat/1_2/sessions/topic.md"), .unlimited));
    try testing.expectEqual(@as(u64, 11), try append(io, a, f.p("data/chat/1_2/sessions/topic.md"), " world"));
    var buf: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try readAt(io, a, f.p("data/chat/1_2/sessions/topic.md"), 6, &buf));
    try testing.expectEqualStrings("world", &buf);
    try testing.expectEqual(@as(u64, 11), (try stat(io, a, f.p("data/chat/1_2/sessions/topic.md"))).size);
    try testing.expectEqual(Kind.directory, (try stat(io, a, f.p("data/chat/1_2"))).kind);

    // append makes a file that is not there, and its folders.
    try testing.expectEqual(@as(u64, 3), try append(io, a, f.p("data/new/x.log"), "abc"));

    const entries = try list(io, a, f.p("data/chat/1_2/sessions"));
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("topic.md", entries[0].name);
    try testing.expectEqual(Kind.file, entries[0].kind);
    try testing.expectEqual(@as(usize, 0), (try list(io, a, f.p("data/nowhere"))).len);

    try testing.expectEqual(@as(usize, 0), (try readOrEmpty(io, a, f.p("data/nothing.md"), .unlimited)).len);
    try testing.expectError(error.FileNotFound, read(io, a, f.p("data/nothing.md"), .unlimited));

    try remove(io, a, f.p("data/chat/1_2/sessions/topic.md"));
    try remove(io, a, f.p("data/chat/1_2/sessions/topic.md")); // gone already: fine
    try testing.expect(!try has(io, a, f.p("data/chat/1_2/sessions/topic.md")));
    try removeTree(io, a, f.p("data/chat"));
    try testing.expect(!try has(io, a, f.p("data/chat")));
    try testing.expect(try has(io, a, f.p("data/new/x.log")));
}

test "a name FAT refuses is refused here too, before anything is made" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectError(error.BadName, write(io, a, f.p("data/what?.md"), "x", .{}));
    try testing.expectError(error.BadName, append(io, a, f.p("data/" ++ "x" ** 97), "x"));
    try testing.expectError(error.BadName, makeDir(io, a, f.p("data/trailing./inner")));
    try testing.expectError(error.BadName, removeTree(io, a, f.p("data/users/   ")));
    try testing.expect(!try has(io, a, f.p("data/trailing.")));
}

test "replace makes the file hold exactly the data, keeps its name, and leaves no sibling" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // New: made, folders and all.
    try replace(io, a, f.p("data/players/next-id.txt"), "4\n", .{});
    try testing.expectEqualStrings("4\n", try read(io, a, f.p("data/players/next-id.txt"), .unlimited));
    // Shorter than before: nothing of the old tail is left.
    try replace(io, a, f.p("data/players/next-id.txt"), "5", .{});
    try testing.expectEqualStrings("5", try read(io, a, f.p("data/players/next-id.txt"), .unlimited));
    // In another case: the same file, in its first case.
    try write(io, a, f.p("data/chat/topic.count"), "1 10\n", .{});
    try replace(io, a, f.p("data/chat/TOPIC.count"), "2 20\n", .{});
    const entries = try list(io, a, f.p("data/chat"));
    try testing.expectEqual(@as(usize, 1), entries.len); // and no sibling left over
    try testing.expectEqualStrings("topic.count", entries[0].name);
    try testing.expectEqualStrings("2 20\n", try read(io, a, f.p("data/chat/topic.count"), .unlimited));
    // A sibling a stop left behind is written over.
    const left = try std.fs.path.join(a, &.{ f.p("data/chat"), try siblingName(a, "topic.count") });
    try write(io, a, left, "stale", .{});
    try replace(io, a, f.p("data/chat/topic.count"), "3 30\n", .{});
    try testing.expectEqual(@as(usize, 1), (try list(io, a, f.p("data/chat"))).len);
    try testing.expectEqualStrings("3 30\n", try read(io, a, f.p("data/chat/topic.count"), .unlimited));
    // A name FAT cannot hold is refused before anything is written.
    try testing.expectError(error.BadName, replace(io, a, f.p("data/what?"), "x", .{}));
    // One sibling name per file, in any case, and short enough for any name.
    try testing.expectEqualStrings(try siblingName(a, "Topic.count"), try siblingName(a, "topic.COUNT"));
    try testing.expect(!std.mem.eql(u8, try siblingName(a, "a.count"), try siblingName(a, "b.count")));
    try testing.expectEqual(@as(usize, 13), (try siblingName(a, "x" ** 96)).len);
    try testing.expect(fatName(try siblingName(a, "x" ** 96)));
}

test "a path the bare-metal host could not hold is refused, measured as it would spell it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = saveBases();
    defer saved.restore();
    // Roots spelled long, as a Linux host's are: the limits do not count them.
    const data = f.p("home/someone/a-long-host-path/prod/data");
    setBases(data, f.p("home/someone/a-long-host-path/prod/auth"));

    // data/ + 245 bytes is 250: held. Spelled here it is far longer.
    const near = try std.fs.path.join(a, &.{ data, "x" ** 90, "y" ** 90, "z" ** 63 });
    try write(io, a, near, "ok", .{});
    // data/ + 252 bytes is 257: refused, before anything is made.
    const over = try std.fs.path.join(a, &.{ data, "x" ** 90, "y" ** 90, "q" ** 70 });
    try testing.expectError(error.PathTooLong, write(io, a, over, "no", .{}));
    try testing.expectError(error.PathTooLong, append(io, a, over, "no"));
    try testing.expectError(error.PathTooLong, replace(io, a, over, "no", .{}));
    try testing.expectError(error.PathTooLong, makeDir(io, a, over));

    // 16 names from the volume's root (data and 15 more): held; 17: refused.
    var parts: [17][]const u8 = undefined;
    parts[0] = data;
    for (parts[1..]) |*p| p.* = "d";
    try write(io, a, try std.fs.path.join(a, parts[0..16]), "ok", .{});
    try testing.expectError(error.PathTooDeep, write(io, a, try std.fs.path.join(a, parts[0..17]), "no", .{}));
    try testing.expectError(error.PathTooDeep, makeDir(io, a, try std.fs.path.join(a, parts[0..17])));
    try testing.expect(!try has(io, a, try std.fs.path.join(a, parts[0..17])));

    // Under auth/ too; and not a path that only begins like a root.
    try testing.expectError(error.PathTooLong, write(io, a, try std.fs.path.join(a, &.{ f.p("home/someone/a-long-host-path/prod/auth"), "x" ** 96, "y" ** 96, "z" ** 96 }), "no", .{}));
    try write(io, a, try std.fs.path.join(a, &.{ f.p("home/someone/a-long-host-path/prod/data2"), "x" ** 96, "y" ** 96, "z" ** 96 }), "free", .{});
}

test "a missing file is empty, and something unreadable in its place is not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqualStrings("", try readOrEmpty(io, a, f.p("not-here"), .unlimited));
    // **SOMETHING THAT EXISTS BUT WILL NOT READ MUST NOT COME BACK AS ""**,
    // because the caller is about to write over what it thinks is empty.
    try makeDir(io, a, f.p("a-directory"));
    try testing.expect(readOrEmpty(io, a, f.p("a-directory"), .unlimited) catch null == null);
}

test "nothing there is null, and something there that will not read is an error (metal-vmm QUEUE 105)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try write(io, a, f.p("a-file"), "x", .{});
    try makeDir(io, a, f.p("a-directory"));
    for ([_][]const u8{ "not-here", "a-file/under-a-file" }) |absent| {
        try testing.expect((try readOrNull(io, a, f.p(absent), .unlimited)) == null);
        try testing.expect((try statOrNull(io, a, f.p(absent))) == null);
    }
    try testing.expectEqualStrings("x", (try readOrNull(io, a, f.p("a-file"), .unlimited)).?);
    try testing.expectEqual(@as(u64, 1), (try statOrNull(io, a, f.p("a-file"))).?.size);
    try testing.expect(std.meta.isError(readOrNull(io, a, f.p("a-directory"), .unlimited)));
}

test "case does not tell two names apart, and the first case is kept" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try write(io, a, f.p("data/chat/channels/Dev/sessions/plan.md"), "one", .{});
    // Read in another case: the same file, as FAT finds it.
    try testing.expectEqualStrings("one", try read(io, a, f.p("data/chat/channels/dev/sessions/PLAN.md"), .unlimited));
    try testing.expect(try has(io, a, f.p("data/chat/CHANNELS/dev/Sessions/Plan.md")));
    // Write in another case: the same file again, kept in its first case.
    try write(io, a, f.p("data/chat/channels/DEV/sessions/Plan.md"), "two", .{});
    _ = try append(io, a, f.p("data/chat/channels/dev/sessions/PLAN.md"), "!");
    const entries = try list(io, a, f.p("data/chat/channels/dev/sessions"));
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("plan.md", entries[0].name);
    try testing.expectEqualStrings("two!", try read(io, a, f.p("data/chat/channels/Dev/sessions/plan.md"), .unlimited));
    const channels = try list(io, a, f.p("data/chat/channels"));
    try testing.expectEqual(@as(usize, 1), channels.len);
    try testing.expectEqualStrings("Dev", channels[0].name);
    // A folder made in another case is the one already there.
    try makeDir(io, a, f.p("data/chat/channels/dEv/sessions/plan.uploads"));
    try testing.expectEqual(@as(usize, 1), (try list(io, a, f.p("data/chat/channels"))).len);
    // Removal in another case removes it.
    try remove(io, a, f.p("data/chat/channels/dev/sessions/PLAN.md"));
    try testing.expect(!try has(io, a, f.p("data/chat/channels/Dev/sessions/plan.md")));
    try removeTree(io, a, f.p("data/chat/channels/DEV"));
    try testing.expectEqual(@as(usize, 0), (try list(io, a, f.p("data/chat/channels"))).len);
}

test "a path with an empty part is refused under a root, as metal refuses it (metal-vmm QUEUE 156(i))" {
    const saved = saveBases();
    defer saved.restore();
    data_base = "/srv/gopher/data/";
    try withinLimits("/srv/gopher/data/chat/1_2/sessions/x.md");
    for ([_][]const u8{ "/srv/gopher/data/chat//1_2/x.md", "/srv/gopher/data/chat/", "/srv/gopher/data//x" }) |bad|
        try std.testing.expectError(error.BadName, withinLimits(bad));
    // Outside the roots nothing is measured.
    try withinLimits("/tmp//x");
}

test "fs: createNew makes a file once, whole; one there, in any case, is PathAlreadyExists, and no temporary is left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "deep" });
    const path = try std.fs.path.join(a, &.{ dir, "Secret" });
    try createNew(io, a, path, "first", .{});
    try std.testing.expectError(error.PathAlreadyExists, createNew(io, a, path, "second", .{}));
    try std.testing.expectError(error.PathAlreadyExists, createNew(io, a, try std.fs.path.join(a, &.{ dir, "SECRET" }), "third", .{}));
    try std.testing.expectEqualStrings("first", try read(io, a, path, .limited(64)));
    const left = try list(io, a, dir);
    try std.testing.expectEqual(@as(usize, 1), left.len);
}
