//! **THE LIBRARY'S NUMBER PARSES THAT NO REQUEST REACHES**, each with why,
//! and **THE ONE READING OF WHERE A NUMBER IS PARSED**. An application checks
//! every place a request carries a number (angry-gopher router.zig's request
//! edges), across its own source and the library's; a library site named here
//! is known without the application listing it, so a change here that adds
//! one says so here, not in each application. A site a request does reach is
//! the application's to cover, with a request. Both that check and this
//! file's test find sites with `parseSites`, so the two cannot read Zig
//! differently.

const std = @import("std");
const Io = @import("host_io").Io;

pub const Site = struct { file: []const u8, func: []const u8, why: []const u8 };

/// Paths are from the library's `src/`.
pub const unreachable_from_requests = [_]Site{
    .{ .file = "script_route.zig", .func = "lastSequence", .why = "a sequence file the server wrote" },
    .{ .file = "shale_sign.zig", .func = "main", .why = "the signer, on the box, not the server" },
    .{ .file = "shale_fixture.zig", .func = "main", .why = "the program Shale's run tests spawn, not the server (zig-webbox, metal-vmm QUEUE 233)" },
    .{ .file = "shale_jobs.zig", .func = "parseRecord", .why = "a job's record its reaper wrote, read by the Linux shale CLI, not the server (zig-webbox, metal-vmm QUEUE 233)" },
    .{ .file = "shale_sign.zig", .func = "lastFor", .why = "the signer, on the box, not the server" },
    .{ .file = "log_view.zig", .func = "requestAt", .why = "the host's own log lines, not a request's" },
    .{ .file = "bus.zig", .func = "keepaliveSetting", .why = "the host's start-up setting, not a request's" },
    .{ .file = "counter.zig", .func = "current", .why = "a counter file the server wrote" },
    .{ .file = "linux_host.zig", .func = "portFrom", .why = "the environment" },
    .{ .file = "linux_fetch.zig", .func = "parseHead", .why = "the answer to the application's own fetch, not a request (zig-webbox, metal-vmm QUEUE 228)" },
    .{ .file = "site_secret.zig", .func = "previous", .why = "a secret file the server wrote" },
    .{ .file = "script/lex.zig", .func = "number", .why = "an integer literal in a script's text, which only the admin's signed script brings (no edge request is signed); errors_test sends it the 64-bit edges" },
    .{ .file = "script/builtins.zig", .func = "parseInteger", .why = "parse_int's text, from a script, which only the admin's signed script brings; builtins_test sends it the edges, past 64 bits among them" },
};

/// Whether a type's `{` comes next: at once (`error{`, `struct {`), or after
/// its argument (`enum(u8) {`, `union(enum) {`). `error.Bad` and a bare
/// `enum` in an expression have none.
fn bodyFollows(after: std.zig.Tokenizer) bool {
    var look = after;
    var t = look.next();
    if (t.tag == .l_brace) return true;
    if (t.tag != .l_paren) return false;
    var open: u32 = 1;
    while (open > 0) {
        t = look.next();
        switch (t.tag) {
            .l_paren => open += 1,
            .r_paren => open -= 1,
            .eof => return false,
            else => {},
        }
    }
    return look.next().tag == .l_brace;
}

/// A place that parses a number: the function it is in ("" at file scope)
/// and its line.
pub const Parse = struct { func: []const u8, line: u32 };

/// **WHERE `text` PARSES A NUMBER**, read with Zig's own tokenizer: each
/// `parseInt` called (`std.fmt.parseInt(` or a bare `parseInt(`), never one in
/// a comment or a string, never the name in `fn parseInt(`; in the innermost
/// function whose body holds it, whatever comes before its `fn` (`pub`,
/// `inline`, `export`); never inside a `test` block.
pub fn parseSites(a: std.mem.Allocator, text: [:0]const u8) ![]const Parse {
    const Frame = struct { name: []const u8, depth: u32, is_test: bool };
    var frames: std.ArrayList(Frame) = .empty;
    var out: std.ArrayList(Parse) = .empty;
    var tok = std.zig.Tokenizer.init(text);
    var depth: u32 = 0;
    var line: u32 = 1;
    var seen: usize = 0; // bytes counted for `line`
    // A body about to open: a function's (its name) or a test's.
    var pending: ?Frame = null;
    var paren: u32 = 0;
    var prev: std.zig.Token.Tag = .invalid;
    // The next `{` is a type's (`error{`, `struct {`, `union(enum) {`), not
    // a body: a function's return type may hold one.
    var type_brace = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        line += @intCast(std.mem.count(u8, text[seen..t.loc.start], "\n"));
        seen = t.loc.start;
        switch (t.tag) {
            .l_paren => paren += 1,
            .r_paren => paren -|= 1,
            .keyword_test => pending = .{ .name = "", .depth = 0, .is_test = true },
            .semicolon => if (pending != null and paren == 0) {
                pending = null; // a declaration with no body (extern)
            },
            .keyword_error, .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque => type_brace = bodyFollows(tok),
            .l_brace => {
                depth += 1;
                if (type_brace) {
                    type_brace = false;
                    try frames.append(a, .{ .name = "", .depth = depth, .is_test = false });
                } else if (pending) |p| if (paren == 0) {
                    try frames.append(a, .{ .name = p.name, .depth = depth, .is_test = p.is_test });
                    pending = null;
                };
            },
            .r_brace => {
                if (frames.items.len > 0 and frames.items[frames.items.len - 1].depth == depth) _ = frames.pop();
                depth -|= 1;
            },
            .identifier => {
                const name = text[t.loc.start..t.loc.end];
                if (prev == .keyword_fn) {
                    pending = .{ .name = name, .depth = 0, .is_test = false };
                    paren = 0;
                } else if (std.mem.eql(u8, name, "parseInt")) {
                    // Called: the next token opens its arguments.
                    var look = tok;
                    if (look.next().tag == .l_paren) {
                        const in_test = for (frames.items) |f| {
                            if (f.is_test) break true;
                        } else false;
                        if (!in_test) {
                            var func: []const u8 = "";
                            var k = frames.items.len;
                            while (k > 0) : (k -= 1) if (!frames.items[k - 1].is_test and frames.items[k - 1].name.len > 0) {
                                func = frames.items[k - 1].name;
                                break;
                            };
                            try out.append(a, .{ .func = func, .line = line });
                        }
                    }
                }
            },
            else => {},
        }
        prev = t.tag;
    }
    return out.toOwnedSlice(a);
}

test "edge_sites: every site named is a function of that name in that file, and parses a number inside it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try Io.Dir.cwd().openDir(io, "src", .{});
    defer src.close(io);
    for (unreachable_from_requests) |s| {
        errdefer std.debug.print("edge_sites: {s}'s {s} parses no number\n", .{ s.file, s.func });
        const text = try src.readFileAllocOptions(io, s.file, a, .limited(4 << 20), .of(u8), 0);
        const sites = try parseSites(a, text);
        const there = for (sites) |p| {
            if (std.mem.eql(u8, p.func, s.func)) break true;
        } else false;
        try std.testing.expect(there);
    }
}

test "edge_sites: parseSites reads Zig as Zig: a comment, a string, a test block and the function's own name are no sites; inline and nested functions are their own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\// parseInt(x) in a comment
        \\const s = "parseInt(";
        \\fn parseInt(t: []const u8) u8 {
        \\    return std.fmt.parseInt(u8, t, 10) catch 0;
        \\}
        \\pub inline fn quick(t: []const u8) u8 {
        \\    const S = struct {
        \\        fn inner(u: []const u8) u8 {
        \\            return std.fmt.parseInt(u8, u, 10) catch 0;
        \\        }
        \\    };
        \\    _ = S;
        \\    return std.fmt.parseInt(u8, t, 10) catch 0;
        \\}
        \\extern fn ext(x: u8) u8;
        \\fn setting(t: []const u8) error{Bad}!u8 {
        \\    return std.fmt.parseInt(u8, t, 10) catch error.Bad;
        \\}
        \\const top = std.fmt.parseInt(u8, "1", 10) catch 0;
        \\test "a test's parse" {
        \\    _ = try std.fmt.parseInt(u8, "1", 10);
        \\}
        \\
    ;
    const sites = try parseSites(arena.allocator(), text);
    const want = [_]Parse{
        .{ .func = "parseInt", .line = 4 },
        .{ .func = "inner", .line = 9 },
        .{ .func = "quick", .line = 13 },
        .{ .func = "setting", .line = 17 },
        .{ .func = "", .line = 19 },
    };
    try std.testing.expectEqual(want.len, sites.len);
    for (want, sites) |w, got| {
        try std.testing.expectEqualStrings(w.func, got.func);
        try std.testing.expectEqual(w.line, got.line);
    }
}
