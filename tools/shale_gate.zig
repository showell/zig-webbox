//! **SHALE-GATE** (metal-vmm QUEUE 233, chunk 5; the dogfood design's
//! "Making the ban real"): the PreToolUse hook on Bash and Monitor that
//! holds Claude to Shale. It reads the hook's JSON on stdin and passes
//! (exit 0) exactly:
//!
//!   - **the launch:** optionally `cd WORD && `, then `shale` (or an
//!     absolute path ending `/shale`) and its words (`--write`,
//!     `--verbose`, `--budget N=V`, a FILE, `NAME=VALUE`), each plain (no
//!     quotes, `$`, backticks, `;|&<>()*?`, `\`), and optionally `<<'TAG'`
//!     ending the first line (TAG `[A-Z_]+`), a body, and a last line that
//!     is `TAG` (trailing spaces allowed) and that no other line is;
//!   - **the escape:** a first line `# want: <tag>: <text>` or
//!     `# out-of-scope: <tag>: <text>` (tag `[a-z0-9-]+`), run and logged
//!     to `~/.local/state/shale/wants.tsv` with one append;
//!   - **a subagent's call** (its input carries an `agent_id`): local cold
//!     agents are exempt (Steve, 2026-10-17);
//!   - any tool but Bash and Monitor (the hook's matcher names those two).
//!
//! Anything else is refused (exit 2), with one line naming both forms.
//! `tools/shale-gate.sh` runs it and turns any other failure, a missing
//! binary included, into a refusal. Steve installs the hook.

const std = @import("std");
const linux = std.os.linux;

pub const Escape = struct { kind: []const u8, tag: []const u8, text: []const u8 };
pub const Verdict = union(enum) { launch, escape: Escape, refused: []const u8 };

/// The two forms, as every refusal names them.
pub const forms = "a launch, `shale [--write] [--verbose] [FILE] [NAME=VALUE]... <<'TAG'` (after `cd DIR && ` if wanted; the script on stdin, the last line `TAG`), or the escape, a first line `# want: <tag>: <text>` or `# out-of-scope: <tag>: <text>`";

var why_buf: [1024]u8 = undefined;

fn refuse(comptime fmt: []const u8, args: anytype) Verdict {
    return .{ .refused = std.fmt.bufPrint(&why_buf, "shale-gate: " ++ fmt ++ "only " ++ forms, args) catch "shale-gate: refused: only " ++ forms };
}

/// **WHAT A COMMAND IS**: a launch, an escape, or refused (and why).
pub fn classify(cmd: []const u8) Verdict {
    const nl = std.mem.indexOfScalar(u8, cmd, '\n');
    const first = cmd[0 .. nl orelse cmd.len];
    const rest = if (nl) |i| cmd[i + 1 ..] else "";
    for ([_][]const u8{ "want", "out-of-scope" }) |kind| {
        if (escapeOf(first, kind)) |e| return .{ .escape = e };
    }
    if (std.mem.startsWith(u8, first, "#")) return refuse("an escape is `# want: <tag>: <text>` or `# out-of-scope: <tag>: <text>`, the tag `[a-z0-9-]`; ", .{});

    var words: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, first, ' ');
    while (it.next()) |w| {
        if (n == words.len) return refuse("too many words; ", .{});
        words[n] = w;
        n += 1;
    }
    var at: usize = 0;
    if (n >= 3 and std.mem.eql(u8, words[0], "cd") and std.mem.eql(u8, words[2], "&&")) {
        if (!plain(words[1])) return refuse("`cd {s}` is not a plain folder; ", .{words[1]});
        at = 3;
    }
    // The heredoc's opener, the first line's last word.
    var tag: ?[]const u8 = null;
    if (n > at and std.mem.startsWith(u8, words[n - 1], "<<")) {
        const w = words[n - 1];
        if (w.len < 5 or w[2] != '\'' or w[w.len - 1] != '\'' or !upperTag(w[3 .. w.len - 1])) return refuse("`{s}`: a heredoc is `<<'TAG'`, quoted, the TAG `[A-Z_]+`; ", .{w});
        tag = w[3 .. w.len - 1];
        n -= 1;
    }
    if (n <= at) return refuse("no `shale`; ", .{});
    const prog = words[at];
    if (!std.mem.eql(u8, prog, "shale") and !(prog[0] == '/' and std.mem.endsWith(u8, prog, "/shale") and plain(prog))) return refuse("`{s}` is not `shale`; ", .{prog});
    var i = at + 1;
    while (i < n) : (i += 1) {
        const w = words[i];
        if (!plain(w)) return refuse("`{s}` is not a plain word; ", .{w});
        if (std.mem.eql(u8, w, "--write") or std.mem.eql(u8, w, "--verbose")) continue;
        if (std.mem.eql(u8, w, "--budget")) {
            if (i + 1 >= n or std.mem.indexOfScalar(u8, words[i + 1], '=') == null or !plain(words[i + 1])) return refuse("`--budget` takes `NAME=N`; ", .{});
            i += 1;
            continue;
        }
        if (w[0] == '-') return refuse("`{s}` is not an option the gate passes; ", .{w});
    }
    const t = tag orelse {
        if (std.mem.trim(u8, rest, " \t\r\n").len != 0) return refuse("a launch is one line, or a heredoc's; ", .{});
        return .launch;
    };
    // The body, and its last line `TAG`, which no other line is.
    var lines: [4096][]const u8 = undefined;
    var m: usize = 0;
    var li = std.mem.splitScalar(u8, rest, '\n');
    while (li.next()) |l| {
        if (m == lines.len) return refuse("a heredoc of more than {d} lines; ", .{lines.len});
        lines[m] = l;
        m += 1;
    }
    if (m > 0 and lines[m - 1].len == 0 and std.mem.endsWith(u8, rest, "\n")) m -= 1;
    if (rest.len == 0 or m == 0 or !std.mem.eql(u8, std.mem.trimEnd(u8, lines[m - 1], " "), t)) return refuse("the heredoc has no last line `{s}`; ", .{t});
    for (lines[0 .. m - 1]) |l| if (std.mem.eql(u8, std.mem.trimEnd(u8, l, " "), t)) return refuse("the heredoc meets `{s}` twice: a line before its end would close it; ", .{t});
    return .launch;
}

fn escapeOf(first: []const u8, kind: []const u8) ?Escape {
    if (!std.mem.startsWith(u8, first, "# ")) return null;
    const after = first[2..];
    if (!std.mem.startsWith(u8, after, kind) or !std.mem.startsWith(u8, after[kind.len..], ": ")) return null;
    const body = after[kind.len + 2 ..];
    const colon = std.mem.indexOf(u8, body, ": ") orelse return null;
    const tag = body[0..colon];
    if (tag.len == 0) return null;
    for (tag) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return null;
    const text = std.mem.trim(u8, body[colon + 2 ..], " \t\r");
    if (text.len == 0) return null;
    return .{ .kind = kind, .tag = tag, .text = text };
}

fn upperTag(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isUpper(c) or c == '_')) return false;
    return true;
}

/// A word the shell takes as it is: nothing it quotes, expands, globs,
/// redirects or chains on.
fn plain(w: []const u8) bool {
    if (w.len == 0) return false;
    for (w) |c| switch (c) {
        '\'', '"', '$', '`', ';', '|', '&', '<', '>', '(', ')', '*', '?', '\\', '\t', '\r' => return false,
        else => {},
    };
    return true;
}

/// **A WANTS LOG LINE**: date, session, kind, tag, text, and the
/// command's first 160 bytes, tab-separated, each with its tabs, newlines
/// and backslashes shown; at most 4 KiB, so one append never interleaves.
pub fn logLine(buf: []u8, date: []const u8, session: []const u8, e: Escape, cmd: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    const fields = [_][]const u8{ date, session, e.kind, e.tag, e.text[0..@min(e.text.len, 2048)], cmd[0..@min(cmd.len, 160)] };
    for (fields, 0..) |f, i| {
        if (i > 0) w.writeByte('\t') catch break;
        for (f) |c| (switch (c) {
            '\t' => w.writeAll("\\t"),
            '\n' => w.writeAll("\\n"),
            '\\' => w.writeAll("\\\\"),
            else => w.writeByte(c),
        }) catch break;
    }
    const n = w.buffered().len;
    buf[n] = '\n';
    return buf[0 .. n + 1];
}

pub const Hook = struct {
    session: []const u8,
    /// Bash's or Monitor's command; null for any other tool.
    command: ?[]const u8,
    /// A subagent's call: its input has a non-empty `agent_id`.
    subagent: bool = false,
};

/// The hook's input, or null for input the gate cannot read (refused).
pub fn readHook(a: std.mem.Allocator, json: []const u8) ?Hook {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return null;
    if (v != .object) return null;
    const o = v.object;
    var h: Hook = .{ .session = "", .command = null };
    if (o.get("session_id")) |s| if (s == .string) {
        h.session = s.string;
    };
    if (o.get("agent_id")) |s| if (s == .string and s.string.len > 0) {
        h.subagent = true;
    };
    const tool = o.get("tool_name") orelse return null;
    if (tool != .string) return null;
    if (!std.mem.eql(u8, tool.string, "Bash") and !std.mem.eql(u8, tool.string, "Monitor")) return h;
    const input = o.get("tool_input") orelse return null;
    if (input != .object) return null;
    const c = input.object.get("command") orelse return null;
    if (c != .string) return null;
    h.command = c.string;
    return h;
}

fn isoNow(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts.sec) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const secs = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, secs.getHoursIntoDay(), secs.getMinutesIntoHour(), secs.getSecondsIntoMinute() }) catch "?";
}

/// One append of `line` to `~/.local/state/shale/wants.tsv`, outside
/// every repo.
fn appendLog(a: std.mem.Allocator, home: []const u8, line: []const u8) bool {
    const dir = std.fmt.allocPrint(a, "{s}/.local/state/shale", .{home}) catch return false;
    var made: []const u8 = "";
    var it = std.mem.splitScalar(u8, dir[1..], '/');
    while (it.next()) |part| {
        made = std.fmt.allocPrint(a, "{s}/{s}", .{ made, part }) catch return false;
        _ = linux.mkdir(a.dupeZ(u8, made) catch return false, 0o755);
    }
    const path = std.fmt.allocPrintSentinel(a, "{s}/wants.tsv", .{dir}, 0) catch return false;
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    const n = linux.write(@intCast(fd), line.ptr, line.len);
    return linux.errno(n) == .SUCCESS and n == line.len;
}

fn say(msg: []const u8) void {
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
}

pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    var in_buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(init.io, &in_buf);
    const input = r.interface.allocRemaining(a, .limited(1 << 20)) catch {
        say("shale-gate: the hook's input could not be read: refused");
        return 2;
    };
    const h = readHook(a, input) orelse {
        say("shale-gate: the hook's input is not the JSON it expects (tool_name, tool_input.command): refused");
        return 2;
    };
    const cmd = h.command orelse return 0;
    if (h.subagent) return 0;
    switch (classify(cmd)) {
        .launch => return 0,
        .escape => |e| {
            var line_buf: [4096]u8 = undefined;
            var date_buf: [32]u8 = undefined;
            const home = init.environ_map.get("HOME") orelse {
                say("shale-gate: no HOME, so the escape cannot be logged: refused");
                return 2;
            };
            if (!appendLog(a, home, logLine(&line_buf, isoNow(&date_buf), h.session, e, cmd))) {
                say("shale-gate: the escape could not be logged to ~/.local/state/shale/wants.tsv: refused");
                return 2;
            }
            return 0;
        },
        .refused => |why| {
            say(why);
            return 2;
        },
    }
}
