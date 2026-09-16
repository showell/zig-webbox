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

// Process-lifetime singleton, mirroring edge.zig's module-level counters.
//
// **THE CHILD HAS NO DEFAULT, AND AN ALLOCATION BEFORE init() PANICS.** It used
// to default to std.heap.page_allocator, "so base() is valid even before init()
// runs". But presence and reading_list capture base() at module level, so the
// route table reaches this singleton — and a default that NAMES a host
// allocator drags that host into everything the route table touches:
// page_allocator is mmap, and mmap is std.posix. On a machine with no operating
// system that is not a slower path, it is a compile error, and it was the one
// thing standing between gopher-metal and angry-gopher's real dispatch.
//
// Capturing base() before init() is still fine — it is a pointer and a vtable,
// and allocates nothing. Only an actual allocation needs a child, and the HOST
// is the only thing that knows which one: server.zig names page_allocator, a
// kernel names its fixed heap. Forgetting is a host bug, so it is a loud panic
// naming the fix rather than an OutOfMemory that reads like memory pressure.
var meter: Meter = .{ .child = unset };

/// init points the meter at `child` and returns the metered allocator. The host
/// calls it once, before serving, and threads the result everywhere as the base
/// allocator.
pub fn init(child: Alloc) Alloc {
    _ = replace(child);
    return base();
}

/// replace swaps the child and answers the previous one, so a test can point the
/// meter somewhere and put it back: `const prev = replace(x); defer _ = replace(prev);`.
pub fn replace(child: Alloc) Alloc {
    const prev = meter.child;
    meter.child = child;
    return prev;
}

/// unset is the child before a host names one. Every entry point panics with the
/// same message, because reaching any of them means the host skipped init().
const unset: Alloc = .{ .ptr = undefined, .vtable = &unset_vtable };

const unset_vtable: Alloc.VTable = .{
    .alloc = unsetAlloc,
    .resize = unsetResize,
    .remap = unsetRemap,
    .free = unsetFree,
};

const unset_msg = "mem_meter: allocation before init() — the host must name the base allocator (server.zig: page_allocator; a kernel: its fixed heap)";

fn unsetAlloc(_: *anyopaque, _: usize, _: Alignment, _: usize) ?[*]u8 {
    @panic(unset_msg);
}
fn unsetResize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    @panic(unset_msg);
}
fn unsetRemap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    @panic(unset_msg);
}
fn unsetFree(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {
    @panic(unset_msg);
}

/// isInitialized answers whether a host has named the child yet. For hosts that
/// want to assert their own startup order, and for the tests below.
pub fn isInitialized() bool {
    return meter.child.vtable != &unset_vtable;
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

// Every test puts the child back the way it found it: the singleton is shared by
// every test in this binary — and, because zig runs an imported file's tests in
// the importer's binary, by reading_list's and router's too. "Uninitialized" is
// itself one of the things under test, so a test anywhere that init()s without
// restoring will trip the first test below. That is the alarm working.
//
// For the same reason no test here asserts an ABSOLUTE counter: another file's
// test may already have allocated through the meter. Only deltas are ours.

test "the meter starts with NO child — nothing here names a host allocator" {
    // This is the property that lets the route table compile freestanding. It
    // must hold before any test has run init(), so it runs first and changes
    // nothing. (Zig cannot assert that a call PANICS, so the panic itself is
    // checked by reading unsetAlloc, not by a test.)
    try testing.expect(!isInitialized());
    try testing.expect(meter.child.vtable == &unset_vtable);
}

test "base() can be captured before init() without allocating" {
    // presence and reading_list do exactly this at module level.
    const before = snapshot();
    const early = base();
    try testing.expect(!isInitialized());
    try testing.expectEqual(before, snapshot());
    // ...and it is the same allocator init() will later hand back.
    const prev = replace(testing.allocator);
    defer _ = replace(prev);
    try testing.expect(early.ptr == base().ptr);
    try testing.expect(early.vtable == base().vtable);
}

test "replace answers the previous child, and init reports initialized" {
    const prev = replace(testing.allocator);
    defer _ = replace(prev);
    try testing.expect(prev.vtable == &unset_vtable);
    try testing.expect(isInitialized());

    const again = replace(testing.allocator);
    try testing.expect(again.vtable == testing.allocator.vtable);

    _ = replace(prev);
    try testing.expect(!isInitialized());
    _ = replace(testing.allocator); // the deferred restore expects to find one
}

test "meter tracks live bytes across alloc/free and nets to zero" {
    // Point the meter at the test allocator (which itself catches leaks), then
    // drive it through the metered allocator and watch the counters move.
    const prev = replace(testing.allocator);
    defer _ = replace(prev);
    const metered = base();
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
}

test "over a FixedBufferAllocator — the bare-metal host's shape" {
    // gopher-metal has no pages to map. Its base allocator is a bump allocator
    // over a static block, and this is the meter wrapped around exactly that.
    var block: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&block);
    const prev = replace(fba.allocator());
    defer _ = replace(prev);
    const metered = base();
    const start = snapshot();

    const a = try metered.alloc(u8, 100);
    // The bytes are the fixed block's, not somewhere a host mapped.
    const lo = @intFromPtr(&block);
    try testing.expect(@intFromPtr(a.ptr) >= lo and @intFromPtr(a.ptr) + a.len <= lo + block.len);
    try testing.expectEqual(start.live_bytes + 100, snapshot().live_bytes);

    const b = try metered.alloc(u8, 50);
    try testing.expectEqual(start.live_bytes + 150, snapshot().live_bytes);
    try testing.expectEqual(start.live_allocs + 2, snapshot().live_allocs);

    // A bump allocator only reclaims its LAST allocation; the meter must count
    // the free either way, because the caller did give the bytes back.
    metered.free(b);
    metered.free(a);
    try testing.expectEqual(start.live_bytes, snapshot().live_bytes);
    try testing.expectEqual(start.live_allocs, snapshot().live_allocs);
    try testing.expectEqual(start.total_allocs + 2, snapshot().total_allocs);
}

test "a refused allocation moves no counter" {
    // When the heap is full the child answers null, and the meter must not have
    // counted bytes nobody got. On the fixed heap this is the common failure.
    var block: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&block);
    const prev = replace(fba.allocator());
    defer _ = replace(prev);
    const metered = base();
    const start = snapshot();

    try testing.expectError(error.OutOfMemory, metered.alloc(u8, 1000));
    try testing.expectEqual(start, snapshot());
}

test "resize tracks the delta when it succeeds, and nothing when it fails" {
    var block: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&block);
    const prev = replace(fba.allocator());
    defer _ = replace(prev);
    const metered = base();

    // `mem` is typed as a slice on purpose: `ptr[0..48]` with comptime-known
    // bounds is a pointer-to-array, and Allocator.resize asserts a slice.
    var mem: []u8 = try metered.alloc(u8, 32);
    const start = snapshot();

    // The last allocation on a bump allocator can grow in place.
    try testing.expect(metered.resize(mem, 48));
    mem = mem.ptr[0..48];
    try testing.expectEqual(start.live_bytes + 16, snapshot().live_bytes);
    try testing.expectEqual(start.live_allocs, snapshot().live_allocs); // same allocation

    // And shrink.
    try testing.expect(metered.resize(mem, 8));
    mem = mem.ptr[0..8];
    try testing.expectEqual(start.live_bytes - 24, snapshot().live_bytes);

    // Past the end of the block it cannot grow — and the meter must not move.
    const before = snapshot();
    try testing.expect(!metered.resize(mem, 10_000));
    try testing.expectEqual(before, snapshot());

    metered.free(mem);
}

test "snapshotJSON renders the counters" {
    var block: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&block);
    const s = try snapshotJSON(fba.allocator());
    try testing.expect(std.mem.startsWith(u8, s, "{\"live_bytes\":"));
    try testing.expect(std.mem.indexOf(u8, s, "\"live_allocs\":") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"total_allocs\":") != null);
}
