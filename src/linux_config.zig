//! linux_config: how a Linux host learns where its data is. Part of the
//! `webbox` library's Linux half (`webbox_linux`): it reads the environment
//! and a file.
//!
//! The application names an environment variable (angry-gopher's is
//! GOPHER_CONFIG) whose value is the path of a flat `key = value` file, read
//! for `data_dir` and `auth_dir` (a leading `~/` is $HOME). Both go to the
//! site's `start` as its `Roots`. With the variable unset, or no `data_dir`
//! in the file, there are none, and each store keeps its development default.

const std = @import("std");
const Io = @import("host_io").Io;
const Roots = @import("webbox").site.Roots;

/// The data directory this process serves, for the host's facts: the
/// config's `data_dir`, or what `load` says when there is none.
pub var data_dir_shown: []const u8 = "";

/// Reads the config file the variable `config_var` names, if it is set in
/// `env`, and answers the roots. `auth_default` is the `auth_dir` when the
/// file names none. Strings are allocated from `alloc`, a long-lived
/// allocator: the roots live for the whole process.
pub fn load(io: Io, alloc: std.mem.Allocator, env: std.process.Environ.Map, comptime config_var: []const u8, auth_default: []const u8) !?Roots {
    data_dir_shown = "the repository's defaults (no " ++ config_var ++ ")";
    const path = env.get(config_var) orelse {
        std.debug.print("config: " ++ config_var ++ " unset — using repo-relative defaults\n", .{});
        return null;
    };

    const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| {
        std.debug.print("config: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };

    var data_dir: ?[]const u8 = null;
    var auth_dir: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "data_dir")) {
            data_dir = try expandHome(alloc, env, val);
        } else if (std.mem.eql(u8, key, "auth_dir")) {
            auth_dir = try expandHome(alloc, env, val);
        }
        // Other keys (a port, say) are not the file's to set: the host's
        // settings are its environment variables.
    }

    if (data_dir) |dd| data_dir_shown = dd;
    const dd = data_dir orelse {
        std.debug.print("config: {s} has no data_dir — using defaults\n", .{path});
        return null;
    };
    const ad = auth_dir orelse try expandHome(alloc, env, auth_default);
    std.debug.print("config: data_dir={s}  auth_dir={s}\n", .{ dd, ad });
    return .{ .data_dir = dd, .auth_dir = ad };
}

/// expandHome turns a leading `~/` into $HOME. Other forms pass through
/// unchanged.
fn expandHome(alloc: std.mem.Allocator, env: std.process.Environ.Map, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "~/")) {
        const home = env.get("HOME") orelse return alloc.dupe(u8, p);
        return std.fs.path.join(alloc, &.{ home, p[2..] });
    }
    return alloc.dupe(u8, p);
}
