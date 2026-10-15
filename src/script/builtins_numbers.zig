//! **NUMBERS' BUILTINS**: the least and the most of a few integers, and an
//! integer's size. The operators do the rest (`+ - * // %`, checked).

const std = @import("std");
const ast = @import("ast.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bi = @import("builtins.zig");

const Run = interp.Run;
const Value = value.Value;
const Error = interp.Error;
const B = ast.Builtin;
const spec = bi.spec;

pub const specs = [_]bi.Spec{
    spec(.min, 2, bi.most_args, extreme(.min)),
    spec(.max, 2, bi.most_args, extreme(.max)),
    spec(.abs, 1, 1, abs),
};

const Way = enum { min, max };

/// **`min(a, b, ...)`, `max(a, b, ...)`**: two to four integers.
fn extreme(comptime way: Way) bi.Impl {
    return struct {
        fn f(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
            const b: B = if (way == .min) .min else .max;
            var best = try bi.intArg(run, pos, b, args[0], "each argument");
            for (args[1..]) |v| {
                const x = try bi.intArg(run, pos, b, v, "each argument");
                best = if (way == .min) @min(best, x) else @max(best, x);
            }
            return .{ .int = best };
        }
    }.f;
}

fn abs(run: *Run, pos: ast.Pos, args: []const Value) Error!Value {
    const x = try bi.intArg(run, pos, .abs, args[0], "its integer");
    if (x == std.math.minInt(i64)) return run.fail(pos, .arithmetic, "abs({d}) overflows 64 bits", .{x});
    return .{ .int = @intCast(@abs(x)) };
}
