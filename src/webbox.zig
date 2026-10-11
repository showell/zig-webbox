//! **THE `webbox` LIBRARY** (a web server in a box): what an application
//! built on it imports, as one module.
//!
//! Its files import std and one another, and nothing of any application's,
//! so an application gets these files and only these.

/// An application made servable: `Site(App)` is everything a host calls
/// (`start`, then `route` per request) around the application's own setup
/// and route table; `Host` is what a host supplies.
pub const site = @import("site.zig");
/// Request and response helpers: bodies, forms, cookies, embedded files.
pub const http = @import("http.zig");
/// The one policy for incoming data at the server's edges.
pub const edge = @import("edge.zig");
/// Values signed so only the site could have made them (cookies).
pub const signed = @import("signed.zig");
/// HTML escaping.
pub const html = @import("html.zig");
/// Keyed pub/sub for SSE streams, and where a host takes a stream over.
pub const bus = @import("bus.zig");
/// The counting allocator under everything long-lived: live bytes, for leaks.
pub const mem_meter = @import("mem_meter.zig");
/// What the host says about itself, for a page that shows the host's facts.
pub const host_facts = @import("host_facts.zig");
/// Every file an application keeps, through one seam, under FAT's rules on
/// every host.
pub const store = @import("store.zig");
/// A number in a file, bumped under a lock: ids handed out exactly once.
pub const counter = @import("counter.zig");
/// Which address a request comes from: the connection's, or behind a trusted
/// reverse proxy, the one it names.
pub const client_address = @import("client_address.zig");
/// The data volume's free space, as the host reports it.
pub const free_space = @import("free_space.zig");

// ── host-only: a site served as a Linux process ─────────────────────────────
// Analysed only by a program that uses them (an application's Linux `main`);
// the portable part above never imports them (tools/lint_portable.py).

/// `Server(site).run`: the whole Linux host, from the allocator to the
/// accept loop.
pub const linux_host = @import("linux_host.zig");
/// The address a Linux host listens on.
pub const bind = @import("bind.zig");
/// Where a Linux host's data is: a config file a variable names.
pub const linux_config = @import("linux_config.zig");

test {
    _ = site;
    _ = http;
    _ = edge;
    _ = signed;
    _ = html;
    _ = bus;
    _ = mem_meter;
    _ = host_facts;
    _ = store;
    _ = counter;
    _ = client_address;
    _ = free_space;
    _ = linux_host;
    _ = bind;
    _ = linux_config;
}
