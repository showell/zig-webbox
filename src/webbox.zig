//! **THE `webbox` LIBRARY** (a web server in a box): what an application
//! built on this server imports, as one module (build.zig's `webbox`;
//! dog-park is the first such application).
//!
//! Its files import std and one another, and nothing else of angry-gopher's:
//! ops/check_zig holds every file named here to that, so an application gets
//! these files and only these.

pub const http = @import("http.zig");
pub const edge = @import("edge.zig");
pub const signed = @import("signed.zig");

test {
    _ = http;
    _ = edge;
    _ = signed;
}
