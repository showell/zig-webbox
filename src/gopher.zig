//! **THE `gopher` LIBRARY**: what an application built on gopher imports, as
//! one module (build.zig's `gopher`; dog-park is the first such application).
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
