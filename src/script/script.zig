//! **SHALE, A SMALL SCRIPT LANGUAGE FOR A SITE'S OWN DATA** (metal-vmm QUEUE
//! 199): Lua's look, a smaller language's semantics, every effect through
//! webbox's `store`, every run inside its budgets. The language, its
//! builtins and its budgets are zig-webbox's README, "Scripts".
//!
//! Portable as every webbox file is: the host's `Io` from `host_io`, an
//! allocator from the caller, and nothing that names the host
//! (`portable_test.zig` holds that).

pub const diag = @import("diag.zig");
pub const ast = @import("ast.zig");
pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");

test {
    _ = lex;
    _ = parse;
}
