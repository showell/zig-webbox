//! **SEVERAL APPLICATIONS, ONE SITE**: a primary application, which keeps `/`
//! and everything not mounted, and others mounted beside it under their own
//! prefix, each seeing itself at `/`. The result is a hosted root (`site`,
//! `hosting`), the shape every application already gives its hosts, so a
//! host serves a combination as it serves one application.
//!
//!     pub const site = combo.site;
//!     pub const hosting = combo.hosting;
//!     const combo = webbox.combo.Mount(gopher, &.{
//!         .{ .prefix = "/codex-chat", .root = codex_chat },
//!         .{ .prefix = "/uo", .root = uo_town },
//!     });
//!
//! A part is a hosted root (it exports `site`, a `Site`, and may export
//! `hosting`) or an application's table itself (`routes`, `setup`, ...).
//!
//! - **Routes**: the mounts first, so the primary cannot shadow one; a bare
//!   prefix is sent to it with a slash (`/todo` to `/todo/`, the query
//!   kept); otherwise the prefix comes off the target before the mount's
//!   routes see it. A mount's pages use relative URLs.
//! - **Files**: a mount is set up with `<data>/<name>` and `<auth>/<name>`,
//!   its name the prefix's segment, so what it keeps cannot meet another's;
//!   its first write makes them, not the setup. The primary keeps the
//!   host's roots.
//! - **Families, body limits, uploaders**: by path, to the part it reaches. A
//!   mount with no families of its own counts under its name.
//! - **Between requests**: every part, in its own shape, on one bus: any part
//!   with more makes it more; otherwise the earliest wake; otherwise idle.
//! - **Hosting**: the primary's names; the largest of the parts' sizes; the
//!   primary's start lines, then each mount's under its prefix.
//!
//! Not here: rewriting a page's URLs, separating bus keys (each mount keys
//! its streams by its own name), mounts within mounts.

const std = @import("std");
const Io = @import("host_io").Io;
const http = @import("http.zig");
const bus = @import("bus.zig");
const site_mod = @import("site.zig");

/// A mounted application: its prefix (`/name`, one segment of `[a-z0-9-]`,
/// which also names its folders) and its root.
pub const Piggyback = struct {
    prefix: []const u8,
    root: type,
};

/// An application's table, from a hosted root or the table itself.
fn tableOf(comptime root: type) type {
    return if (@hasDecl(root, "site")) root.site.Application else root;
}

/// What a part says to its host about itself: its `hosting`, or none.
fn hostingOf(comptime root: type) type {
    return if (@hasDecl(root, "hosting")) root.hosting else struct {};
}

fn nameOf(comptime m: Piggyback) []const u8 {
    return m.prefix[1..];
}

fn checkPrefixes(comptime mounts: []const Piggyback) void {
    for (mounts, 0..) |m, i| {
        if (m.prefix.len < 2 or m.prefix[0] != '/') @compileError("a mount's prefix is /name: " ++ m.prefix);
        for (m.prefix[1..]) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-'))
            @compileError("a mount's prefix is one segment of [a-z0-9-]: " ++ m.prefix);
        for (mounts[0..i]) |o| if (std.mem.eql(u8, o.prefix, m.prefix)) @compileError("two mounts at " ++ m.prefix);
    }
}

pub fn Mount(comptime Primary: type, comptime mounts: []const Piggyback) type {
    comptime checkPrefixes(mounts);
    const P = tableOf(Primary);
    const PH = hostingOf(Primary);

    const report_types = blk: {
        var ts: [mounts.len]type = undefined;
        for (mounts, 0..) |m, i| ts[i] = tableOf(m.root).StartReport;
        break :blk ts;
    };
    const MountReports = @Tuple(&report_types);

    const App = struct {
        pub const StartReport = struct { primary: P.StartReport, mounts: MountReports };

        pub fn setup(io: Io, base: std.mem.Allocator, roots: ?site_mod.Roots) !StartReport {
            var out: StartReport = .{ .primary = try P.setup(io, base, roots), .mounts = undefined };
            // Each mount's folders are made by its first write (the store's
            // writes make their parents), never here: a setup that wrote
            // stops the machine when its volume refuses the write, where a
            // request's write fails only that request.
            inline for (mounts, 0..) |m, i| {
                const data = try std.fmt.allocPrint(base, "{s}/{s}", .{ if (roots) |r| r.data_dir else "data", nameOf(m) });
                const auth = try std.fmt.allocPrint(base, "{s}/{s}", .{ if (roots) |r| r.auth_dir else "auth", nameOf(m) });
                out.mounts[i] = try tableOf(m.root).setup(io, base, .{ .data_dir = data, .auth_dir = auth });
            }
            return out;
        }

        pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, b: *bus.Bus) !void {
            const target = try http.target(req, alloc);
            const path = http.pathOf(target);
            inline for (mounts) |m| {
                if (http.pathUnder(path, m.prefix)) |sub| {
                    // The bare prefix: to the mount's own `/`, its query kept.
                    if (sub.len == 0) return http.redirect(req, try http.Target.format(alloc, "{s}/{s}", .{ m.prefix, target[path.len..] }));
                    const whole = http.stripTarget(req, m.prefix.len);
                    defer http.restoreTarget(req, whole);
                    return tableOf(m.root).routes(req, io, alloc, b);
                }
            }
            return P.routes(req, io, alloc, b);
        }

        pub fn bodyLimit(path: []const u8) u64 {
            inline for (mounts) |m| if (http.pathUnder(path, m.prefix)) |sub| return tableOf(m.root).bodyLimit(sub);
            return P.bodyLimit(path);
        }

        pub fn uploader(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !?[]const u8 {
            const target = try http.target(req, alloc);
            inline for (mounts) |m| if (http.pathUnder(http.pathOf(target), m.prefix) != null) {
                const M = tableOf(m.root);
                if (!@hasDecl(M, "uploader")) return null;
                const whole = http.stripTarget(req, m.prefix.len);
                defer http.restoreTarget(req, whole);
                return M.uploader(req, io, alloc);
            };
            return if (@hasDecl(P, "uploader")) P.uploader(req, io, alloc) else null;
        }

        pub fn family(path: []const u8) []const u8 {
            inline for (mounts) |m| if (http.pathUnder(path, m.prefix)) |sub| {
                const M = tableOf(m.root);
                if (!@hasDecl(M, "family")) return comptime nameOf(m);
                const f = M.family(if (sub.len == 0) "/" else sub);
                return if (@TypeOf(f) == []const u8) f else @tagName(f);
            };
            if (!@hasDecl(P, "family")) return "all";
            const f = P.family(path);
            return if (@TypeOf(f) == []const u8) f else @tagName(f);
        }

        pub fn between(io: Io, now: site_mod.Now, b: *bus.Bus) site_mod.Wake {
            var wake = site_mod.betweenOf(P, io, now, b.hub);
            inline for (mounts) |m| wake = sooner(wake, site_mod.betweenOf(tableOf(m.root), io, now, b.hub));
            return wake;
        }
    };

    return struct {
        pub const site = site_mod.Site(App);
        pub const hosting = struct {
            pub const name = if (@hasDecl(PH, "name")) PH.name else "the site";
            pub const data_name = if (@hasDecl(PH, "data_name")) PH.data_name else "the site's data";
            pub const whole_read_max = largest("whole_read_max");
            pub const cache_largest_most = largest("cache_largest_most");

            /// The primary's lines, then each mount's under its prefix.
            pub fn describeStart(r: App.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
                if (@hasDecl(PH, "describeStart")) try PH.describeStart(r.primary, w);
                inline for (mounts, 0..) |m, i| {
                    const MH = hostingOf(m.root);
                    if (@hasDecl(MH, "describeStart")) {
                        var buf: [512]u8 = undefined;
                        var lines: std.Io.Writer = .fixed(&buf);
                        try MH.describeStart(r.mounts[i], &lines);
                        var each = std.mem.splitScalar(u8, std.mem.trimEnd(u8, lines.buffered(), "\n"), '\n');
                        while (each.next()) |line| try w.print("{s}: {s}\n", .{ m.prefix, line });
                    } else try w.print("{s}: started\n", .{m.prefix});
                }
            }

            fn largest(comptime decl: []const u8) usize {
                var most: usize = if (@hasDecl(PH, decl)) @field(PH, decl) else 0;
                for (mounts) |m| {
                    const MH = hostingOf(m.root);
                    if (@hasDecl(MH, decl)) most = @max(most, @field(MH, decl));
                }
                return most;
            }
        };
    };
}

/// Two parts' wakes as one: more if either has more, else the earlier time,
/// else idle.
fn sooner(a: site_mod.Wake, b: site_mod.Wake) site_mod.Wake {
    return switch (a) {
        .more => .more,
        .idle => b,
        .at => |ta| switch (b) {
            .more => .more,
            .idle => a,
            .at => |tb| .{ .at = @min(ta, tb) },
        },
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Toy parts: each answers with its name and the target it was handed.
fn Toy(comptime label: []const u8, comptime limit: u64, comptime wake: site_mod.Wake) type {
    return struct {
        pub const StartReport = struct { data: []const u8, auth: []const u8 };
        pub fn setup(_: Io, _: std.mem.Allocator, roots: ?site_mod.Roots) !StartReport {
            return .{ .data = roots.?.data_dir, .auth = roots.?.auth_dir };
        }
        pub fn bodyLimit(_: []const u8) u64 {
            return limit;
        }
        pub fn routes(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, _: *bus.Bus) !void {
            return req.respond(try std.fmt.allocPrint(alloc, "{s} {s}", .{ label, try http.target(req, alloc) }), .{ .keep_alive = false });
        }
        pub fn between(_: Io, _: site_mod.Now) site_mod.Wake {
            return wake;
        }
    };
}
const ToyPrimary = Toy("primary", 10, .idle);
const Todo = struct {
    pub const site = site_mod.Site(Toy("todo", 20, .{ .at = 7 }));
    pub const hosting = struct {
        pub const whole_read_max = 99;
        pub fn describeStart(r: Toy("todo", 20, .{ .at = 7 }).StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("its list in {s}\n", .{r.data});
        }
    };
};
const Chat = struct {
    const T = Toy("chat", 30, .{ .at = 3 });
    pub const StartReport = T.StartReport;
    pub const setup = T.setup;
    pub const bodyLimit = T.bodyLimit;
    pub const routes = T.routes;
    pub const between = T.between;
    pub const Family = enum { streams, chat };
    pub fn family(path: []const u8) Family {
        return if (std.mem.eql(u8, path, "/events")) .streams else .chat;
    }
};
const Both = Mount(struct {
    pub const site = site_mod.Site(ToyPrimary);
    pub const hosting = struct {
        pub const data_name = "the primary's data";
        pub const whole_read_max = 50;
    };
}, &.{ .{ .prefix = "/todo", .root = Todo }, .{ .prefix = "/chat", .root = Chat } });

/// The answer `Both` gives `target`: its status line and body.
fn ask(alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader: std.Io.Reader = .fixed(try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{target}));
    var server = std.http.Server.init(&reader, &out.writer);
    var req = try server.receiveHead();
    req.head.keep_alive = false;
    var hub = bus.Hub.init(testing.io, testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    var b = bus.Bus.of(&hub);
    try Both.site.Application.routes(&req, testing.io, alloc, &b);
    try out.writer.flush();
    const head_end = std.mem.indexOf(u8, out.written(), "\r\n").?;
    const body_at = std.mem.indexOf(u8, out.written(), "\r\n\r\n").? + 4;
    const location = if (std.mem.indexOf(u8, out.written(), "location: ")) |at| out.written()[at + 10 ..][0..std.mem.indexOf(u8, out.written()[at + 10 ..], "\r\n").?] else "";
    return std.fmt.allocPrint(alloc, "{s}|{s}|{s}", .{ out.written()[0..head_end], location, out.written()[body_at..] });
}

test "combo: a mount sees itself at /, the primary keeps the rest, a bare prefix gains its slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("HTTP/1.1 200 OK||todo /api/todos?x=1", try ask(a, "/todo/api/todos?x=1"));
    try testing.expectEqualStrings("HTTP/1.1 200 OK||chat /", try ask(a, "/chat/"));
    try testing.expectEqualStrings("HTTP/1.1 200 OK||primary /", try ask(a, "/"));
    // Not a mount: a name that only begins like one.
    try testing.expectEqualStrings("HTTP/1.1 200 OK||primary /todolist", try ask(a, "/todolist"));
    try testing.expect(std.mem.startsWith(u8, try ask(a, "/todo?x=1"), "HTTP/1.1 303 See Other|/todo/?x=1|"));
}

test "combo: body limits and families by path; a mount with no families counts under its name" {
    const A = Both.site.Application;
    try testing.expectEqual(@as(u64, 20), A.bodyLimit("/todo/api/todos"));
    try testing.expectEqual(@as(u64, 30), A.bodyLimit("/chat/send"));
    try testing.expectEqual(@as(u64, 10), A.bodyLimit("/anything"));
    try testing.expectEqualStrings("todo", A.family("/todo/api/todos"));
    try testing.expectEqualStrings("streams", A.family("/chat/events"));
    try testing.expectEqualStrings("chat", A.family("/chat/send"));
    try testing.expectEqualStrings("all", A.family("/"));
}

test "combo: between asks every part: the earliest wake" {
    var hub = bus.Hub.init(testing.io, testing.allocator);
    defer hub.entries.deinit(testing.allocator);
    var b = bus.Bus.of(&hub);
    try testing.expectEqual(site_mod.Wake{ .at = 3 }, Both.site.Application.between(testing.io, .{ .awake_ns = 0, .unix_s = 0 }, &b));
}

test "combo: each mount set up with its own folders under the host's roots, which setup does not write; hosting composes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const data = try std.fs.path.join(a, &.{ root, "data" });
    const auth = try std.fs.path.join(a, &.{ root, "auth" });
    const r = try Both.site.Application.setup(testing.io, a, .{ .data_dir = data, .auth_dir = auth });
    try testing.expectEqualStrings(data, r.primary.data);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/todo", .{data}), r.mounts[0].data);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/chat", .{auth}), r.mounts[1].auth);
    // Made by a mount's first write, never by setup: a setup write a volume
    // refuses would stop the machine.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "data/todo", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "auth/chat", .{}));

    try testing.expectEqualStrings("the primary's data", Both.hosting.data_name);
    try testing.expectEqual(@as(usize, 99), Both.hosting.whole_read_max);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Both.hosting.describeStart(r, &w);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "/todo: its list in {s}/todo\n/chat: started\n", .{data}), w.buffered());
}

test "combo: wakes combine: more wins, then the earlier time, then idle" {
    try testing.expectEqual(site_mod.Wake.more, sooner(.idle, .more));
    try testing.expectEqual(site_mod.Wake.more, sooner(.{ .at = 5 }, .more));
    try testing.expectEqual(site_mod.Wake{ .at = 3 }, sooner(.{ .at = 5 }, .{ .at = 3 }));
    try testing.expectEqual(site_mod.Wake{ .at = 5 }, sooner(.{ .at = 5 }, .idle));
    try testing.expectEqual(site_mod.Wake.idle, sooner(.idle, .idle));
}
