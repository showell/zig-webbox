//! mem_meter: a counting allocator that wraps a child allocator and tracks the
//! outstanding (live) bytes + allocation count for the whole process.
//!
//! Why this is the right place to measure: every request runs on a per-request
//! arena that server.zig frees wholesale when the request ends (`arena.deinit()`),
//! so a handler that forgets to `free()` *cannot* leak. The ONLY thing that can
//! leak is state allocated on the process-lifetime base allocator — the bus, the
//! presence map, the reading-list cache. Wrapping that base allocator therefore
//! meters exactly the leakable surface: bytes that survive a request.
//!
//! Read it at /debug/mem (and folded into /version, which the watchdog already
//! polls). A real leak climbs ~linearly under a hammered endpoint; a legitimate
//! cache fills once and plateaus — so the stress harness watches the SLOPE, not
//! the level. This is the cheap always-on smoke detector; std.heap.DebugAllocator
//! is the swap-in localizer (stack traces) for once the meter fingers an endpoint.

const std = @import("std");
const Alloc = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Meter = struct {
    child: Alloc,
    live_bytes: std.atomic.Value(usize) = .init(0),
    live_allocs: std.atomic.Value(usize) = .init(0),
    total_allocs: std.atomic.Value(u64) = .init(0),
};

// Process-lifetime singleton, mirroring edge.zig's module-level counters. The
// child defaults to page_allocator so base() is valid even before init() runs;
// init() just lets main name the child explicitly (and repoint it in a test).
var meter: Meter = .{ .child = std.heap.page_allocator };

/// init points the meter at `child` and returns the metered allocator. main calls
/// it once, before serving, and threads the result everywhere as the base alloc.
pub fn init(child: Alloc) Alloc {
    meter.child = child;
    return base();
}

/// base is the metered allocator: a thin vtable over `meter`. Stable for the
/// process (ptr + vtable never move), so modules that hold a process-lifetime
/// allocator — presence, reading_list — can capture it directly and have their
/// persistent allocations show up in the meter.
pub fn base() Alloc {
    return .{ .ptr = &meter, .vtable = &vtable };
}

const vtable: Alloc.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Meter = @ptrCast(@alignCast(ctx));
    const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
    _ = self.live_bytes.fetchAdd(len, .monotonic);
    _ = self.live_allocs.fetchAdd(1, .monotonic);
    _ = self.total_allocs.fetchAdd(1, .monotonic);
    return p;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Meter = @ptrCast(@alignCast(ctx));
    if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
    track(self, memory.len, new_len);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Meter = @ptrCast(@alignCast(ctx));
    const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    track(self, memory.len, new_len);
    return p;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Meter = @ptrCast(@alignCast(ctx));
    self.child.rawFree(memory, alignment, ret_addr);
    _ = self.live_bytes.fetchSub(memory.len, .monotonic);
    _ = self.live_allocs.fetchSub(1, .monotonic);
}

/// track adjusts live_bytes for an in-place grow/shrink (resize/remap). The
/// allocation count is unchanged — it's the same allocation at a new length.
fn track(self: *Meter, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        _ = self.live_bytes.fetchAdd(new_len - old_len, .monotonic);
    } else {
        _ = self.live_bytes.fetchSub(old_len - new_len, .monotonic);
    }
}

pub const Snapshot = struct { live_bytes: usize, live_allocs: usize, total_allocs: u64 };

/// snapshot reads the live counters. Lock-free; the three loads aren't a single
/// atomic transaction, so the numbers can be a hair inconsistent with each other
/// under concurrent load — fine for a slope signal, not a transactional readout.
pub fn snapshot() Snapshot {
    return .{
        .live_bytes = meter.live_bytes.load(.monotonic),
        .live_allocs = meter.live_allocs.load(.monotonic),
        .total_allocs = meter.total_allocs.load(.monotonic),
    };
}

/// snapshotJSON renders the live counters as a JSON object (owned by `a`) — the
/// body /debug/mem returns and the value /version embeds. Mirrors edge.countsJSON.
pub fn snapshotJSON(a: Alloc) ![]const u8 {
    const s = snapshot();
    return std.fmt.allocPrint(a,
        \\{{"live_bytes":{d},"live_allocs":{d},"total_allocs":{d}}}
    , .{ s.live_bytes, s.live_allocs, s.total_allocs });
}

const testing = std.testing;

test "meter tracks live bytes across alloc/free and nets to zero" {
    // Point the meter at the test allocator (which itself catches leaks), then
    // drive it through the metered allocator and watch the counters move.
    const metered = init(testing.allocator);
    const start = snapshot();

    const a = try metered.alloc(u8, 100);
    const after_alloc = snapshot();
    try testing.expectEqual(start.live_bytes + 100, after_alloc.live_bytes);
    try testing.expectEqual(start.live_allocs + 1, after_alloc.live_allocs);

    metered.free(a);
    const after_free = snapshot();
    try testing.expectEqual(start.live_bytes, after_free.live_bytes);
    try testing.expectEqual(start.live_allocs, after_free.live_allocs);
    // total_allocs only ever climbs — it counted the one alloc.
    try testing.expectEqual(start.total_allocs + 1, after_free.total_allocs);

    // Leave the singleton pointed back at page_allocator so other tests / the
    // real server don't inherit the test allocator.
    _ = init(std.heap.page_allocator);
}
