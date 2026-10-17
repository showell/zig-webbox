//! **THE STREAMS HELD AT ONCE** (metal-vmm QUEUE 184), for linux_host.zig:
//! a kept stream takes a slot, the oldest is ended when none is free, and a
//! slot is given back when its stream ends (unless a newer one has it).
//! linux_host.zig uses it as `linux_streams`.

const std = @import("std");
const Io = @import("host_io").Io;
const net = std.Io.net;

/// The most streams held at once (184), as the kernel's default, and a test's own.
pub const streams_most: usize = 64;
pub var streams_most_for_test: ?usize = null;
var held_streams: [streams_most]?struct { stream: net.Stream, since: u64 } = @splat(null);
var held_lock: Io.Mutex = .init;
var held_count: u64 = 0;

pub const Held = struct { slot: usize, ticket: u64 };

/// A slot for a stream about to be served; the oldest ended to make room.
pub fn holdStream(io: Io, stream: net.Stream) Held {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    const most = @min(streams_most_for_test orelse streams_most, streams_most);
    held_count += 1;
    var free: ?usize = null;
    var oldest: usize = 0;
    for (held_streams[0..most], 0..) |h, i| {
        if (h) |x| {
            if (held_streams[oldest] == null or x.since < held_streams[oldest].?.since) oldest = i;
        } else if (free == null) free = i;
    }
    const i = free orelse at: {
        // Its socket shut: its writes fail, and its task lets the slot go.
        held_streams[oldest].?.stream.shutdown(io, .both) catch {};
        break :at oldest;
    };
    held_streams[i] = .{ .stream = stream, .since = held_count };
    return .{ .slot = i, .ticket = held_count };
}

/// A stream's slot given back, unless a newer stream has taken it.
pub fn letGoStream(io: Io, h: Held) void {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    if (held_streams[h.slot]) |x| if (x.since == h.ticket) {
        held_streams[h.slot] = null;
    };
}

/// How many streams are held now, for tests.
pub fn heldStreams(io: Io) usize {
    held_lock.lockUncancelable(io);
    defer held_lock.unlock(io);
    var n: usize = 0;
    for (held_streams) |h| if (h != null) {
        n += 1;
    };
    return n;
}
