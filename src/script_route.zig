//! **A SIGNED SCRIPT, RUN ON THE LIVE SITE** (metal-vmm QUEUE 200): the
//! reusable half of an application's `POST /admin/script`. The application
//! checks its admin's bearer key (the first lock), hands the body here, and
//! answers with what comes back. Here: the envelope read, its Ed25519
//! signature checked against the public key the server holds (the second
//! lock), the target, the expiry and the sequence number, the sequence
//! written durably before anything runs, the run itself (`script.run`), the
//! log of it, and the reply.
//!
//! **THE ENVELOPE** (the request's body), three parts, nothing optional:
//!
//!     shale-signature <128 hex digits>\n
//!     shale-1 target=<host> sequence=<n> expires=<unix seconds>\n
//!     <the script's bytes, to the end of the body>
//!
//! The signature is over every byte after the first line: the second line
//! and the script. The second line has one spelling for its values (its
//! fields in that order, a single space between, decimal without leading
//! zeros, a host name of `a-z 0-9 . -`), checked by writing it again and
//! comparing, so no two bodies that differ mean the same request. `shale-1`
//! is the format's name: a signature over anything else is not one over
//! this.
//!
//! **THE ORDER, AND WHAT EACH REFUSAL IS.** Every refusal comes before the
//! script runs and changes nothing on the store, except the last two, which
//! burn the sequence number (the safe direction: a request may be refused
//! and its number spent, never run twice):
//!
//!   1. the envelope, read: 400 `malformed`;
//!   2. the server's config (`public_key`, `target`): 403 `no_key` when
//!      there is none (the route never falls open), 500 `bad_config`;
//!   3. the signature: 403 `bad_signature`;
//!   4. the target: 403 `wrong_target` (a script signed for a test volume
//!      is not one for the site);
//!   5. the expiry: 403 `expired`, or `expires_too_far` past `max_ahead_s`;
//!   6. the sequence: 409 `replayed` at or under the last one run; 503
//!      `sequence_unreadable`;
//!   7. the sequence written, the source kept and the start logged, then
//!      the store made durable (`store.makeDurable`): 503
//!      `not_recorded` when any of it failed. Not run.
//!
//! Then the script runs, and the reply is 200 whatever it did: what it
//! printed, its effects, and how it ended, as the Linux runner prints them
//! (`script.report`). A run whose end could not be logged is answered 500,
//! with the same body and the failure first: loud, never quiet.
//!
//! **ON THE STORE, UNDER THE AUTH ROOT**, out of a script's reach (its paths
//! are confined to the data root): `shale.conf` (the config), `shale/sequence`
//! (the last number accepted), `shale/log` (a line when each run starts, and
//! its effects and ending when it ends) and `shale/runs/<n>.shale` (each
//! run's source, so the log's hash names a script anyone can read back).

const std = @import("std");
const Io = @import("host_io").Io;
const store = @import("store.zig");
const script = @import("script/script.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The format's name, the second line's first word.
pub const format = "shale-1";
/// The most an envelope's header lines take: a body is at most this past
/// the script's own budget.
pub const header_bytes = 512;
/// How far ahead an expiry may be: a signature is good for minutes, so one
/// that leaked is not good for long.
pub const max_ahead_s: i64 = 24 * 60 * 60;

pub const Envelope = struct {
    signature: [Ed25519.Signature.encoded_length]u8,
    target: []const u8,
    sequence: u64,
    expires: i64,
    /// The bytes the signature is over: the second line and the script.
    signed: []const u8,
    source: []const u8,
};

/// Why a request was refused before its script ran.
pub const Refusal = enum {
    malformed,
    no_key,
    bad_config,
    bad_signature,
    wrong_target,
    expired,
    expires_too_far,
    replayed,
    sequence_unreadable,
    not_recorded,

    pub fn status(r: Refusal) std.http.Status {
        return switch (r) {
            .malformed => .bad_request,
            .no_key, .bad_signature, .wrong_target, .expired, .expires_too_far => .forbidden,
            .bad_config => .internal_server_error,
            .replayed => .conflict,
            .sequence_unreadable, .not_recorded => .service_unavailable,
        };
    }
};

/// The second line, as it must be spelled for these values.
pub fn headerLine(buf: []u8, target: []const u8, sequence: u64, expires: i64) ![]const u8 {
    return std.fmt.bufPrint(buf, format ++ " target={s} sequence={d} expires={d}\n", .{ target, sequence, expires });
}

/// The bytes a signer signs: the second line and the script.
pub fn signedBytes(alloc: std.mem.Allocator, target: []const u8, sequence: u64, expires: i64, source: []const u8) ![]u8 {
    var buf: [header_bytes]u8 = undefined;
    const line = try headerLine(&buf, target, sequence, expires);
    return std.mem.concat(alloc, u8, &.{ line, source });
}

/// The whole body a signer sends, `signature` over `signedBytes`.
pub fn envelope(alloc: std.mem.Allocator, signature: [Ed25519.Signature.encoded_length]u8, signed: []const u8) ![]u8 {
    const hex = std.fmt.bytesToHex(signature, .lower);
    return std.mem.concat(alloc, u8, &.{ "shale-signature ", &hex, "\n", signed });
}

pub fn validTarget(t: []const u8) bool {
    if (t.len == 0 or t.len > 253) return false;
    for (t) |c| switch (c) {
        'a'...'z', '0'...'9', '.', '-' => {},
        else => return false,
    };
    return true;
}

/// Reads the envelope, refusing any body that is not exactly one.
pub fn parse(body: []const u8) error{Malformed}!Envelope {
    const first_end = std.mem.indexOfScalar(u8, body, '\n') orelse return error.Malformed;
    const first = body[0..first_end];
    const sig_prefix = "shale-signature ";
    if (!std.mem.startsWith(u8, first, sig_prefix)) return error.Malformed;
    const hex = first[sig_prefix.len..];
    if (hex.len != 2 * Ed25519.Signature.encoded_length) return error.Malformed;
    for (hex) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return error.Malformed,
    };
    var sig: [Ed25519.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig, hex) catch return error.Malformed;

    const signed = body[first_end + 1 ..];
    const second_end = std.mem.indexOfScalar(u8, signed, '\n') orelse return error.Malformed;
    if (second_end + 1 > header_bytes) return error.Malformed;
    const second = signed[0..second_end];
    var fields = std.mem.splitScalar(u8, second, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.Malformed, format)) return error.Malformed;
    const target = try field(fields.next(), "target=");
    const sequence = std.fmt.parseInt(u64, try field(fields.next(), "sequence="), 10) catch return error.Malformed;
    const expires = std.fmt.parseInt(i64, try field(fields.next(), "expires="), 10) catch return error.Malformed;
    if (fields.next() != null) return error.Malformed;
    if (!validTarget(target) or sequence == 0) return error.Malformed;
    // **ONE SPELLING**: written again from what was read, it is what came.
    var again: [header_bytes]u8 = undefined;
    const line = headerLine(&again, target, sequence, expires) catch return error.Malformed;
    if (!std.mem.eql(u8, line, signed[0 .. second_end + 1])) return error.Malformed;
    return .{ .signature = sig, .target = target, .sequence = sequence, .expires = expires, .signed = signed, .source = signed[second_end + 1 ..] };
}

fn field(got: ?[]const u8, comptime name: []const u8) error{Malformed}![]const u8 {
    const f = got orelse return error.Malformed;
    if (!std.mem.startsWith(u8, f, name)) return error.Malformed;
    return f[name.len..];
}

/// The server's config (`shale.conf`): `public_key = <64 hex>` and
/// `target = <host>`, each once, nothing else.
pub const Config = struct {
    public_key: Ed25519.PublicKey,
    target: []const u8,
};

pub fn parseConfig(text: []const u8) error{BadConfig}!Config {
    var key: ?Ed25519.PublicKey = null;
    var target: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadConfig;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "public_key")) {
            if (key != null or v.len != 2 * Ed25519.PublicKey.encoded_length) return error.BadConfig;
            var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, v) catch return error.BadConfig;
            key = Ed25519.PublicKey.fromBytes(bytes) catch return error.BadConfig;
        } else if (std.mem.eql(u8, k, "target")) {
            if (target != null or !validTarget(v)) return error.BadConfig;
            target = v;
        } else return error.BadConfig;
    }
    return .{ .public_key = key orelse return error.BadConfig, .target = target orelse return error.BadConfig };
}

/// Where the route keeps what it keeps: under the auth root, which a
/// script cannot reach.
pub const Paths = struct {
    /// The auth root itself: never inside the data root, nor it inside
    /// this (`handle` refuses), or a script could rewrite its own key.
    root: []const u8,
    config: []const u8,
    sequence: []const u8,
    log: []const u8,
    runs: []const u8,

    pub fn under(alloc: std.mem.Allocator, auth_root: []const u8) !Paths {
        return .{
            .root = auth_root,
            .config = try std.fs.path.join(alloc, &.{ auth_root, "shale.conf" }),
            .sequence = try std.fs.path.join(alloc, &.{ auth_root, "shale", "sequence" }),
            .log = try std.fs.path.join(alloc, &.{ auth_root, "shale", "log" }),
            .runs = try std.fs.path.join(alloc, &.{ auth_root, "shale", "runs" }),
        };
    }
};

pub const Request = struct {
    paths: Paths,
    /// The folder a script's paths are confined to: the data root.
    data_root: []const u8,
    budgets: script.Budgets,
    /// Unix seconds, the host's clock: the expiry is judged by it, and it
    /// is what the script's `now()` answers.
    now: i64,
    /// Where the script's `print` goes: its output budget is at most this.
    out: []u8,
};

pub const Ran = struct {
    sequence: u64,
    sha256: [Sha256.digest_length]u8,
    result: script.Result,
    /// Null when the run's end was logged; the store's error otherwise.
    log_failed: ?anyerror,

    /// Whether any effect was tried: the store may have changed.
    pub fn changedStore(r: *const Ran) bool {
        return r.result.effects.len > 0;
    }
};

pub const Outcome = union(enum) {
    refused: struct { why: Refusal, detail: []const u8 },
    ran: Ran,

    pub fn deinit(o: *Outcome) void {
        switch (o.*) {
            .ran => |*r| r.result.deinit(),
            .refused => {},
        }
    }

    /// The reply's status: a run is 200 however it ended, 500 when its end
    /// went unlogged.
    pub fn status(o: *const Outcome) std.http.Status {
        return switch (o.*) {
            .refused => |r| r.why.status(),
            .ran => |r| if (r.log_failed != null) .internal_server_error else .ok,
        };
    }
};

/// **THE WHOLE ROUTE BUT THE BEARER AND THE ANSWER**: refused, or run.
/// `alloc` is the request's (the detail strings live there); the run's own
/// memory is its result's arena, given back by `Outcome.deinit`.
pub fn handle(io: Io, alloc: std.mem.Allocator, body: []const u8, req: Request) !Outcome {
    if (try nested(alloc, req.data_root, req.paths.root))
        return refuse(.bad_config, "the auth root and the data root nest: a script could rewrite the key or the sequence");
    const env = parse(body) catch return refuse(.malformed, "the body is not a shale-1 envelope (shale-signature line, shale-1 line, script)");
    // absent-ok: a config that cannot be read refuses (bad_config), never runs.
    const conf_text = (store.readOrNull(io, alloc, req.paths.config, .limited(4096)) catch |e|
        return refuse(.bad_config, try std.fmt.allocPrint(alloc, "the script config cannot be read: {s}", .{@errorName(e)}))) orelse
        return refuse(.no_key, "no public key is configured: the route is off");
    const conf = parseConfig(conf_text) catch return refuse(.bad_config, "the script config is not `public_key = <64 hex>` and `target = <host>`");
    const sig = Ed25519.Signature.fromBytes(env.signature);
    sig.verify(env.signed, conf.public_key) catch return refuse(.bad_signature, "the signature is not the configured key's over this request");
    if (!std.mem.eql(u8, env.target, conf.target))
        return refuse(.wrong_target, try std.fmt.allocPrint(alloc, "signed for {s}; this is {s}", .{ env.target, conf.target }));
    if (req.now > env.expires)
        return refuse(.expired, try std.fmt.allocPrint(alloc, "expired at {d}; it is {d}", .{ env.expires, req.now }));
    if (env.expires - req.now > max_ahead_s)
        return refuse(.expires_too_far, try std.fmt.allocPrint(alloc, "expires {d} s from now, past the {d} s allowed", .{ env.expires - req.now, max_ahead_s }));
    // absent-ok: a sequence that cannot be read refuses (sequence_unreadable), never runs.
    const last = lastSequence(io, alloc, req.paths.sequence) catch |e|
        return refuse(.sequence_unreadable, try std.fmt.allocPrint(alloc, "the last sequence number cannot be read: {s}", .{@errorName(e)}));
    if (env.sequence <= last)
        return refuse(.replayed, try std.fmt.allocPrint(alloc, "sequence {d} is not past the last one run, {d}", .{ env.sequence, last }));

    var sha: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(env.source, &sha, .{});
    // **RECORDED, DURABLY, BEFORE IT RUNS**: a crash mid-run cannot let the
    // same signed request run twice.
    record(io, alloc, req, env, sha) catch |e|
        return refuse(.not_recorded, try std.fmt.allocPrint(alloc, "sequence {d} could not be recorded durably ({s}): not run", .{ env.sequence, @errorName(e) }));

    const result = script.run(io, alloc, req.data_root, env.source, req.budgets, req.now, req.out);
    var ran: Ran = .{ .sequence = env.sequence, .sha256 = sha, .result = result, .log_failed = null };
    logEnd(io, alloc, req, &ran) catch |e| {
        ran.log_failed = e;
    };
    return .{ .ran = ran };
}

fn refuse(why: Refusal, detail: []const u8) Outcome {
    return .{ .refused = .{ .why = why, .detail = detail } };
}

/// The last sequence number accepted. **A MISSING FILE IS AN ERROR, NOT
/// 0**: `installKey` writes it with the key, so one missing beside a key
/// was lost, and reading it as 0 would run again every signed request
/// still unexpired.
pub fn lastSequence(io: Io, alloc: std.mem.Allocator, path: []const u8) !u64 {
    const text = (try store.readOrNull(io, alloc, path, .limited(64))) orelse return error.NoSequenceFile;
    return std.fmt.parseInt(u64, std.mem.trimEnd(u8, text, "\n"), 10) catch error.BadSequenceFile;
}

/// **THE ONE WAY A KEY IS SET**: the sequence first, at least `floor` (the
/// clock's seconds: the signer numbers from them, so nothing signed before
/// now runs after) and never lower than it was, then the config. A key set
/// again after the sequence was lost reopens nothing.
pub fn installKey(io: Io, alloc: std.mem.Allocator, paths: Paths, config_text: []const u8, floor: u64) !void {
    _ = try parseConfig(config_text);
    const was: u64 = lastSequence(io, alloc, paths.sequence) catch |e| switch (e) {
        error.NoSequenceFile => 0,
        else => return e,
    };
    try store.replace(io, alloc, paths.sequence, try std.fmt.allocPrint(alloc, "{d}\n", .{@max(was, floor)}), .{});
    try store.replace(io, alloc, paths.config, config_text, .{ .private = true });
}

/// Whether one of two folders is the other or inside it, by their
/// resolved spellings (a symlink is not followed: neither host's roots
/// are links).
pub fn nested(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ra = try std.fs.path.resolve(alloc, &.{a});
    const rb = try std.fs.path.resolve(alloc, &.{b});
    return within(ra, rb) or within(rb, ra);
}

fn within(inner: []const u8, outer: []const u8) bool {
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '/' or std.mem.endsWith(u8, outer, "/");
}

fn record(io: Io, alloc: std.mem.Allocator, req: Request, env: Envelope, sha: [Sha256.digest_length]u8) !void {
    try store.replace(io, alloc, req.paths.sequence, try std.fmt.allocPrint(alloc, "{d}\n", .{env.sequence}), .{});
    const source_path = try std.fs.path.join(alloc, &.{ req.paths.runs, try std.fmt.allocPrint(alloc, "{d}.shale", .{env.sequence}) });
    try store.replace(io, alloc, source_path, env.source, .{});
    const hex = std.fmt.bytesToHex(sha, .lower);
    _ = try store.append(io, alloc, req.paths.log, try std.fmt.allocPrint(alloc, "{d} seq={d} sha256={s} target={s} bytes={d} started\n", .{ req.now, env.sequence, &hex, env.target, env.source.len }));
    if (!store.makeDurable()) return error.NotDurable;
}

/// The run's effects and its end, one append: a line each, every byte of a
/// path a script named that is not printable written as `\xNN`.
fn logEnd(io: Io, alloc: std.mem.Allocator, req: Request, ran: *const Ran) !void {
    var text: std.ArrayList(u8) = .empty;
    const w = &text;
    for (ran.result.effects) |e| {
        try w.print(alloc, "{d} seq={d} effect {s} ", .{ req.now, ran.sequence, e.op });
        try escaped(alloc, w, e.path);
        try w.print(alloc, ": {s}\n", .{e.outcome});
    }
    try w.print(alloc, "{d} seq={d} ", .{ req.now, ran.sequence });
    try ending(alloc, w, &ran.result);
    _ = try store.append(io, alloc, req.paths.log, text.items);
}

fn escaped(alloc: std.mem.Allocator, w: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c >= 0x20 and c < 0x7f and c != '\\') try w.append(alloc, c) else try w.print(alloc, "\\x{x:0>2}", .{c});
    }
}

/// How a run ended, one line: `finished (N steps)`, or `stopped at L:C:
/// class[ budget]: message (N steps)`, as the runner says it.
fn ending(alloc: std.mem.Allocator, w: *std.ArrayList(u8), r: *const script.Result) !void {
    if (r.stop) |s| {
        try w.print(alloc, "stopped at {d}:{d}: {s}{s}{s}: ", .{ s.line, s.column, @tagName(s.class), if (s.budget != null) " " else "", if (s.budget) |b| @tagName(b) else "" });
        try escaped(alloc, w, s.message);
        try w.print(alloc, " ({d} steps)\n", .{r.steps});
    } else try w.print(alloc, "finished ({d} steps)\n", .{r.steps});
}

/// **THE REPLY'S BODY**: the reason, for a refusal; for a run, what it
/// printed, then `script.report` (its effects and how it ended), as the
/// Linux runner prints them, under the sequence number, and a log that
/// failed said first and last.
pub fn writeReply(o: *const Outcome, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (o.*) {
        .refused => |r| try w.print("refused ({s}): {s}\nnot run\n", .{ @tagName(r.why), r.detail }),
        .ran => |r| {
            if (r.log_failed) |e| try w.print("── THE LOG WAS NOT WRITTEN ({s}): this run is on the store's sequence and source, not its log ──\n", .{@errorName(e)});
            try w.writeAll(r.result.output);
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "seq {d}", .{r.sequence}) catch "script";
            try script.report(&r.result, name, w);
            if (r.log_failed) |e| try w.print("── THE LOG WAS NOT WRITTEN ({s}) ──\n", .{@errorName(e)});
        },
    }
}
