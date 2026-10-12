//! **THE `webbox` LIBRARY** (a web server in a box): what an application
//! built on it imports, as one module.
//!
//! Its files import std and one another, and nothing of any application's,
//! so an application gets these files and only these.
//!
//! **PORTABLE**: nothing here assumes an operating system. Serving a site as
//! a Linux process is the other module, `webbox_linux` (webbox_linux.zig),
//! which only a Linux `main` imports.

/// An application made servable: `Site(App)` is everything a host calls
/// (`start`, then `route` per request) around the application's own setup
/// and route table; `Host` is what a host supplies.
pub const site = @import("site.zig");
/// When a request's body is read (before the turn or in it) and how long it
/// may take: the one rule every host reads it by.
pub const body = @import("body.zig");
/// Request and response helpers: bodies, forms, cookies, embedded files.
pub const http = @import("http.zig");
/// The one policy for incoming data at the server's edges.
pub const edge = @import("edge.zig");
/// Values signed so only the site could have made them (cookies).
pub const signed = @import("signed.zig");
/// The site's signing secret, kept as files: load, the previous one, rotate.
pub const site_secret = @import("site_secret.zig");
/// A cookie whose value is signed: read back under the current or previous
/// secret, issued, and renewed when it is used.
pub const signed_cookie = @import("signed_cookie.zig");
/// HTML escaping.
pub const html = @import("html.zig");
/// Keyed pub/sub for SSE streams, and where a host takes a stream over. A
/// request's `Bus` also carries the connection's address (`peer`, for
/// client_address.resolve).
pub const bus = @import("bus.zig");
/// Server-Sent Events: open a stream, push frames, forward a key's blobs,
/// and where a reconnecting stream resumes.
pub const sse = @import("sse.zig");
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

test {
    _ = site;
    _ = body;
    _ = http;
    _ = edge;
    _ = signed;
    _ = site_secret;
    _ = signed_cookie;
    _ = html;
    _ = bus;
    _ = sse;
    _ = mem_meter;
    _ = host_facts;
    _ = store;
    _ = counter;
    _ = client_address;
    _ = free_space;
}
