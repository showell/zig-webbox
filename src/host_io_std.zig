//! host_io for a program with an operating system: the standard library's
//! `std.Io`. The build chooses this file as the `host_io` module on Linux;
//! gopher-metal's build chooses its own, with the machine's `Io`. Every file
//! takes its `Io` from here (`const Io = @import("host_io").Io;`), so which
//! host it runs on is one file, swapped by the build, and never named in the
//! code.
pub const Io = @import("std").Io;
