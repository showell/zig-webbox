//! store: every file the application keeps, through one seam.
//!
//! The application's data lives under its roots (data/, auth/) as named files
//! in folders. This module is the only way to reach them, so the rules of the
//! disk the data may end up on are kept in one place:
//!
//! **THE RULES ARE FAT'S, ON EVERY HOST.** On gopher-metal the data is a FAT
//! volume. On Linux it is not, and a Linux that allowed what FAT refuses would
//! hide the difference until the data moved. So the Store keeps FAT's rules
//! here too:
//!
//!   - **A name FAT can hold**, or the call is refused with `error.BadName`:
//!     1 to 96 bytes (disk_fat_dirent.zig's max_name), printable ASCII, none of
//!     `" * / : < > ? \ |`, not `.` or `..`, not ending in a dot or a space.
//!   - **Case does not tell two names apart; it is kept for display.** A name
//!     that differs from an existing one only in case IS that one (Steve,
//!     2026-10-02, option 1): reading `Plan.md` finds `plan.md`, and writing
//!     `Plan.md` writes `plan.md`, where FAT would. A new name keeps the case
//!     it was given.
//!
//! The rules apply to the names a call would CREATE and to the names it looks
//! up. The roots themselves (configured paths, such as prod's
//! /home/steve/AngryGopher/prod) are the host's and are not checked: a path
//! that exists is taken as it is, and only a name that is not found is looked
//! for in another case.
//!
//! **A FOLDER HOLDS AT MOST 65,536 ENTRIES ON FAT** (the spec's 2 MiB; a long
//! name takes 2 to 4 of them). gopher-metal refuses to grow a folder past it:
//! the write that needed the room fails as a full disk would
//! (`error.NoSpaceLeft`). Linux has no such limit, and this Store does not
//! count entries on every write, so at that bound the two hosts would
//! differ. What the application's folders can reach (gopher-metal QUEUE item
//! 68; prod's counts from 2026-10-02):
//!
//!   - `data/players`: one folder per player, two entries each, so about
//!     32,000 players. **Nothing bounds it** but game_limits' 5 new players
//!     an address an hour. Prod: 19.
//!   - `data/lynrummy`: one folder per player who has played. Prod: 5.
//!   - a player's `sessions` folders: at most 500 (game_limits). Prod's
//!     largest: 65.
//!   - a conversation's `sessions`: a topic is about five files of 2-4
//!     entries each, so a few thousand topics. A topic's uploads: about
//!     16,000. Prod's largest folder of all: 70 entries.
//!
//! So prod is a few hundred times inside every one of them. The players
//! folder is the one that grows without a bound of its own; when it nears
//! the limit, the fix is a fan-out (`data/players/<first digit>/p...`),
//! not a bigger folder.
//!
//! **AN ERROR IS NOT AN EMPTY FILE.** `readOrEmpty` says the difference between
//! a file that is not there ("nothing yet") and one that will not read.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// disk_fat_dirent.zig's max_name: the longest name gopher-metal reads and writes.
pub const max_name = 96;

/// io.zig's max_path: the longest path gopher-metal holds a file by.
pub const max_path = 256;

/// disk_fat.zig's max_tree_depth: how deep gopher-metal removes a tree and
/// checks a volume at boot. A path is held to it from the volume's root.
pub const max_depth = 16;

pub const Error = error{ BadName, PathTooLong, PathTooDeep };

// ── the paths gopher-metal would hold ───────────────────────────────────────
//
// **FAT'S PATH LIMITS, ON EVERY HOST, MEASURED AS GOPHER-METAL SPELLS THE
// PATH.** There the data is `data/...` and `auth/...` on the volume; on Linux
// the same files are under configured roots, often absolute and long. So a
// path under a root is measured as if the root were spelled `data` or `auth`:
// what gopher-metal would be asked to hold. A path under neither root (a
// test's temporary folder, the site's own files) is not measured.

/// The two roots roots.point sets, as this host spells them; null until then.
pub var data_base: ?[]const u8 = null;
pub var auth_base: ?[]const u8 = null;

/// Called by roots.point, with the same two directories.
pub fn setBases(data_dir: []const u8, auth_dir: []const u8) void {
    data_base = data_dir;
    auth_base = auth_dir;
}

/// `path`'s length and depth as gopher-metal would spell it, or null when it
/// is under neither root.
fn metalShape(path: []const u8) ?struct { len: usize, depth: usize } {
    for ([_]struct { ?[]const u8, []const u8 }{ .{ data_base, "data" }, .{ auth_base, "auth" } }) |pair| {
        const base = std.mem.trimEnd(u8, pair[0] orelse continue, "/");
        if (!std.mem.startsWith(u8, path, base)) continue;
        const rest = path[base.len..];
        if (rest.len != 0 and rest[0] != '/') continue; // "data2" is not under "data"
        var depth: usize = 1;
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |_| depth += 1;
        return .{ .len = pair[1].len + rest.len, .depth = depth };
    }
    return null;
}

/// Refuses a path gopher-metal could not hold: longer than max_path or
/// deeper than max_depth, measured as it would spell it.
fn withinLimits(path: []const u8) Error!void {
    const shape = metalShape(path) orelse return;
    if (shape.len > max_path) return error.PathTooLong;
    if (shape.depth > max_depth) return error.PathTooDeep;
}

/// Whether FAT, as gopher-metal holds it, can store `name`.
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
/// which folds case, answers it on gopher-metal.
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
/// gopher-metal's io name the type differently, and both have these tags.
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
    /// FAT has none: on gopher-metal the volume is the boundary.
    private: bool = false,
};

/// Makes `path` hold exactly `data`, making the folders above it.
pub fn write(io: Io, alloc: Alloc, path: []const u8, data: []const u8, opts: WriteOptions) !void {
    const p = try forWrite(io, alloc, path);
    if (std.fs.path.dirname(p)) |d| try makeDir(io, alloc, d);
    // The flags are spelled in place, not named: std.Io and gopher-metal's io
    // call their type differently.
    if (opts.private) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data, .flags = .{ .permissions = @enumFromInt(0o600) } });
    } else {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
    }
}

/// **MAKES `path` HOLD EXACTLY `data`, SO THAT NO STOP LOSES IT.** `write`
/// empties the file and then fills it (on gopher-metal it removes the entry
/// and writes a new one), so a machine that stops between the two has lost
/// the record. This writes `data` to a sibling with a temporary name first,
/// then renames it over `path`:
///   - stopped before the rename: `path` is the old record, whole, and the
///     sibling is left over (the next replace writes over it);
///   - the rename itself: on Linux one atomic step; on gopher-metal,
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

test "a path gopher-metal could not hold is refused, measured as it would spell it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const saved = .{ data_base, auth_base };
    defer data_base, auth_base = saved;
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
