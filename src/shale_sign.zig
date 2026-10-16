//! **THE SHALE SIGNER, FOR THE BOX** (metal-vmm QUEUE 200): makes the key
//! pair once, and signs a `.shale` file for a target with the next
//! sequence number, writing the request's body beside it and printing the
//! one line that sends it. The private key never leaves this program, and
//! this program never prints it.
//!
//!     zig build shale-sign -- keygen [target]
//!         makes ~/.shale_signing_key (mode 600), or a target's own key,
//!         ~/.shale_signing_key.<target>, and prints the line for the
//!         server's shale.conf; refuses if the key is already there
//!     zig build shale-sign -- pubkey [target]
//!         prints that line again
//!     zig build shale-sign -- sign <file.shale> <target> [minutes]
//!         writes <file.shale>.<sequence>.req, the signed body, good for
//!         `minutes` (default 10), and prints the curl line that sends it
//!     zig build shale-sign -- background <file.shale> <target> [minutes]
//!         the same, as a `mode=background` run: it only reads, a slice at
//!         a time between requests, and is answered with its number
//!     zig build shale-sign -- kill <target> [minutes]
//!         a signed `mode=kill`, ending the background run going: written to
//!         kill.<sequence>.req
//!
//! **THE NEXT SEQUENCE NUMBER** is one past the last this program signed
//! for the target (~/.shale_sequences, a line per target), and never less
//! than the clock's seconds: a lost file or a second machine still signs
//! a number past every one before it, as long as no two are signed for one
//! target in the same second from two places.
//!
//! **ONE KEY PER SITE, WHEN IT HAS ITS OWN**: signing for a target uses
//! ~/.shale_signing_key.<target> when that file is there (Dog Park's, say,
//! never lynrummy's), else ~/.shale_signing_key. A server holding another
//! key's public half refuses the signature, so the wrong key never runs.
//!
//! The key file holds the 32-byte seed, as hex: a key file that anyone but
//! its owner may read is refused, not used.

const std = @import("std");
const webbox = @import("webbox");
const route = webbox.script_route;
const Ed25519 = std.crypto.sign.Ed25519;

const key_name = ".shale_signing_key";
const sequences_name = ".shale_sequences";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const out = &ow.interface;
    defer out.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &err_buf);
    const err = &ew.interface;
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse {
        try err.writeAll("shale-sign: HOME is not set\n");
        return 2;
    };
    const key_path = try std.fs.path.join(arena, &.{ home, key_name });
    const seq_path = try std.fs.path.join(arena, &.{ home, sequences_name });
    if (args.len == 2 or args.len == 3) {
        const own = if (args.len == 3) (try targetKey(arena, home, args[2], err)) orelse return 2 else key_path;
        if (std.mem.eql(u8, args[1], "keygen")) return keygen(io, own, out, err);
        if (std.mem.eql(u8, args[1], "pubkey")) {
            const kp = loadKey(io, arena, own, err) catch return 2;
            try printConfig(kp.public_key, out);
            return 0;
        }
    }
    const signing: ?route.Mode = if (args.len >= 2) (if (std.mem.eql(u8, args[1], "sign")) route.Mode.atomic else if (std.mem.eql(u8, args[1], "background")) route.Mode.background else if (std.mem.eql(u8, args[1], "kill")) route.Mode.kill else null) else null;
    if (signing) |mode| {
        // A kill names no file: its script is empty.
        const fixed: usize = if (mode == .kill) 3 else 4;
        if (args.len == fixed or args.len == fixed + 1) {
            const minutes: i64 = if (args.len == fixed + 1) std.fmt.parseInt(i64, args[fixed], 10) catch {
                try err.print("shale-sign: {s} is not a number of minutes\n", .{args[fixed]});
                return 2;
            } else 10;
            if (minutes < 1 or minutes * 60 > route.max_ahead_s) {
                try err.print("shale-sign: an expiry of 1 to {d} minutes\n", .{@divFloor(route.max_ahead_s, 60)});
                return 2;
            }
            const file = if (mode == .kill) "" else args[2];
            const target = if (mode == .kill) args[2] else args[3];
            const own = (try targetKey(arena, home, target, err)) orelse return 2;
            const which = if (fileExists(io, own)) own else key_path;
            return sign(io, arena, which, seq_path, file, target, minutes, mode, out, err);
        }
    }
    try err.writeAll("usage: shale-sign keygen [target] | pubkey [target] | sign <file.shale> <target> [minutes] | background <file.shale> <target> [minutes] | kill <target> [minutes]\n");
    return 2;
}

/// A target's own key file, ~/.shale_signing_key.<target>; null (said) for
/// a target that isn't a host name.
fn targetKey(arena: std.mem.Allocator, home: []const u8, target: []const u8, err: *std.Io.Writer) !?[]const u8 {
    if (!route.validTarget(target)) {
        try err.print("shale-sign: {s} is not a host name (a-z 0-9 . -)\n", .{target});
        return null;
    }
    return try std.fs.path.join(arena, &.{ home, try std.fmt.allocPrint(arena, "{s}.{s}", .{ key_name, target }) });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn keygen(io: std.Io, key_path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const kp = Ed25519.KeyPair.generate(io);
    const file = std.Io.Dir.cwd().createFile(io, key_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            try err.print("shale-sign: {s} is already there; it is not replaced (remove it yourself to make a new pair, and change the server's shale.conf)\n", .{key_path});
            return 2;
        },
        else => return e,
    };
    defer file.close(io);
    const hex = std.fmt.bytesToHex(kp.secret_key.seed(), .lower);
    var buf: [128]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("{s}\n", .{&hex});
    try w.interface.flush();
    try err.print("shale-sign: the private key is in {s} (mode 600). Put this in the server's shale.conf, with its target:\n", .{key_path});
    try printConfig(kp.public_key, out);
    return 0;
}

fn printConfig(key: Ed25519.PublicKey, out: *std.Io.Writer) !void {
    const hex = std.fmt.bytesToHex(key.toBytes(), .lower);
    try out.print("public_key = {s}\n", .{&hex});
}

fn loadKey(io: std.Io, arena: std.mem.Allocator, key_path: []const u8, err: *std.Io.Writer) !Ed25519.KeyPair {
    const file = std.Io.Dir.cwd().openFile(io, key_path, .{}) catch |e| {
        try err.print("shale-sign: cannot open {s}: {s} (make it with `keygen`)\n", .{ key_path, @errorName(e) });
        return e;
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.permissions.toMode() & 0o077 != 0) {
        try err.print("shale-sign: {s} may be read by others (mode {o}); chmod 600 it first\n", .{ key_path, st.permissions.toMode() & 0o777 });
        return error.KeyFileOpen;
    }
    var buf: [128]u8 = undefined;
    var r = file.reader(io, &buf);
    const text = try r.interface.allocRemaining(arena, .limited(256));
    const hex = std.mem.trim(u8, text, " \n\r\t");
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    if (hex.len != 2 * seed.len) {
        try err.print("shale-sign: {s} is not a key this program made\n", .{key_path});
        return error.BadKeyFile;
    }
    _ = std.fmt.hexToBytes(&seed, hex) catch {
        try err.print("shale-sign: {s} is not a key this program made\n", .{key_path});
        return error.BadKeyFile;
    };
    return Ed25519.KeyPair.generateDeterministic(seed);
}

fn sign(io: std.Io, arena: std.mem.Allocator, key_path: []const u8, seq_path: []const u8, file_path: []const u8, target: []const u8, minutes: i64, mode: route.Mode, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (!route.validTarget(target)) {
        try err.print("shale-sign: {s} is not a host name (a-z 0-9 . -)\n", .{target});
        return 2;
    }
    const kp = loadKey(io, arena, key_path, err) catch return 2;
    const source = if (mode == .kill) "" else std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(webbox.script.Budgets.default_source_bytes + 1)) catch |e| {
        try err.print("shale-sign: cannot read {s}: {s}\n", .{ file_path, @errorName(e) });
        return 2;
    };
    if (source.len > webbox.script.Budgets.default_source_bytes) {
        try err.print("shale-sign: {s} is past the {d} bytes a script may be\n", .{ file_path, webbox.script.Budgets.default_source_bytes });
        return 2;
    }
    const now: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const seqs = std.Io.Dir.cwd().readFileAlloc(io, seq_path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const last = lastFor(seqs, target);
    const sequence: u64 = @max(last + 1, @as(u64, @intCast(now)));
    const expires = now + minutes * 60;

    const signed = try route.signedBytesIn(arena, target, sequence, expires, mode, source);
    const sig = try kp.sign(signed, null);
    const body = try route.envelope(arena, sig.toBytes(), signed);
    // The number is kept before the request leaves: one signed and never
    // sent is a number spent, never one signed twice.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = seq_path, .data = try withSequence(arena, seqs, target, sequence) });
    const req_path = try std.fmt.allocPrint(arena, "{s}.{d}.req", .{ if (mode == .kill) "kill" else file_path, sequence });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = req_path, .data = body });
    try err.print("shale-sign: {s} for {s} ({t}), signed with {s}, sequence {d}, good until {d} ({d} minutes): {s}\n", .{ if (mode == .kill) "a kill" else file_path, target, mode, std.fs.path.basename(key_path), sequence, expires, minutes, req_path });
    try out.print("curl -sS --fail-with-body -H \"Authorization: Bearer $SHALE_ADMIN_KEY\" --data-binary @{s} https://{s}/admin/script\n", .{ req_path, target });
    return 0;
}

/// The last number signed for `target` in the sequences file's text.
fn lastFor(text: []const u8, target: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[0..sp], target)) continue;
        return std.fmt.parseInt(u64, line[sp + 1 ..], 10) catch 0;
    }
    return 0;
}

/// The sequences file with `target`'s line set to `sequence`.
fn withSequence(alloc: std.mem.Allocator, text: []const u8, target: []const u8, sequence: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..sp], target)) continue;
        try out.print(alloc, "{s}\n", .{line});
    }
    try out.print(alloc, "{s} {d}\n", .{ target, sequence });
    return out.toOwnedSlice(alloc);
}

test "the sequences file: a target's line read, replaced, the others kept" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), lastFor("", "x.com"));
    const t = try withSequence(a, "a.com 5\nx.com 9\n", "x.com", 12);
    defer a.free(t);
    try std.testing.expectEqualStrings("a.com 5\nx.com 12\n", t);
    try std.testing.expectEqual(@as(u64, 12), lastFor(t, "x.com"));
    try std.testing.expectEqual(@as(u64, 5), lastFor(t, "a.com"));
}
