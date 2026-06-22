//! html: tiny HTML helpers shared across every page-rendering module. No state,
//! no I/O — just escaping. Lives on its own (not in chat.zig) so chrome.zig and
//! the non-chat pages (login, game, admin, …) can escape without importing the
//! chat dispatcher.

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

/// scriptSafe makes a JSON/text blob safe to embed inside an inline <script>:
/// the only sequence that can close the element early is `</` (e.g. `</script>`),
/// so escape it to `<\/`. Browsers read `<\/script>` as literal text. Returns an
/// alloc-owned copy.
pub fn scriptSafe(alloc: Alloc, s: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, s, "</", "<\\/");
    const out = try alloc.alloc(u8, n);
    _ = std.mem.replace(u8, s, "</", "<\\/", out);
    return out;
}
