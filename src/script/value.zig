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

    fn resize(ctx: *anyopaque, m: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and !self.room(new_len - m.len)) return false;
        if (!self.child.rawResize(m, a, new_len, ra)) return false;
        self.used = self.used - m.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and !self.room(new_len - m.len)) return null;
        const p = self.child.rawRemap(m, a, new_len, ra) orelse return null;
        self.used = self.used - m.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.used -= m.len;
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
