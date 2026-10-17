//! **READ-ONLY MOUNTS, AND A STORE THAT FOLLOWS NO LINK, TESTED** (metal-vmm
//! QUEUE 235, 4): every change through an `ro` mount refused before
//! anything is written, its reads as ever; the mounts file's ` ro`; and a
//! symbolic link anywhere in a path (to a file, to a folder, in the middle,
//! in a mount) refused for reads, changes, `exists`/`stat` and listings.

const std = @import("std");
const testing = std.testing;
const T = @import("shale_test_host.zig").T;
const host_linux = @import("shale_host_linux.zig");

fn init(t: *T) !void {
    try t.init();
    t.preludes = &.{host_linux.linux_prelude};
}

test "ro mounts: every change builtin through one is refused before anything is written; a read works" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    try t.tmp.dir.createDirPath(t.threaded.io(), "frozen/sub");
    try t.put("frozen/a.zig", "const x = 1;\n\nconst y = x;\n");
    try t.put("mine.zig", "const z = 1;\n");
    var why: []const u8 = "";
    t.host.mounts = try host_linux.parseMounts(a, try std.fmt.allocPrint(a, "ro = {s}/frozen ro\n", .{t.root}), "/home/x", &why);
    try t.expectOutput("print(read(\"ro:a.zig\"), exists(\"ro:sub\"), #ls(\"ro:\"))", "const x = 1;\n\nconst y = x;\n\ttrue\t2\n");
    // Every change builtin, through the mount: a new one cannot skip it.
    for ([_][]const u8{
        "replace(\"ro:a.zig\", \"x\")",
        "append(\"ro:a.zig\", \"x\")",
        "create(\"ro:new.zig\", \"x\")",
        "edit(\"ro:a.zig\", \"const x\", \"const w\")",
        "edits_all({{\"ro:a.zig\", {{old = \"const x\", new = \"const w\"}}}})",
        "remove(\"ro:a.zig\")",
        "mkdir(\"ro:d\")",
        "remove_tree(\"ro:sub\")",
        "zig_rename(\"ro:a.zig\", \"x\", \"w\")",
        "zig_move(\"ro:a.zig\", \"mine2.zig\", {\"y\"})",
        "zig_move(\"mine.zig\", \"ro:a.zig\", {\"z\"})",
        // A root path into the mount's folder is the mount's.
        "replace(\"frozen/a.zig\", \"x\")",
        // A set with one file that may not change writes none.
        "edits_all({{\"mine.zig\", {{old = \"const z\", new = \"const q\"}}}, {\"ro:a.zig\", {{old = \"const x\", new = \"const w\"}}}})",
    }) |src| {
        try t.expectStop(src, .atomic, .refused, "mount `ro` is read-only");
        try testing.expectEqualStrings("const x = 1;\n\nconst y = x;\n", try t.file("frozen/a.zig"));
        try testing.expectEqualStrings("const z = 1;\n", try t.file("mine.zig"));
    }
    // `zig_move` out of the mount wrote nothing anywhere.
    try testing.expectError(error.FileNotFound, t.file("mine2.zig"));
}

test "ro mounts: the mounts file's ` ro`; any other trailing word, or a path with a space, refused by line" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const a = t.arena.allocator();
    var why: []const u8 = "";
    const ms = try host_linux.parseMounts(a, "a = /x ro\nb = /y\n", "/home/x", &why);
    try testing.expectEqual(host_linux.Mount.Access.read_only, ms[0].access);
    try testing.expectEqual(host_linux.Mount.Access.read_write, ms[1].access);
    try testing.expectEqualStrings("/x", ms[0].dir);
    for ([_]struct { []const u8, []const u8 }{
        .{ "a = /x rw\n", "line 1: `rw` after `a`'s path: only `ro` may follow it" },
        .{ "a = /x y z\n", "line 1: `a`'s path has a space" },
    }) |c| {
        try testing.expectError(error.Malformed, host_linux.parseMounts(a, c[0], "/home/x", &why));
        errdefer std.debug.print("{s}: {s}\n", .{ c[0], why });
        try testing.expect(std.mem.indexOf(u8, why, c[1]) != null);
    }
}

test "the store follows no link: to a file, to a folder, in the middle of a path, in a mount, out of the root: refused for reads, changes, exists, stat and listings" {
    var t: T = undefined;
    try init(&t);
    defer t.deinit();
    const io = t.threaded.io();
    const a = t.arena.allocator();
    try t.tmp.dir.createDirPath(io, "dir");
    try t.tmp.dir.createDirPath(io, "frozen");
    try t.put("real.txt", "real");
    try t.put("dir/inner.txt", "inner");
    try t.tmp.dir.symLink(io, "real.txt", "link_file", .{});
    try t.tmp.dir.symLink(io, "dir", "link_dir", .{});
    try t.tmp.dir.symLink(io, "../real.txt", "dir/up", .{});
    try t.tmp.dir.symLink(io, "../real.txt", "frozen/up", .{});
    try t.tmp.dir.symLink(io, "/etc/hostname", "outside", .{});
    var why: []const u8 = "";
    t.host.mounts = try host_linux.parseMounts(a, try std.fmt.allocPrint(a, "m = {s}/dir\nro = {s}/frozen ro\n", .{ t.root, t.root }), "/home/x", &why);
    for ([_]struct { []const u8, []const u8 }{
        .{ "read(\"link_file\")", "link_file is a symbolic link" },
        .{ "read(\"link_dir/inner.txt\")", "link_dir is a symbolic link" },
        .{ "exists(\"link_file\")", "is a symbolic link" },
        .{ "stat(\"link_dir\")", "is a symbolic link" },
        .{ "ls(\"link_dir\")", "is a symbolic link" },
        .{ "replace(\"link_file\", \"x\")", "is a symbolic link" },
        .{ "read(\"m:up\")", "is a symbolic link" },
        .{ "read(\"ro:up\")", "is a symbolic link" },
        .{ "read(\"outside\")", "outside is a symbolic link" },
    }) |c| try t.expectStop(c[0], .atomic, .refused, c[1]);
    try testing.expectEqualStrings("real", try t.file("real.txt"));
    // What is no link reads as ever, a listing names the links it holds.
    try t.expectOutput("print(read(\"real.txt\"), read(\"m:inner.txt\"), #ls(\"\"))", "real\tinner\t6\n");
}
