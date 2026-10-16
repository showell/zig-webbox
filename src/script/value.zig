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

/// **THE RUN'S ARENA, ITS BUDGET ITS SIZE** (metal-vmm QUEUE 209, the box's
/// review 2): every value of a run is bumped out of chunks this arena takes
/// from the backing allocator, and **it never takes more than its limit in
/// all**, so the budget bounds the memory a run holds on metal, whatever
/// the script does. (std's ArenaAllocator grows each block by about half
/// again what it holds, so a count kept outside it can't bound it: an 8
/// MiB budget held 14-16 MiB.) Past the limit an allocation fails, and
/// every `OutOfMemory` of the run, a store call's among them, is read as
/// this budget.
///
/// Small allocations are bumped out of chunks of at least `chunk_least`,
/// twice the last when the limit has that left; only the last of them can
/// grow, shrink or be taken back, in place, and any other free is kept (as
/// an arena's is). **An allocation of `big` or more has a chunk of its
/// own,** given back to the backing allocator when it is freed: a list
/// grown to megabytes holds its live buffer, not every one it outgrew.
pub const Budgeted = struct {
    backing: std.mem.Allocator,
    limit: usize,
    /// Every chunk's bytes, its header among them: what the arena holds.
    held: usize = 0,
    /// The bytes handed out (a measure, not a bound).
    used: usize = 0,
    hit: bool = false,
    /// The newest chunk, first; each its header then its bytes.
    chunk: ?*Chunk = null,
    /// How far into the newest chunk's bytes the next allocation starts.
    end: usize = 0,
    /// The big allocations' chunks, one each.
    bigs: ?*Chunk = null,

    pub const chunk_least = 16 * 1024;
    pub const big = 64 * 1024;

    const Chunk = struct {
        next: ?*Chunk,
        /// The whole chunk, its header first, as the backing allocator gave it.
        total: usize,

        fn bytes(c: *Chunk) []u8 {
            const base: [*]u8 = @ptrCast(c);
            return base[@sizeOf(Chunk)..c.total];
        }
    };
    const chunk_align: std.mem.Alignment = .of(Chunk);

    pub fn allocator(self: *Budgeted) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Every chunk back to the backing allocator.
    pub fn deinit(self: *Budgeted) void {
        for ([_]?*Chunk{ self.chunk, self.bigs }) |first| {
            var c = first;
            while (c) |x| {
                c = x.next;
                const base: [*]u8 = @ptrCast(x);
                // **IN THE TESTS, FREED IS OVERWRITTEN**, so a value still
                // read after its arena went (a root a `yield` missed)
                // reads as garbage, not as what it was.
                const whole = base[0..x.total];
                if (@import("builtin").is_test) @memset(whole, 0xaa);
                self.backing.rawFree(whole, chunk_align, @returnAddress());
            }
        }
        self.* = .{ .backing = self.backing, .limit = self.limit };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    const Alignment = std.mem.Alignment;

    /// Where in the newest chunk an allocation of `len` aligned to `a`
    /// would start, if it fits.
    fn fits(self: *const Budgeted, len: usize, a: Alignment) ?usize {
        const c = self.chunk orelse return null;
        const bytes = c.bytes();
        const addr = @intFromPtr(bytes.ptr) + self.end;
        const start = a.forward(addr) - @intFromPtr(bytes.ptr);
        if (start + len > bytes.len) return null;
        return start;
    }

    /// A chunk of `total` bytes from the backing allocator, if the limit
    /// has that left.
    fn take(self: *Budgeted, total: usize) ?*Chunk {
        if (total > self.limit -| self.held) {
            self.hit = true;
            return null;
        }
        const raw = self.backing.rawAlloc(total, chunk_align, @returnAddress()) orelse {
            self.hit = true;
            return null;
        };
        const c: *Chunk = @ptrCast(@alignCast(raw));
        c.* = .{ .next = null, .total = total };
        self.held += total;
        return c;
    }

    /// The bytes of a chunk of its own, aligned to `a`.
    fn bigBytes(c: *Chunk, a: Alignment) [*]u8 {
        return @ptrFromInt(a.forward(@intFromPtr(c.bytes().ptr)));
    }

    fn alloc(ctx: *anyopaque, len: usize, a: Alignment, _: usize) ?[*]u8 {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (len >= big) {
            const c = self.take(@sizeOf(Chunk) + len + a.toByteUnits()) orelse return null;
            c.next = self.bigs;
            self.bigs = c;
            self.used += len;
            return bigBytes(c, a);
        }
        const start = self.fits(len, a) orelse blk: {
            // A new chunk: room for this and its alignment, at least the
            // least, twice the last when the limit has that left.
            const need = @sizeOf(Chunk) + len + a.toByteUnits();
            const last = if (self.chunk) |c| c.total else 0;
            const want = @max(need, @min(self.limit -| self.held, @max(chunk_least, 2 * last)));
            const c = self.take(want) orelse return null;
            c.next = self.chunk;
            self.chunk = c;
            self.end = 0;
            break :blk self.fits(len, a).?;
        };
        self.end = start + len;
        self.used += len;
        return self.chunk.?.bytes().ptr + start;
    }

    /// Whether `m` is the newest chunk's last allocation.
    fn isLast(self: *const Budgeted, m: []u8) bool {
        const c = self.chunk orelse return false;
        return m.ptr + m.len == c.bytes().ptr + self.end;
    }

    fn resize(ctx: *anyopaque, m: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        // A big one never changes its length in place: its chunk is freed
        // by the length it was made with. A small one never grows into a
        // big one's place but by moving.
        if (m.len >= big or new_len >= big) return false;
        if (!self.isLast(m)) return new_len <= m.len;
        const start = self.end - m.len;
        if (start + new_len > self.chunk.?.bytes().len) return false;
        self.end = start + new_len;
        if (new_len > m.len) self.used += new_len - m.len;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, m, a, new_len, ra)) m.ptr else null;
    }

    fn free(ctx: *anyopaque, m: []u8, a: Alignment, _: usize) void {
        const self: *Budgeted = @ptrCast(@alignCast(ctx));
        if (m.len >= big) {
            // Its own chunk, given back.
            var at = &self.bigs;
            while (at.*) |c| : (at = &c.next) {
                if (bigBytes(c, a) != m.ptr) continue;
                at.* = c.next;
                self.held -= c.total;
                const base: [*]u8 = @ptrCast(c);
                self.backing.rawFree(base[0..c.total], chunk_align, @returnAddress());
                return;
            }
            return;
        }
        if (self.isLast(m)) self.end -= m.len;
    }
};

test "the arena's budget refuses past its limit, and says it was hit" {
    var b: Budgeted = .{ .backing = std.testing.allocator, .limit = 64 * 1024 };
    defer b.deinit();
    const a = b.allocator();
    _ = try a.alloc(u8, 40 * 1024);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 40 * 1024));
    try std.testing.expect(b.hit);
    try std.testing.expect(b.held <= b.limit);
}

/// The backing allocator's bytes outstanding, and the most there ever were.
pub const Peak = struct {
    child: std.mem.Allocator,
    now: usize = 0,
    most: usize = 0,

    pub fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = pAlloc, .resize = pResize, .remap = pRemap, .free = pFree } };
    }
    fn pAlloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.now += len;
        self.most = @max(self.most, self.now);
        return p;
    }
    fn pResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn pRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn pFree(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.now -= m.len;
    }
};

test "the arena never takes more than its limit from the backing allocator, whatever grows in it" {
    // The review's shapes: many small tables, one list pushed to, and the
    // two interleaved, which std's arena held at 1.7x and 2.0x its count.
    const limit = 1024 * 1024;
    for (0..3) |shape| {
        var peak: Peak = .{ .child = std.testing.allocator };
        var b: Budgeted = .{ .backing = peak.allocator(), .limit = limit };
        defer b.deinit();
        const a = b.allocator();
        var l: std.ArrayList(u64) = .empty;
        var other: std.ArrayList(u64) = .empty;
        var i: u64 = 0;
        while (true) : (i += 1) {
            const ok = switch (shape) {
                0 => if (a.create(Table)) |_| true else |_| false,
                1 => if (l.append(a, i)) |_| true else |_| false,
                else => if (l.append(a, i)) |_| (if (other.append(a, i)) |_| true else |_| false) else |_| false,
            };
            if (!ok) break;
        }
        try std.testing.expect(b.hit);
        try std.testing.expect(peak.most <= limit);
        try std.testing.expect(b.held <= limit);
    }
}
