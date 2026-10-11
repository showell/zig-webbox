//! **THE `webbox` LIBRARY** (a web server in a box): what an application
//! built on this server imports, as one module (build.zig's `webbox`;
//! dog-park is the first such application).
//!
//! Its files import std and one another, and nothing else of angry-gopher's:
//! ops/check_zig holds every file named here to that, so an application gets
//! these files and only these.

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
/// What the host says about itself (/admin/host's host half).
pub const host_facts = @import("host_facts.zig");

test {
    _ = http;
    _ = edge;
    _ = signed;
    _ = html;
    _ = bus;
    _ = mem_meter;
    _ = host_facts;
}
