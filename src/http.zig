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

/// A request's cookies of one name, OWNED. **SEVERAL IS ITS OWN CASE**
/// (metal-vmm QUEUE 162.4): a cookie set for a parent domain arrives beside
/// a subdomain's own of the same name, and which one a browser sends first is
/// not the site's to choose, so no caller is handed "the first".
pub const CookieValues = union(enum) {
    none,
    one: []const u8,
    several: []const []const u8,
};

/// **EVERY SIGNED COOKIE IS A `__Host-` ONE** (metal-vmm QUEUE 167.5): a
/// browser keeps a cookie of this prefix only when it is Secure, has
/// `Path=/` and no `Domain`, so a sibling subdomain cannot plant one for
/// this site (one it set for `Domain=lynrummy.com` sat beside the site's own,
/// and with two that verify naming no one, kept its victim logged out).
pub const host_prefix = "__Host-";

/// A cookie read under its name, or, when the request has none of that name,
/// under the name it had before (`legacy`): the migration read. `legacy` in
/// the answer says which it was, so the caller can move it to the new name.
pub const Named = struct { values: CookieValues, legacy: bool };

/// **THE LEGACY NAMES ARE READ UNTIL THIS SECOND, AND NEVER AFTER** (metal-vmm
/// QUEUE 170.8): 2026-11-15, a month past the move. A legacy cookie can be
/// planted by a sibling subdomain (that is why the names moved), so reading
/// one at all is a door left open; until then a visitor's next GET moves it.
pub const legacy_names_until_unix: i64 = 1_794_700_800;

pub fn cookieOrLegacy(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8, legacy: []const u8, now_unix: i64) !Named {
    const current = try cookie(req, alloc, name);
    if (current != .none or now_unix >= legacy_names_until_unix) return .{ .values = current, .legacy = false };
    return .{ .values = try cookie(req, alloc, legacy), .legacy = true };
}

/// The Set-Cookie that clears a legacy-named cookie (its old name, its old
/// path), sent with the answer that moves it.
pub fn clearCookie(comptime name: []const u8) []const u8 {
    return name ++ "=; Path=/; Max-Age=0; " ++ cookie_attributes;
}

/// Every value of cookie `name`, from every Cookie header.
pub fn cookie(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8) !CookieValues {
    var found: std.ArrayList([]const u8) = .empty;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, h.value, ';');
        while (pairs.next()) |raw| {
            const pair = std.mem.trim(u8, raw, " \t");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) try found.append(alloc, try alloc.dupe(u8, pair[eq + 1 ..]));
        }
    }
    return switch (found.items.len) {
        0 => .none,
        1 => .{ .one = found.items[0] },
        else => .{ .several = found.items },
    };
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

/// **A REFUSAL NEVER SAYS "SEND IT"** (metal-vmm QUEUE 166): std's `respond`
/// answers a pending `Expect: 100-continue` before anything else, so a
/// client refused without its body being read was told to send it first,
/// and began an upload into a connection about to close. Every refusal here
/// (and edge.reject) declines it instead. A body already read has had its
/// expectation answered, and std cleared it then.
pub fn declineExpectation(req: *std.http.Server.Request) void {
    req.head.expect = null;
}

pub fn notFound(req: *std.http.Server.Request) !void {
    declineExpectation(req);
    try req.respond("not found\n", .{ .status = .not_found });
}

pub fn methodNotAllowed(req: *std.http.Server.Request) !void {
    declineExpectation(req);
    try req.respond("method not allowed\n", .{ .status = .method_not_allowed });
}

/// readLimitedBody reads the request body capped at `max` bytes. On success
/// returns the body (alloc-owned). On overflow it responds 413 and returns null;
/// on any other read error 400; and null each time, so callers just `return`
/// when the result is null. Every host has the body in memory by now
/// (body.zig: the turn never waits on the network).
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
/// **THE BODY A HOST READ BEFORE THE TURN, HANDED OVER AS IT IS** (metal-vmm
/// QUEUE 170.5): set by the host just before the route runs (one route at a
/// time) and cleared after, so `readLimitedBody` returns it without a second
/// copy: an upload is in memory once.
pub var held_body: ?[]u8 = null;

pub fn readLimitedBody(req: *std.http.Server.Request, alloc: std.mem.Allocator, max: usize) !?[]u8 {
    if (held_body) |b| {
        held_body = null;
        if (b.len > max) {
            try edge.reject(req, .body_too_large, "request body too large\n");
            return null;
        }
        return b;
    }
    if (req.head.content_length == null and req.head.transfer_encoding == .none) {
        return try alloc.alloc(u8, 0);
    }
    var buf: [4 * 1024]u8 = undefined;
    const declared = req.head.content_length;
    const reader = try req.readerExpectContinue(&buf);
    const got = reader.allocRemaining(alloc, .limited(max + 1)) catch |e| switch (e) {
        error.StreamTooLong => {
            try edge.reject(req, .body_too_large, "request body too large\n");
            return null;
        },
        else => {
            try edge.reject(req, .body_unreadable, "read body\n");
            return null;
        },
    };
    // **A BODY CUT SHORT IS NOT A BODY** (metal-vmm QUEUE 166): std's reader
    // ends a Content-Length body at the connection's end, short, without a
    // word, so a client that hangs up halfway (or a stranger's upload, which
    // the host never reads) would hand the handler half a body as the whole.
    if (declared) |n| if (got.len != n) {
        alloc.free(got);
        try edge.reject(req, .body_unreadable, "read body\n");
        return null;
    };
    return got;
}

/// redirect sends a 303 See Other to `location`.
pub fn redirect(req: *std.http.Server.Request, location: []const u8) !void {
    declineExpectation(req);
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

test "formDecode: a %XX that ends the value is a byte, a %X that ends it is malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("aA", try formDecode(a, "a%41"));
    try testing.expectError(error.MalformedForm, formDecode(a, "a%4"));
    try testing.expectEqualStrings("A", try formDecode(a, "%41"));
    try testing.expectError(error.MalformedForm, formDecode(a, "%4"));
    try testing.expectError(error.MalformedForm, formDecode(a, "%"));
}

/// The status line's code of a response written to `out`.
fn statusOf(out: []const u8) []const u8 {
    return if (out.len >= 12) out[9..12] else "";
}

/// `raw` received as a request, its body read with `readLimitedBody(max)`:
/// the body, or null and the status it was answered with.
fn readBodyOf(a: std.mem.Allocator, raw: []const u8, max: usize, status: *[]const u8) !?[]u8 {
    var reader: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    const got = try readLimitedBody(&req, a, max);
    try out.writer.flush();
    status.* = statusOf(out.written());
    return got;
}

test "readLimitedBody: a body of exactly the limit is read, one byte more is refused 413" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const max = 8;
    var status: []const u8 = "";
    const at = try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n" ++ "b" ** max, max, &status);
    try testing.expectEqualStrings("b" ** max, at.?);
    try testing.expect(try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n" ++ "b" ** (max + 1), max, &status) == null);
    try testing.expectEqualStrings("413", status);
    // Chunked, the same edge: the length is not stated, the bytes are counted.
    const chunked = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    try testing.expectEqualStrings("b" ** max, (try readBodyOf(a, chunked ++ "8\r\n" ++ "b" ** max ++ "\r\n0\r\n\r\n", max, &status)).?);
    try testing.expect(try readBodyOf(a, chunked ++ "9\r\n" ++ "b" ** (max + 1) ++ "\r\n0\r\n\r\n", max, &status) == null);
    try testing.expectEqualStrings("413", status);
}

test "readLimitedBody: a Content-Length body cut short by the connection's end is refused 400 (metal-vmm QUEUE 166)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var status: []const u8 = "";
    const short = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\nbbbb";
    try testing.expect(try readBodyOf(a, short, 64, &status) == null);
    try testing.expectEqualStrings("400", status);
}

test "cookieOrLegacy: the legacy name is read before its end date and never after (metal-vmm QUEUE 170.8)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nCookie: old=1\r\n\r\n");
    var out: std.Io.Writer.Allocating = .init(a);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();
    const before = try cookieOrLegacy(&req, a, "__Host-old", "old", legacy_names_until_unix - 1);
    try testing.expect(before.legacy and before.values == .one);
    const after = try cookieOrLegacy(&req, a, "__Host-old", "old", legacy_names_until_unix);
    try testing.expect(!after.legacy and after.values == .none);
}

test "readLimitedBody: a body the host holds is handed over as it is, no copy, its cap still kept (metal-vmm QUEUE 170.5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var held = "hello".*;
    held_body = &held;
    var status: []const u8 = "";
    const got = (try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", 64, &status)).?;
    try testing.expectEqual(@as([*]u8, &held), got.ptr);
    try testing.expect(held_body == null);
    held_body = &held;
    try testing.expect(try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", 4, &status) == null);
    try testing.expectEqualStrings("413", status);
}

/// `raw` received through a read buffer of `head_bytes`, as a host reads it.
fn receiveThroughHostBuffer(raw: []const u8) !void {
    var src: std.Io.Reader = .fixed(raw);
    var buf: [head_bytes]u8 = undefined;
    var limited = src.limited(.unlimited, &buf);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var server = std.http.Server.init(&limited.interface, &discard.writer);
    _ = try server.receiveHead();
}

test "head_bytes: a request head of exactly head_bytes is received, one byte more is oversize (431)" {
    const start = "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: ";
    const end = "\r\n\r\n";
    const pad = "p" ** (head_bytes - start.len - end.len);
    try receiveThroughHostBuffer(start ++ pad ++ end);
    try testing.expectError(error.HttpHeadersOversize, receiveThroughHostBuffer(start ++ pad ++ "p" ++ end));
}
