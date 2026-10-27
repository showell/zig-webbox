//! html: tiny HTML helpers for every module that renders a page. Part of the
//! `webbox` library. No state, no I/O — just escaping, so a page can escape
//! without importing anything else.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// htmlEscape maps & ' < > " → &amp; &#39; &lt; &gt; &#34;. Returns `s`
/// unchanged (no allocation) when it has nothing to escape.
pub fn htmlEscape(alloc: Alloc, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&'<>\"") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '\'' => try out.appendSlice(alloc, "&#39;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&#34;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

/// scriptSafe makes a JSON blob safe to embed inside an inline <script>: every
/// `<` becomes `\u003c`, which JSON reads back as the same `<`. Escaping only
/// `</` is not enough (metal-vmm QUEUE 266): `<!--` then `<script` puts the
/// HTML tokenizer in its double-escaped state, where the page's own
/// `</script>` no longer ends the element, and what follows runs as part of
/// it. With no `<` at all, no tag or comment can start. JSON only: `<` can
/// stand only inside a JSON string, where the escape means the same, but not
/// in script code (`a < b`). Returns an alloc-owned copy.
pub fn scriptSafe(alloc: Alloc, s: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, s, "<", "\\u003c");
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, s, "<", "\\u003c", out);
    return out;
}

test "scriptSafe: no `<` is left, so neither `</script>` nor `<!--<script` can end or swallow the element (metal-vmm QUEUE 266)" {
    const a = std.testing.allocator;
    const got = try scriptSafe(a, "{\"x\":\"<!--<script>\",\"y\":\"</script><script src=/evil.js>\"}");
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"x\":\"\\u003c!--\\u003cscript>\",\"y\":\"\\u003c/script>\\u003cscript src=/evil.js>\"}", got);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, '<') == null);
    // What the browser's JSON.parse gives back is the text as it was.
    const parsed = try std.json.parseFromSlice(struct { x: []const u8, y: []const u8 }, a, got, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("<!--<script>", parsed.value.x);
}
