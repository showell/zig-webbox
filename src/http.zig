//! http: small helpers over std.http.Server, part of the `webbox` library:
//! content-type headers, owned reads of the request head, forms, embedded files
//! a browser caches, redirects and the common responses (an event stream's are
//! sse.zig's). They keep an application's handlers terse.

const std = @import("std");
const Io = std.Io;
const edge = @import("edge.zig");

pub const html_ct = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };
pub const js_ct = std.http.Header{ .name = "content-type", .value = "application/javascript; charset=utf-8" };
pub const json_ct = std.http.Header{ .name = "content-type", .value = "application/json; charset=utf-8" };
pub const plain_ct = std.http.Header{ .name = "content-type", .value = "text/plain; charset=utf-8" };
pub const ndjson_ct = std.http.Header{ .name = "content-type", .value = "application/x-ndjson; charset=utf-8" };
pub const pdf_ct = std.http.Header{ .name = "content-type", .value = "application/pdf" };
pub const png_ct = std.http.Header{ .name = "content-type", .value = "image/png" };
pub const svg_ct = std.http.Header{ .name = "content-type", .value = "image/svg+xml" };
pub const wasm_ct = std.http.Header{ .name = "content-type", .value = "application/wasm" };
pub const octet_ct = std.http.Header{ .name = "content-type", .value = "application/octet-stream" };

/// The request line and headers together, the most a host reads before
/// answering 431.
pub const head_bytes = 16 * 1024;

// ── request-head accessors (the OWNING chokepoint) ───────────────────────────
//
// Reading the request BODY invalidates the std.http head strings (the zig-0.16
// `received_head` gotcha): any borrowed slice of a header value or the target
// silently becomes garbage afterward, which can attribute an authenticated post
// to the wrong principal. So every accessor here returns memory OWNED by the
// caller's allocator — a head value you hold can never dangle. An application
// that reads the head only through this module (`req.head.target` and
// `req.iterateHeaders()` touched nowhere else) cannot make the mistake; a lint
// holding its other files to that keeps it impossible rather than fixed once.

/// header returns the value of the first request header whose name
/// case-insensitively matches `name`, OWNED (duped into `alloc`), or null.
pub fn header(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return try alloc.dupe(u8, h.value);
    }
    return null;
}

/// target returns the request target (`/path?query`), OWNED. Routing keeps
/// slices of it alive past body reads, so it must not borrow from the head.
pub fn target(req: *std.http.Server.Request, alloc: std.mem.Allocator) ![]const u8 {
    return alloc.dupe(u8, req.head.target);
}

/// **AN EMBEDDED FILE THE BROWSER KEEPS** (metal-vmm QUEUE 158; Steve,
/// 2026-10-11). Its `ETag` is a hash of its bytes, and a page names it by that
/// hash (`hashedSrc`: `path?h=<hash>`).
/// - **Asked for by its hash:** `Cache-Control: public, max-age=31536000,
///   immutable`. The browser never asks for those bytes again; a changed file
///   is a new hash, so the next page names a new URL, fetched once.
/// - **Asked for without it, or by another** (a tab open across a deploy, a
///   wasm a script fetches by name): today's bytes with `no-cache`, and a
///   request whose `If-None-Match` names the tag is a 304 with no body.
/// The hash is taken per request: at compile time, one 396 KB script alone
/// cost two minutes.
pub fn serveEmbedded(req: *std.http.Server.Request, body: []const u8, content_type: std.http.Header) !void {
    const hash = hashOf(body);
    var buf: [hash.len + 2]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "\"{s}\"", .{&hash}) catch unreachable;
    const etag = std.http.Header{ .name = "etag", .value = tag };
    const cache = std.http.Header{ .name = "cache-control", .value = if (askedHash(req.head.target, &hash)) "public, max-age=31536000, immutable" else "no-cache" };
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "if-none-match") and namesTag(h.value, tag))
            return req.respond("", .{ .status = .not_modified, .extra_headers = &.{ etag, cache } });
    }
    return req.respond(body, .{ .extra_headers = &.{ content_type, etag, cache } });
}

/// An embedded file's hash, as its ETag and its URL name it.
fn hashOf(body: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{std.hash.Wyhash.hash(0, body)}) catch unreachable;
    return out;
}

/// **A PAGE NAMES AN EMBEDDED FILE BY ITS BYTES**: `path?h=<hash>`, the URL
/// `serveEmbedded` answers as immutable.
pub fn hashedSrc(alloc: std.mem.Allocator, path: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}?h={s}", .{ path, &hashOf(body) });
}

/// `<script src="path?h=<hash>"></script>`.
pub fn scriptTag(alloc: std.mem.Allocator, path: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "<script src=\"{s}\"></script>", .{try hashedSrc(alloc, path, body)});
}

/// Whether `target`'s query has `h=` naming `hash`.
fn askedHash(target_: []const u8, hash: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, target_, '?') orelse return false;
    var params = std.mem.splitScalar(u8, target_[q + 1 ..], '&');
    while (params.next()) |p| {
        if (std.mem.startsWith(u8, p, "h=") and std.mem.eql(u8, p[2..], hash)) return true;
    }
    return false;
}

test "askedHash: the query's h names the hash, or it does not" {
    try std.testing.expect(askedHash("/a.js?h=00ff", "00ff"));
    try std.testing.expect(askedHash("/a.js?x=1&h=00ff", "00ff"));
    try std.testing.expect(!askedHash("/a.js?h=00f", "00ff"));
    try std.testing.expect(!askedHash("/a.js?hh=00ff", "00ff"));
    try std.testing.expect(!askedHash("/a.js", "00ff"));
    try std.testing.expect(!askedHash("/a.js?v=zig", "00ff"));
}

/// Whether an `If-None-Match` value names `tag`: a list of tags, each
/// possibly weak (`W/`), or `*` (RFC 9110 §13.1.2).
fn namesTag(if_none_match: []const u8, tag: []const u8) bool {
    var each = std.mem.splitScalar(u8, if_none_match, ',');
    while (each.next()) |raw| {
        const one = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, one, "*")) return true;
        const strong = if (std.mem.startsWith(u8, one, "W/")) one[2..] else one;
        if (std.mem.eql(u8, strong, tag)) return true;
    }
    return false;
}

test "namesTag: a list, weak tags and * name it; another tag or a bare value does not" {
    try std.testing.expect(namesTag("\"ab\"", "\"ab\""));
    try std.testing.expect(namesTag("\"x\", W/\"ab\"", "\"ab\""));
    try std.testing.expect(namesTag("*", "\"ab\""));
    try std.testing.expect(!namesTag("\"abc\"", "\"ab\""));
    try std.testing.expect(!namesTag("ab", "\"ab\""));
    try std.testing.expect(!namesTag("", "\"ab\""));
}

/// **WHAT EVERY COOKIE A SITE SETS SAYS ABOUT ITSELF** (metal-vmm QUEUE
/// 162.2), after its `Path` and `Max-Age`: kept from scripts, sent only over
/// HTTPS, and not on another site's requests. Behind Caddy the application
/// sees plain http, and that is fine: `Secure` is for the browser, which
/// speaks HTTPS to Caddy. On `http://localhost` during development, Chrome
/// and Firefox treat the page as secure and keep and send the cookie; a
/// browser that does not (older Safari) drops it, and each page load is a
/// new visitor there.
pub const cookie_attributes = "HttpOnly; Secure; SameSite=Lax";

/// cookie returns the value of cookie `name` from any Cookie header, OWNED, or null.
pub fn cookie(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        if (parseCookieValue(h.value, name)) |v| return try alloc.dupe(u8, v);
    }
    return null;
}

/// parseCookieValue extracts cookie `name` from one Cookie header value
/// (`a=1; b=2`), or null. PURE — returns a slice INTO `header_value`; the owning
/// is `cookie`'s job. Split out so the parse is unit-testable without a Request.
fn parseCookieValue(header_value: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, header_value, ';');
    while (pairs.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// queryValue pulls one (un-decoded) query parameter from a request target
/// (`/path?a=1&b=2`), or null when absent. PURE — a slice into `target`; pass an
/// OWNED target (from `target`) when the result outlives a body read.
pub fn queryValue(target_str: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target_str, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target_str[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// **ONE FORM DECODER** (metal-vmm QUEUE 156(i)): the value of field `name`
/// in an `a=b&c=d` form or query, `+` a space and `%XX` a byte, or null when
/// there is no such field. A `%` that is not two hex digits, or a field sent
/// twice, is `error.MalformedForm`: the client's mistake, which an application
/// answers 400, never 500. One decoder, so every form on a site reads a bad
/// escape and a repeated field the same way.
pub fn formField(alloc: std.mem.Allocator, body: []const u8, name: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        if (found != null) return error.MalformedForm;
        found = try formDecode(alloc, pair[eq + 1 ..]);
    }
    return found;
}

/// A form value decoded: `+` a space, `%XX` a byte; a `%` that is not two hex
/// digits is `error.MalformedForm`.
pub fn formDecode(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '+' => try out.append(alloc, ' '),
            '%' => {
                if (i + 2 >= raw.len) return error.MalformedForm;
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.MalformedForm;
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.MalformedForm;
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 2;
            },
            else => try out.append(alloc, raw[i]),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// **A REDIRECT TARGET ON THIS SITE, OR THE SITE'S ROOT** (`?next=`, a form's
/// `next`): a path that starts with one slash and that no browser can read as
/// another host. A browser reads a backslash as a slash and drops a tab or
/// newline before it looks, so `/\evil.example` and `/\t/evil.example` are
/// `//evil.example` to it: any backslash, any control character, or a second
/// slash first is refused (the normalization hunt, 2026-10-10).
pub fn internalTarget(next: []const u8) []const u8 {
    if (next.len == 0 or next[0] != '/') return "/";
    if (next.len > 1 and next[1] == '/') return "/";
    for (next) |c| if (c == '\\' or c < 0x20 or c == 0x7f) return "/";
    return next;
}

/// **THE TAIL OF `path` UNDER `prefix`**, when `path` is exactly `prefix` or
/// `prefix` followed by '/'; null otherwise, so "/drivingX" is not under
/// "/driving". The tail keeps its leading '/' (or is empty).
pub fn pathUnder(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const tail = path[prefix.len..];
    if (tail.len == 0 or tail[0] == '/') return tail;
    return null;
}

/// A request target's path: up to the first '?' (e.g. /driving/blitter.js
/// from /driving/blitter.js?h=…).
pub fn pathOf(target_: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target_, '?')) |q| return target_[0..q];
    return target_;
}

test "pathUnder: the prefix itself, or the prefix and a '/', and nothing else" {
    try std.testing.expectEqualStrings("", pathUnder("/driving", "/driving").?);
    try std.testing.expectEqualStrings("/app.js", pathUnder("/driving/app.js", "/driving").?);
    try std.testing.expect(pathUnder("/drivingX", "/driving") == null);
    try std.testing.expect(pathUnder("/chat", "/driving") == null);
    try std.testing.expectEqualStrings("/a.js", pathOf("/a.js?h=00ff"));
    try std.testing.expectEqualStrings("/a.js", pathOf("/a.js"));
}

pub fn notFound(req: *std.http.Server.Request) !void {
    try req.respond("not found\n", .{ .status = .not_found });
}

pub fn methodNotAllowed(req: *std.http.Server.Request) !void {
    try req.respond("method not allowed\n", .{ .status = .method_not_allowed });
}

/// readLimitedBody reads the request body capped at `max` bytes. On success
/// returns the body (alloc-owned). On overflow it responds 413 and returns null;
/// on any other read error it responds 400 and returns null — so callers just
/// `return` when the result is null.
///
/// `max + 1`: allocRemaining errors when the limit is *reached* (≥), so to allow
/// a body of exactly `max` and reject only `max + 1` we pass `max + 1`.
///
/// No-framing guard: a request with NO Content-Length and NO chunked transfer
/// encoding has no body (RFC 9110). zig's bodyReader would otherwise frame that
/// as `.body_none` = the raw connection reader, so allocRemaining reads until the
/// socket closes — which, with keep-alive off and the client awaiting our
/// response, hangs forever. A browser form post always sends Content-Length (0
/// for an empty form), so this only bites a malformed/handcrafted client; we
/// treat it as the empty body it spec'ly is rather than hang. (Steve, 2026-06-19.)
pub fn readLimitedBody(req: *std.http.Server.Request, alloc: std.mem.Allocator, max: usize) !?[]u8 {
    if (req.head.content_length == null and req.head.transfer_encoding == .none) {
        return try alloc.alloc(u8, 0);
    }
    var buf: [4 * 1024]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    return reader.allocRemaining(alloc, .limited(max + 1)) catch |e| switch (e) {
        error.StreamTooLong => {
            try edge.reject(req, .body_too_large, "request body too large\n");
            return null;
        },
        else => {
            try edge.reject(req, .body_unreadable, "read body\n");
            return null;
        },
    };
}

/// redirect sends a 303 See Other to `location`.
pub fn redirect(req: *std.http.Server.Request, location: []const u8) !void {
    try req.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

const testing = std.testing;

test "parseCookieValue: picks the named cookie, trims spaces, ignores the rest" {
    try testing.expectEqualStrings("xyz", parseCookieValue("a=1; gopher_auth=xyz; b=2", "gopher_auth").?);
    try testing.expectEqualStrings("1", parseCookieValue("a=1", "a").?);
    try testing.expectEqualStrings("3", parseCookieValue("gopher_uid=3", "gopher_uid").?);
    try testing.expect(parseCookieValue("a=1; b=2", "c") == null);
    try testing.expect(parseCookieValue("", "a") == null);
    try testing.expect(parseCookieValue("noequalssign", "a") == null);
}

// The regression test for the bug this whole module exists to prevent: a value
// read from the request head, used after the body read that clobbers the head
// buffer. parseCookieValue returns a slice INTO the source (what the accessor
// borrows before duping); we prove the dupe — and only the dupe — survives the
// source being overwritten, exactly as a chunked body read overwrites the head.
test "head value must be owned: a clobbered source buffer corrupts the borrow, not the dupe" {
    var buf: [12]u8 = undefined;
    @memcpy(&buf, "sid=deadbee0"); // "sid=" + an 8-char value
    const borrowed = parseCookieValue(&buf, "sid").?;
    try testing.expectEqualStrings("deadbee0", borrowed);

    const owned = try testing.allocator.dupe(u8, borrowed); // what the accessor does
    defer testing.allocator.free(owned);

    @memset(&buf, 0xAA); // simulate the body read overwriting the head buffer
    try testing.expectEqualStrings("deadbee0", owned); // the owned copy is intact
    try testing.expect(!std.mem.eql(u8, borrowed, owned)); // the borrow is now garbage
}
