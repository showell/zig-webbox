//! admin_log: /admin/log, the host's whole log as plain text, for an agent
//! to fetch and grep (metal-vmm QUEUE 189.3; webbox's since QUEUE 221, when
//! Dog Park became its second user). The application checks its admin gate
//! first, as for its other admin pages, and says what it is; GET only,
//! and it changes nothing.
//!
//! /admin/host is the page for a person: a summary, then the newest lines.
//! This is the rest: this boot's log as the host holds it, and the boot
//! before it where the host kept it across a restart, narrowed by the
//! filters log_view.zig reads (`since=`, `until=`, `request=`, `path=`,
//! `boot=`). It opens with header lines, each `# `, saying what it is.

const std = @import("std");
const Io = @import("host_io").Io;
const Alloc = std.mem.Allocator;
const http = @import("http.zig");
const host_facts = @import("host_facts.zig");
const log_view = @import("log_view.zig");
const traffic = @import("traffic.zig");

const Request = std.http.Server.Request;

/// What a wrong filter is told, after "400": what each one takes.
const usage =
    \\The filters: since=2026-10-13T14:02 and until=... (an ISO UTC time, or any
    \\leading part of one, a year at least), request=12 (digits), path=/gopher/chat
    \\(a leading /), boot=this|before|both.
    \\
;

/// render writes the view. The caller has already checked the admin gate;
/// `app` is what the application says of itself in the view's header
/// (angry-gopher: "commit <sha>"; Dog Park: its name and physics hash).
pub fn render(req: *Request, io: Io, alloc: Alloc, app: []const u8) !void {
    if (req.head.method != .GET and req.head.method != .HEAD) {
        return req.respond("Only GET: this view changes nothing.\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{ http.plain_ct, .{ .name = "allow", .value = "GET, HEAD" } },
        });
    }
    const target = try http.target(req, alloc);
    const f = log_view.parseFilter(alloc, target) catch |e| switch (e) {
        error.BadFilter => return req.respond("A filter is spelled wrong. " ++ usage, .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} }),
        else => return e,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    try write(&out.writer, io, alloc, f, app);
    try req.respond(out.written(), .{ .extra_headers = &.{http.plain_ct} });
}

fn write(w: *std.Io.Writer, io: Io, alloc: Alloc, f: log_view.Filter, app: []const u8) !void {
    try w.writeAll("# The host's log, for agents (metal-vmm QUEUE 189.3): lines beginning \"# \" are\n" ++
        "# this header; the rest is the log as written, its secrets taken out then.\n");
    try w.print("# the application: {s}\n", .{app});
    // The counts an agent would grep for (189.5), every 5xx first.
    const t = &traffic.global;
    try w.writeAll("# requests since boot: ");
    try t.writeClasses(w);
    try w.writeAll("\n# by part of the site: ");
    try t.writeFamilies(w);
    try w.writeByte('\n');
    var k: usize = 0;
    while (t.newestError(k)) |e| : (k += 1) {
        try w.writeAll("# 5xx: ");
        try traffic.writeSeen(e, w);
        try w.writeByte('\n');
    }
    for (t.slowest[0..t.n_slowest]) |*one| {
        try w.writeAll("# slow: ");
        try traffic.writeSeen(one, w);
        try w.writeByte('\n');
    }
    const logs = (try host_facts.allLogs(io, alloc)) orelse {
        try w.writeAll("# This host keeps no log of its own to show here.\n");
        return;
    };
    if (logs.host_commit) |c| try w.print("# the host: commit {s}\n", .{c});
    if (logs.booted_unix) |b| try w.print("# booted {s}\n", .{try host_facts.utc(alloc, b)});
    try w.print("# filters: since={s} until={s} request={?d} path={s} boot={t}\n", .{
        f.since orelse "-", f.until orelse "-", f.request, f.path orelse "-", f.boot,
    });
    if (f.boot != .before) {
        var body: std.Io.Writer.Allocating = .init(alloc);
        const c = try log_view.writeLines(&body.writer, logs.this_boot, f);
        try w.print("# this boot: {d} bytes in {d} lines held, of {d} kept at most; {d} written before them and no longer held; the oldest timed line {s}; {d} lines below\n", .{
            logs.this_boot.len, c.lines, logs.capacity, logs.lost, c.oldest orelse "(none)", c.kept,
        });
        try w.writeAll(body.written());
    }
    if (f.boot != .this) {
        if (logs.before) |b| {
            var body: std.Io.Writer.Allocating = .init(alloc);
            const c = try log_view.writeLines(&body.writer, b.text, f);
            try w.print("# the boot before (boot {d}, kept across its restart): {d} bytes in {d} lines; the oldest timed line {s}; {d} lines below\n", .{
                b.boot, b.text.len, c.lines, c.oldest orelse "(none)", c.kept,
            });
            try w.writeAll(body.written());
        } else try w.writeAll("# the boot before: none kept (a first boot, or one that did not end on purpose)\n");
    }
}
