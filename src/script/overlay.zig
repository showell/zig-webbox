//! **THE DRY RUN'S OVERLAY** (metal-vmm QUEUE 234, 2): in `Mode.dry_run`
//! every change goes here as well as into the effects, and every read
//! sees it (builtins_store.zig's view), so a replace and then an edit
//! previews the edit against the replaced text. Keyed by the resolved path
//! (`p.full`, after the path hook: mounts alias). An entry is a file (its
//! whole content, or the real file's with a suffix appended), a folder made,
//! or a path removed (a removal covers everything under it made before it).
//! Everything it holds is in the run's arena, counted there, and copied at
//! a `yield` as the effects are. **Metal compiles none of it**: its
//! `host_io` does not say `shale_dry_run`.

const std = @import("std");
const store = @import("../store.zig");

pub const on = @hasDecl(@import("host_io"), "shale_dry_run") and @import("host_io").shale_dry_run;

pub const Entry = struct {
    /// When it was made: a later removal of a folder above it hides it.
    seq: u64,
    kind: enum { file, dir, removed },
    /// A file's whole content, or null for the real file's (if any).
    base: ?[]const u8 = null,
    /// Bytes appended after `base` (or the real file's content).
    suffix: []const u8 = "",
};

/// The overlay itself; on metal, nothing at all.
pub const Overlay = if (on) struct {
    map: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    seq: u64 = 0,
} else struct {};

pub const Change = enum { replace, append, mkdir, remove, remove_tree };

/// **A CHANGE, HELD**: what `full` is after it.
pub fn record(o: *Overlay, a: std.mem.Allocator, c: Change, full: []const u8, data: []const u8) error{OutOfMemory}!void {
    o.seq += 1;
    const prior = find(o, full);
    const e: Entry = switch (c) {
        .replace => .{ .seq = o.seq, .kind = .file, .base = data },
        .append => if (prior) |p| switch (p.kind) {
            .file => .{ .seq = o.seq, .kind = .file, .base = p.base, .suffix = try std.mem.concat(a, u8, &.{ p.suffix, data }) },
            // Appending to what is gone, or to a folder (which the store
            // refuses): the file it would make.
            else => .{ .seq = o.seq, .kind = .file, .base = data },
        } else .{ .seq = o.seq, .kind = .file, .suffix = data },
        .mkdir => .{ .seq = o.seq, .kind = .dir },
        .remove, .remove_tree => .{ .seq = o.seq, .kind = .removed },
    };
    const gop = try o.map.getOrPut(a, full);
    if (!gop.found_existing) gop.key_ptr.* = try a.dupe(u8, full);
    gop.value_ptr.* = e;
}

/// **WHAT THE OVERLAY SAYS OF `full`**: its own entry, unless a later
/// removal of a folder above it hides it; null when it says nothing.
pub fn find(o: *const Overlay, full: []const u8) ?Entry {
    var got: ?Entry = o.map.get(full);
    var it = o.map.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (kv.value_ptr.kind != .removed) continue;
        if (!(full.len > k.len and std.mem.startsWith(u8, full, k) and full[k.len] == '/')) continue;
        if (got == null or kv.value_ptr.seq > got.?.seq) got = kv.value_ptr.*;
    }
    return got;
}

/// Whether the overlay holds anything at or under the folder `full`, or
/// covers it by a removal or a file above: a listing of it would not be
/// what the run would see.
pub fn touches(o: *const Overlay, full: []const u8) bool {
    const dir = std.mem.trimEnd(u8, full, "/");
    var it = o.map.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (std.mem.eql(u8, k, dir)) return true;
        if (dir.len == 0 or (k.len > dir.len and std.mem.startsWith(u8, k, dir) and k[dir.len] == '/')) return true;
        if (dir.len > k.len and std.mem.startsWith(u8, dir, k) and dir[k.len] == '/') return true;
    }
    return false;
}

/// A file entry's whole content: its base, or the real file's, then its
/// suffix. Reading the real file is a read the script asked for.
pub fn content(e: Entry, io: std.Io, a: std.mem.Allocator, full: []const u8) ![]const u8 {
    const base = e.base orelse real: {
        const st = (try store.statOrNull(io, a, full)) orelse break :real ""; // the view
        const buf = try a.alloc(u8, @intCast(st.size));
        const n = try store.readAt(io, a, full, 0, buf); // the view
        break :real buf[0..n];
    };
    if (e.suffix.len == 0) return base;
    return std.mem.concat(a, u8, &.{ base, e.suffix });
}

/// **THE OVERLAY, COPIED** into `a` at a `yield`: its keys and its bytes.
pub fn copy(o: *const Overlay, a: std.mem.Allocator) error{OutOfMemory}!Overlay {
    var out: Overlay = .{ .seq = o.seq };
    try out.map.ensureTotalCapacity(a, o.map.count());
    var it = o.map.iterator();
    while (it.next()) |kv| {
        var e = kv.value_ptr.*;
        if (e.base) |b| e.base = try a.dupe(u8, b);
        e.suffix = try a.dupe(u8, e.suffix);
        out.map.putAssumeCapacity(try a.dupe(u8, kv.key_ptr.*), e);
    }
    return out;
}

/// The bytes it holds, for a yield's count.
pub fn bytes(o: *const Overlay) usize {
    var n: usize = 0;
    var it = o.map.iterator();
    while (it.next()) |kv| n += kv.key_ptr.len + kv.value_ptr.suffix.len + if (kv.value_ptr.base) |b| b.len else 0;
    return n;
}
