//! host_io for a program with an operating system: the standard library's
//! `std.Io`. The build chooses this file as the `host_io` module on Linux;
//! zig-metal-unikernel's build chooses its own, with the machine's `Io`. Every file
//! takes its `Io` from here (`const Io = @import("host_io").Io;`), so which
//! host it runs on is one file, swapped by the build, and never named in the
//! code.
pub const Io = @import("std").Io;
/// **SHALE'S PRELUDES AFTER THE CORE'S** (metal-vmm QUEUE 233): a host
/// with an operating system takes them (the Linux host's, a repo's, a
/// user's); metal's `host_io` says nothing, and its parse compiles none.
pub const shale_preludes = true;
/// **A DIFF AS ONE LINE** (metal-vmm QUEUE 234): the Linux CLI prints a
/// change's diff as a summary unless `--verbose`; metal prints every diff
/// in full and compiles no summary.
pub const shale_diff_summary = true;
