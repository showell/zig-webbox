//! **A DRY RUN THAT SEES ITS OWN CHANGES** (metal-vmm QUEUE 234, 2): in a
//! dry run each change goes into an overlay, and every read sees it, so
//! a replace and then an edit previews the edit against the replaced text.
//! Through the gate: all three engines, the cut one yielding.

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;
const Fixture = @import("builtins_test.zig").Fixture;

var out_buf: [64 * 1024]u8 = undefined;

fn dry(f: *Fixture, src: []const u8, budgets: script.Budgets) script.Result {
    return script.runWith(f.threaded.io(), testing.allocator, f.root, src, budgets, 0, &out_buf, .{ .mode = .dry_run });
}

fn expectDry(f: *Fixture, src: []const u8, want: []const u8) !void {
    var r = dry(f, src, .{});
    defer r.deinit();
    if (r.stop) |s| {
        std.debug.print("{s}\n  stopped {d}:{d} {s}: {s}\n", .{ src, s.line, s.column, @tagName(s.class), s.message });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(want, r.output);
}

fn expectDryStop(f: *Fixture, src: []const u8, budgets: script.Budgets, class: script.diag.Class, says: []const u8) !void {
    var r = dry(f, src, budgets);
    defer r.deinit();
    const s = r.stop orelse {
        std.debug.print("{s}: finished\n", .{src});
        return error.TestUnexpectedResult;
    };
    errdefer std.debug.print("{s}: {s}: {s}\n", .{ src, @tagName(s.class), s.message });
    try testing.expectEqual(class, s.class);
    try testing.expect(std.mem.indexOf(u8, s.message, says) != null);
}

test "overlay: a replace, then an edit, previews the edit against the replaced text; the disk keeps its own" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDry(&f, "replace(\"top.txt\", \"one\\n\") edit(\"top.txt\", \"one\", \"two\") print(read(\"top.txt\"))", "--- a/top.txt\n+++ b/top.txt\n@@ -1,1 +1,1 @@\n-one\n+two\ntwo\n\n");
    const kept = try f.file("data/top.txt");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("top", kept);
}

test "overlay: a new file reads back, with its size; a removed one is gone; an append reads as the old and its suffix" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDry(&f, "replace(\"new.txt\", \"made\") print(exists(\"new.txt\"), read(\"new.txt\"), stat(\"new.txt\").size, stat(\"new.txt\").kind, read_or(\"new.txt\", \"-\"))", "true\tmade\t4\tfile\tmade\n");
    try expectDry(&f, "remove(\"top.txt\") print(exists(\"top.txt\"), read_or(\"top.txt\", \"gone\"), is_dir(\"top.txt\"))", "false\tgone\tfalse\n");
    try expectDryStop(&f, "remove(\"top.txt\") read(\"top.txt\")", .{}, .store, "top.txt");
    try expectDryStop(&f, "remove(\"top.txt\") remove(\"top.txt\")", .{}, .store, "top.txt");
    try expectDry(&f, "append(\"top.txt\", \" more\") append(\"top.txt\", \"!\") print(read(\"top.txt\"), stat(\"top.txt\").size, count_in(\"top.txt\", \"o\"), find_in(\"top.txt\", \"more\"))", "top more!\t9\t2\t4\n");
    try expectDry(&f, "append(\"fresh.txt\", \"a\\nb\\n\") print(#read_lines(\"fresh.txt\").lines, count_lines(\"fresh.txt\"), line_at(\"fresh.txt\", 2), #grep(\"fresh.txt\", \"b\"))", "2\t2\tb\t1\n");
    // A replace after a remove is there again.
    try expectDry(&f, "remove(\"top.txt\") replace(\"top.txt\", \"back\") print(read(\"top.txt\"))", "back\n");
}

test "overlay: folders: mkdir and remove_tree are seen; listing a folder the dry run changed stops, saying so" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDry(&f, "mkdir(\"made\") print(is_dir(\"made\"), exists(\"made\"), stat(\"made\").kind)", "true\ttrue\tdirectory\n");
    try expectDry(&f, "remove_tree(\"chat\") print(exists(\"chat\"), exists(\"chat/a.md\"), read_or(\"chat/a.md\", \"-\"))", "false\tfalse\t-\n");
    try expectDry(&f, "remove_tree(\"chat\") replace(\"chat/c.md\", \"c\") print(exists(\"chat/c.md\"), exists(\"chat/a.md\"))", "true\tfalse\n");
    try expectDryStop(&f, "replace(\"chat/c.md\", \"c\") ls(\"chat\")", .{}, .argument, "a dry run cannot list chat after changing it: run --write on a copy");
    try expectDryStop(&f, "replace(\"chat/c.md\", \"c\") walk(\"\")", .{}, .argument, "a dry run cannot list  after changing it");
    // A folder it did not change lists as ever.
    try expectDry(&f, "replace(\"top.txt\", \"x\") print(join(ls(\"chat\"), \",\"))", "a.md,b.md\n");
}

test "overlay: the change budgets stop a dry run as they stop --write" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDryStop(&f, "replace(\"a.txt\", rep(\"x\", 100))", .{ .change_bytes = 10 }, .budget, "");
}

test "overlay: it survives a yield, in the gate's cut engine" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectDry(&f, "replace(\"top.txt\", \"kept across\") append(\"top.txt\", \" a yield\") yield() print(read(\"top.txt\"))", "kept across a yield\n");
}

test "overlay: a builtins_* file reads the store only through the view (builtins_store.zig's `view`)" {
    const files = .{
        .{ "builtins_read.zig", @embedFile("builtins_read.zig") },
        .{ "builtins_walk.zig", @embedFile("builtins_walk.zig") },
        .{ "builtins_change.zig", @embedFile("builtins_change.zig") },
        .{ "builtins_store.zig", @embedFile("builtins_store.zig") },
    };
    const reads = [_][]const u8{ "store.statOrNull(", "store.stat(", "store.has(", "store.readAt(", "store.list(" };
    var found: usize = 0;
    inline for (files) |f| {
        var it = std.mem.splitScalar(u8, f[1], '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            n += 1;
            // The view's own lines say so.
            if (std.mem.indexOf(u8, line, "// the view") != null) continue;
            for (reads) |r| if (std.mem.indexOf(u8, line, r) != null) {
                std.debug.print("{s}:{d} reads the store directly ({s}): go through the view\n", .{ f[0], n, r });
                found += 1;
            };
        }
    }
    try testing.expectEqual(@as(usize, 0), found);
}
