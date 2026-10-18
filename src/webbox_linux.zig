//! webbox_linux: a webbox site served as a Linux process. The `webbox`
//! library's host-only half, its own module, so the portable half (the
//! `webbox` module, all a site's code imports) never carries it: a site's
//! Linux `main` imports this, and nothing else does (angry-gopher's tools/lint_portable.py).
//! Its files reach the portable half as the `webbox` module, never by path.

/// `Server(site).run`: the whole Linux host, from the allocator to the
/// accept loop.
pub const linux_host = @import("linux_host.zig");
/// The address a Linux host listens on.
pub const bind = @import("bind.zig");
/// Where a Linux host's data is: a config file a variable names.
pub const linux_config = @import("linux_config.zig");
/// No response before the writes ahead of it are on the disk.
pub const linux_durable = @import("linux_durable.zig");
/// The application's one fetch at a time, on a thread of its own.
pub const linux_fetch = @import("linux_fetch.zig");
/// A connection's writes under their deadlines, for the host (linux_writes.zig).
pub const linux_writes = @import("linux_writes.zig");
/// The streams held at once, for the host (linux_streams.zig).
pub const linux_streams = @import("linux_streams.zig");
/// A request's reads before the turn, for the host (linux_reads.zig).
pub const linux_reads = @import("linux_reads.zig");

test {
    _ = linux_host;
    _ = bind;
    _ = linux_config;
    _ = linux_durable;
    _ = linux_fetch;
    _ = linux_writes;
    _ = linux_streams;
    _ = linux_reads;
}
