//! **A SCRIPT'S VALUES**: nil, booleans, 64-bit integers, byte strings, and
//! tables, each a list or a map once it has an entry. All in the run's arena.

const std = @import("std");

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    string: []const u8,
    table: *Table,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nil",
            .boolean => "a boolean",
            .int => "an integer",
            .string => "a string",
            .table => |t| switch (t.kind) {
                .empty => "an empty table",
                .list => "a list",
                .map => "a map",
            },
        };
    }
};

pub const Table = struct {
    /// `{}` takes its kind from its first entry.
    kind: enum { empty, list, map } = .empty,
    list: std.ArrayList(Value) = .empty,
    /// Keys in the order they were first set.
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,
};

/// **THE ARENA'S BUDGET**: bytes handed out by the arena, counted; past the
/// limit an allocation fails, and every `OutOfMemory` of the run, a store
/// call's among them, is read as this budget.
///
/// **NEVER LESS THAN THE ARENA HOLDS** (metal-vmm QUEUE 208(a)): an arena
/// reclaims a freed buffer only when it was its last, so a list's old
/// buffer, freed as the list grows, stays held. A free is never credited,
/// a shrink neither, and a remap that moves counts its new buffer whole:
/// `used` is an upper bound on the arena's size, so the budget bounds the
/// memory a run takes on metal, not half of it.
pub const Budgeted = struct {
    child: std.mem.Allocator,
    used: usize = 0,
    limit: usize,
    hit: bool = false,

    pub fn allocator(self: *Budgeted) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    const Alignment = std.mem.Alignment;

    fn room(self: *Budgeted, more: usize) bool {
        if (more > self.limit -| self.used) {
            self.hit = true;
            return false;
        }
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (!self.room(len)) return null;
        const p = self.child.rawAlloc(len, a, ra) orelse {
            self.hit = true;
            return null;
        };
        self.used += len;
        return p;
    }

    /// In place: only growth is counted.
    fn resize(ctx: *anyopaque, m: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        const more = new_len -| m.len;
        if (!self.room(more)) return false;
        if (!self.child.rawResize(m, a, new_len, ra)) return false;
        self.used += more;
        return true;
    }

    /// Moved, the new buffer whole (the old one may stay held); in place,
    /// its growth.
    fn remap(ctx: *anyopaque, m: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (!self.room(new_len)) return null;
        const p = self.child.rawRemap(m, a, new_len, ra) orelse return null;
        self.used += if (p == m.ptr) new_len -| m.len else new_len;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

test "the arena's budget refuses past its limit, and says it was hit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b: Budgeted = .{ .child = arena.allocator(), .limit = 100 };
    const a = b.allocator();
    _ = try a.alloc(u8, 60);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 41));
    try std.testing.expect(b.hit);
    _ = try a.alloc(u8, 40);
    try std.testing.expectEqual(@as(usize, 100), b.used);
}

test "the arena's budget never credits a free: a buffer freed but not reclaimed still counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b: Budgeted = .{ .child = arena.allocator(), .limit = 1 << 20 };
    const a = b.allocator();
    // A list grown by doubling: every old buffer is freed to the arena,
    // which keeps all but the last; the count must cover them all.
    var l: std.ArrayList(u64) = .empty;
    var other: std.ArrayList(u64) = .empty;
    for (0..2000) |i| {
        try l.append(a, i);
        // Another list growing between, so no buffer is the arena's last.
        try other.append(a, i);
    }
    try std.testing.expect(b.used >= arena.queryCapacity() / 2);
    const before = b.used;
    a.free(try a.alloc(u8, 4096));
    try std.testing.expectEqual(before + 4096, b.used);
}
