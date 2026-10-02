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
//!     1 to 96 bytes (fat16.zig's max_name), printable ASCII, none of
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
//! **AN ERROR IS NOT AN EMPTY FILE.** `readOrEmpty` says the difference between
//! a file that is not there ("nothing yet") and one that will not read.

const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

/// fat16.zig's max_name: the longest name gopher-metal reads and writes.
pub const max_name = 96;

pub const Error = error{BadName};

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
    return resolve(io, alloc, path);
}

/// `path` resolved for a call that creates folders: every component past the
/// existing part must be a name FAT holds.
fn forMakeDir(io: Io, alloc: Alloc, path: []const u8) ![]const u8 {
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
/// no such thing in any case.
fn retry(io: Io, alloc: Alloc, path: []const u8) !?[]const u8 {
    const p = try resolve(io, alloc, path);
    if (std.mem.eql(u8, p, path) or !exists(io, p)) return null;
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
pub fn has(io: Io, alloc: Alloc, path: []const u8) bool {
    _ = stat(io, alloc, path) catch return false;
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

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    base: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.tmp = testing.tmpDir(.{});
        self.threaded = std.Io.Threaded.init(self.arena.allocator(), .{});
        // tmpDir() makes .zig-cache/tmp/<sub_path> through Io.Dir.cwd(), which
        // is what every call here resolves against.
        self.base = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path });
    }
    fn deinit(self: *Fixture) void {
        self.threaded.deinit();
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
    const io = f.threaded.io();

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
    try testing.expect(!has(io, a, f.p("data/chat/1_2/sessions/topic.md")));
    try removeTree(io, a, f.p("data/chat"));
    try testing.expect(!has(io, a, f.p("data/chat")));
    try testing.expect(has(io, a, f.p("data/new/x.log")));
}

test "a name FAT refuses is refused here too, before anything is made" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const io = f.threaded.io();

    try testing.expectError(error.BadName, write(io, a, f.p("data/what?.md"), "x", .{}));
    try testing.expectError(error.BadName, append(io, a, f.p("data/" ++ "x" ** 97), "x"));
    try testing.expectError(error.BadName, makeDir(io, a, f.p("data/trailing./inner")));
    try testing.expectError(error.BadName, removeTree(io, a, f.p("data/users/   ")));
    try testing.expect(!has(io, a, f.p("data/trailing.")));
}

test "case does not tell two names apart, and the first case is kept" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const io = f.threaded.io();

    try write(io, a, f.p("data/chat/channels/Dev/sessions/plan.md"), "one", .{});
    // Read in another case: the same file, as FAT finds it.
    try testing.expectEqualStrings("one", try read(io, a, f.p("data/chat/channels/dev/sessions/PLAN.md"), .unlimited));
    try testing.expect(has(io, a, f.p("data/chat/CHANNELS/dev/Sessions/Plan.md")));
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
    try testing.expect(!has(io, a, f.p("data/chat/channels/Dev/sessions/plan.md")));
    try removeTree(io, a, f.p("data/chat/channels/DEV"));
    try testing.expectEqual(@as(usize, 0), (try list(io, a, f.p("data/chat/channels"))).len);
}
