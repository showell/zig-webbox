//! free_space: the data volume's free space, as the host reports it. Part of
//! the `webbox` library.
//!
//! The host knows it (Linux asks statfs; the bare-metal host reads its FAT's
//! free count) and hands over a reader as it starts. What an application does
//! with it, such as refusing some writes below a floor of its own, is the
//! application's policy.

pub const Space = struct { free: u64, total: u64 };

/// How the host reads the free space, which it sets as it starts. Null: the
/// host cannot say (a test whose data is on a development disk, whose
/// fullness is no fact about the server).
pub var reader: ?*const fn () ?Space = null;

/// How a host says the free space is read, as it starts: its reader, or none
/// (a test whose data is on a development disk, whose fullness is no fact
/// about the server).
pub const FreeSpace = union(enum) {
    reader: *const fn () ?Space,
    none_for_a_test,
};

/// The free space now, or null when the host cannot say.
pub fn read() ?Space {
    const r = reader orelse return null;
    return r();
}

/// The setting as it stood, to put back (`defer saved.restore()`): for a test
/// that sets it.
pub const Saved = struct {
    reader: ?*const fn () ?Space,
    pub fn restore(self: Saved) void {
        reader = self.reader;
    }
};

pub fn save() Saved {
    return .{ .reader = reader };
}
