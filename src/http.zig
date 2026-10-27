//! http: small helpers over std.http.Server, part of the `webbox` library:
//! content-type headers, owned reads of the request head, forms, embedded files
//! a browser caches, redirects and the common responses (an event stream's are
//! sse.zig's). They keep an application's handlers terse.

const std = @import("std");
const Io = @import("host_io").Io;
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

/// **A MOUNTED APPLICATION'S TARGET** (combo.zig): the head's target with its
/// first `n` bytes (the mount's prefix) off, so the mount sees itself at `/`;
/// the whole target is returned for `restoreTarget` once the mount answers.
/// The head is not copied: the mount reads it through this module as any
/// application does.
pub fn stripTarget(req: *std.http.Server.Request, n: usize) []const u8 {
    const whole = req.head.target;
    req.head.target = whole[n..];
    return whole;
}

pub fn restoreTarget(req: *std.http.Server.Request, whole: []const u8) void {
    req.head.target = whole;
}

/// The target's path, without its query, copied into `buf` (cut short to
/// fit): an owned copy with no allocation, for a count kept of every
/// request (traffic.zig, metal-vmm QUEUE 189.5).
pub fn pathInto(req: *const std.http.Server.Request, buf: []u8) []const u8 {
    const t = req.head.target;
    const path = t[0 .. std.mem.indexOfScalar(u8, t, '?') orelse t.len];
    const n = @min(path.len, buf.len);
    @memcpy(buf[0..n], path[0..n]);
    return buf[0..n];
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

/// **A LEGACY COOKIE ISSUED AFTER THIS IS A PLANT** (170.8's cold review): the
/// site issues only `__Host-` names from its move on, so a legacy-named value
/// signed later came from somewhere else (a sibling subdomain), and is not
/// read, nor moved to the new name (which would outlive the end date). Set
/// on or after the day the move deploys: 2026-10-14 00:00 UTC, two days
/// past the planned deploy. A value issued after it, before the deploy, is
/// read as no one (its visitor signs in again), so a release after this day
/// moves it first.
///
/// **ACCEPTED** (metal-vmm QUEUE 176.9): a sibling subdomain can still plant a
/// legacy value issued BEFORE the cutoff on a visitor with no `__Host-` cookie
/// yet, and it is moved to the new name. The cutoff narrows that; the end
/// date ends it.
pub const legacy_issued_before_unix: i64 = 1_791_936_000;

/// **THE CLOCK THE END DATE IS READ BY** (metal-vmm QUEUE 176.1): the real one,
/// but in the tests a fixed day before the end date, so the migration's tests
/// do not go red on 2026-11-15 with no change. A test of the end itself sets
/// it; `legacy names have ended` below is the one test that fails that day,
/// saying what to delete.
pub var names_clock_for_test: ?i64 = if (@import("builtin").is_test) legacy_names_until_unix - 30 * 86_400 else null;

/// The time the legacy names' end date is judged by, given the real one.
pub fn namesNow(real_now: i64) i64 {
    return names_clock_for_test orelse real_now;
}

pub fn cookieOrLegacy(req: *std.http.Server.Request, alloc: std.mem.Allocator, name: []const u8, legacy: []const u8, now_unix: i64) !Named {
    const current = try cookie(req, alloc, name);
    if (current != .none or now_unix >= legacy_names_until_unix) return .{ .values = current, .legacy = false };
    return .{ .values = try cookie(req, alloc, legacy), .legacy = true };
}

/// The Set-Cookie that clears a legacy-named cookie (its old name, its old
/// path), sent with the answer that moves it. **NOT SECURE** (170.8's cold
/// review): over plain http a browser refuses a Set-Cookie that says Secure,
/// so a clear that said it would be dropped with the move, and the legacy
/// cookie (set before 162.2, without Secure) would 303 for ever. A clear
/// carries no value, and still works from HTTPS.
pub fn clearCookie(comptime name: []const u8) []const u8 {
    return name ++ "=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax";
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
/// slash first is refused (the normalization hunt, 2026-10-10). A control
/// character refused is a CR or LF too, so no target splits the header.
///
/// **SEALED** (metal-vmm QUEUE 250): `redirect` takes only a `Target`, and
/// only this file makes one, so a target from a form or a query cannot
/// reach the `location` header unchecked. Zig has no private fields, so
/// a literal, or a change to one made, is refused by shale's
/// cookbook/sealed.shale outside this file, over this tree and every
/// consumer's (`zig build consumers`, angry-gopher's ops/check_zig): it
/// refuses `.target_path =` and `.target_seal =`. The path is read by
/// `path()`. **A `location` HEADER IS SET HERE ONLY** (`redirect`,
/// `redirectWith`); the same lint refuses `.name = "location"` elsewhere.
pub const Target = struct {
    target_path: []const u8,
    target_seal: Seal,

    /// `next` if it is a path on this site, else the site's root: for a
    /// target a visitor names (`?next=`), where the root is the answer.
    pub fn of(next: []const u8) Target {
        return .{ .target_path = if (internal(next)) next else "/", .target_seal = .{} };
    }

    /// The path the `location` header carries.
    pub fn path(t: Target) []const u8 {
        return t.target_path;
    }

    /// A path written in the source, checked as it compiles.
    pub fn literal(comptime p: []const u8) Target {
        comptime if (!internal(p)) @compileError("not a path on this site: " ++ p);
        return .{ .target_path = p, .target_seal = .{} };
    }

    /// A relative path written in the source (`town/`), checked as it
    /// compiles: it lands under whatever prefix a host mounts the page at, so
    /// it may not begin with a slash or a backslash, and with no `:` it names
    /// no scheme (`https:`, `javascript:`).
    pub fn relative(comptime p: []const u8) Target {
        comptime if (!relativeOnSite(p)) @compileError("not a relative path on this site: " ++ p);
        return .{ .target_path = p, .target_seal = .{} };
    }

    /// `fmt` filled in, checked as `of` checks it, and **one not on this site
    /// is `error.NotOnSite`**, never the root (the box's review): a path the
    /// server builds goes where it says or nowhere, and the caller says
    /// which answer that is.
    pub fn format(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, NotOnSite }!Target {
        const p = try std.fmt.allocPrint(alloc, fmt, args);
        if (!internal(p)) return error.NotOnSite;
        return .{ .target_path = p, .target_seal = .{} };
    }
};

const Seal = struct {};

fn relativeOnSite(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    for (path) |c| if (c == ':' or c == '\\' or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn internal(next: []const u8) bool {
    if (next.len == 0 or next[0] != '/') return false;
    if (next.len > 1 and next[1] == '/') return false;
    for (next) |c| if (c == '\\' or c < 0x20 or c == 0x7f) return false;
    return true;
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

/// A 405, naming the one method the route takes (metal-vmm QUEUE 177.6: a
/// 405 must say what is allowed, RFC 9110 15.5.6).
pub fn methodNotAllowed(req: *std.http.Server.Request, allow: std.http.Method) !void {
    declineExpectation(req);
    try req.respond("method not allowed\n", .{ .status = .method_not_allowed, .extra_headers = &.{.{ .name = "allow", .value = @tagName(allow) }} });
}

/// readLimitedBody reads the request body capped at `max` bytes. On success
/// returns the body (alloc-owned). On overflow it responds 413 and returns null;
/// on any other read error 400; and null each time, so callers just `return`
/// when the result is null. Every host has the body in memory by now
/// (body.zig: the turn never waits on the network).
///
/// `max`: allocRemaining (since Zig 0.17) takes a body of exactly its limit
/// and errors past it, so a body of `max` is read and `max + 1` refused.
/// (Under 0.16 it errored on reaching the limit, and this passed `max + 1`.)
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
    const got = reader.allocRemaining(alloc, .limited(max)) catch |e| switch (e) {
        error.StreamTooLong => {
            try edge.reject(req, .body_too_large, "request body too large\n");
            return null;
        },
        // Memory that runs out is the server's (a 500 the host logs), never
        // the client's malformed body (metal-vmm QUEUE 172).
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => {
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

/// redirect sends a 303 See Other to `location`, a path on this site.
pub fn redirect(req: *std.http.Server.Request, location: Target) !void {
    return redirectWith(req, location, .{});
}

/// A redirect's status and what rides with it (a Set-Cookie, say).
pub const RedirectOptions = struct {
    status: std.http.Status = .see_other,
    /// At most `redirect_headers_most`; no `location` among them.
    headers: []const std.http.Header = &.{},
};

pub const redirect_headers_most = 8;

/// A redirect to `location` with `opts.status` and `opts.headers` beside it:
/// the one way, with `redirect`, that a `location` header is set.
pub fn redirectWith(req: *std.http.Server.Request, location: Target, opts: RedirectOptions) !void {
    if (opts.headers.len > redirect_headers_most) return error.TooManyHeaders;
    var hs: [redirect_headers_most + 1]std.http.Header = undefined;
    hs[0] = .{ .name = "location", .value = location.target_path };
    for (opts.headers, hs[1..][0..opts.headers.len]) |h, *to| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) return error.LocationTwice;
        to.* = h;
    }
    declineExpectation(req);
    try req.respond("", .{ .status = opts.status, .extra_headers = hs[0 .. opts.headers.len + 1] });
}

const testing = std.testing;

test "Target: a path on this site is kept; anything a browser could read as another host, or that splits a header, is the root" {
    for ([_][]const u8{ "/", "/game", "/chat/c/1_2/ChitChat?x=1#msg-ChitChat_3" }) |ok| try testing.expectEqualStrings(ok, Target.of(ok).path());
    for ([_][]const u8{ "", "game", "//evil.example", "https://evil.example", "/\\evil.example", "/\t/evil.example", "/x\r\nset-cookie: a=b", "/x\x7f" }) |bad| try testing.expectEqualStrings("/", Target.of(bad).path());
    try testing.expectEqualStrings("/login", Target.literal("/login").path());
    try testing.expectEqualStrings("town/", Target.relative("town/").path());
    try testing.expect(comptime !relativeOnSite("/x") and !relativeOnSite("https://evil.example") and !relativeOnSite("\\\\evil") and !relativeOnSite("") and relativeOnSite("a/b?c=1"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/chat/c/7", (try Target.format(arena.allocator(), "/chat/c/{d}", .{7})).path());
    // A built path off the site is an error, never the root.
    for ([_][]const u8{ "//evil.example", "/a\\b", "/x\ny" }) |bad| try testing.expectError(error.NotOnSite, Target.format(arena.allocator(), "{s}", .{bad}));
}

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
    const at = try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\n" ++ &@as([max]u8, @splat('b')), max, &status);
    try testing.expectEqualStrings(&@as([max]u8, @splat('b')), at.?);
    try testing.expect(try readBodyOf(a, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n" ++ &@as([max + 1]u8, @splat('b')), max, &status) == null);
    try testing.expectEqualStrings("413", status);
    // Chunked, the same edge: the length is not stated, the bytes are counted.
    const chunked = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    try testing.expectEqualStrings(&@as([max]u8, @splat('b')), (try readBodyOf(a, chunked ++ "8\r\n" ++ &@as([max]u8, @splat('b')) ++ "\r\n0\r\n\r\n", max, &status)).?);
    try testing.expect(try readBodyOf(a, chunked ++ "9\r\n" ++ &@as([max + 1]u8, @splat('b')) ++ "\r\n0\r\n\r\n", max, &status) == null);
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
    const pad = &@as([head_bytes - start.len - end.len]u8, @splat('p'));
    try receiveThroughHostBuffer(start ++ pad ++ end);
    try testing.expectError(error.HttpHeadersOversize, receiveThroughHostBuffer(start ++ pad ++ "p" ++ end));
}

test "readLimitedBody: memory that runs out is the server's error, never the client's 400 'read body' (metal-vmm QUEUE 172)" {
    var reader: std.Io.Reader = .fixed("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, readLimitedBody(&req, failing.allocator(), 100));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "the legacy names have ended on 2026-11-15: delete the migration, its tests, and the judges' legacy steps (metal-vmm QUEUE 176.1)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const real: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, threaded.io()).nanoseconds, std.time.ns_per_s));
    if (real >= legacy_names_until_unix) {
        std.debug.print("the legacy cookie names ended on 2026-11-15: delete http.cookieOrLegacy's legacy branch, users' session move, uid_cookie's unsigned window, their tests, and zig-metal-unikernel probe/judge_gopher.py's legacy steps\n", .{});
        return error.LegacyNamesHaveEnded;
    }
}

test "methodNotAllowed is a 405 that names the method allowed (RFC 9110 15.5.6; metal-vmm QUEUE 177.6)" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var reader: std.Io.Reader = .fixed("DELETE /x HTTP/1.1\r\nHost: x\r\n\r\n");
    var server = std.http.Server.init(&reader, &out);
    var req = try server.receiveHead();
    try methodNotAllowed(&req, .POST);
    const got = out.buffered();
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 405"));
    try testing.expect(std.mem.indexOf(u8, got, "\r\nallow: POST\r\n") != null);
}
