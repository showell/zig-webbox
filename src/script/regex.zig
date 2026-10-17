//! **REGULAR EXPRESSIONS, A LINEAR-TIME SUBSET** (metal-vmm QUEUE 230,
//! chunk 2; Steve, 2026-10-17: "yes to regex"): the engine `re_find` and
//! `re_match` run (builtins_regex.zig). Literals, `.`, classes (`[a-z]`,
//! `[^...]`, `\d \w \s` and their capitals), `*`, `+`, `?`, `^`, `$`,
//! alternation (`|`, lowest precedence, the leftmost alternative first) and
//! `\b \B` (a word's edge, ASCII; QUEUE 232), and one capture group, which
//! may hold alternatives; `nocase` folds ASCII letters when the pattern
//! compiles. No counted repetition, no backreferences, no lookaround: each
//! is refused, saying so.
//!
//! **A THOMPSON MACHINE, SO THE COST IS LINEAR.** A pattern compiles to a
//! program of at most a few instructions a byte; a search runs every way
//! through it at once, one byte of the string at a time, each instruction
//! at most once a byte (Pike's machine: the threads in order of preference,
//! so the match is the one a backtracking matcher would find first). A
//! search is at most (string bytes + 1) times the program's instructions,
//! whatever the pattern: `(a*)*b` on a long run of `a` costs about what
//! `a*b` does. Pure: no Run, no I/O; its memory is the caller's.

const std = @import("std");

/// The longest pattern compiled: one past it is refused before it is read.
pub const pattern_most = 256;

pub const Op = enum(u8) {
    /// The byte `c`.
    byte,
    /// Any byte but a newline.
    any,
    /// A byte in `sets[x]`.
    set,
    /// Go on at `x`, and (less preferred) at `y`.
    split,
    jmp,
    /// Note where the string is in capture slot `x` (0 the group's start, 1 its end).
    save,
    /// Only at the string's start.
    start,
    /// Only at the string's end.
    end,
    /// Only at a word's edge (`c` 0), or only not at one (`c` 1): a word
    /// byte on one side and none on the other.
    boundary,
    match,
};

pub const Inst = struct { op: Op, c: u8 = 0, x: u16 = 0, y: u16 = 0 };

pub const Set = std.StaticBitSet(256);

pub const Program = struct {
    insts: []Inst,
    sets: []Set,
    /// Whether the pattern has its capture group.
    group: bool,
    /// Whether the pattern begins with `^`: only a match at the start.
    anchored: bool,

    pub fn deinit(p: *Program, alloc: std.mem.Allocator) void {
        alloc.free(p.insts);
        alloc.free(p.sets);
    }
};

/// Why a pattern is not compiled: the byte of the pattern it is at, and
/// what to write instead.
pub const Refusal = struct { at: usize, message: []const u8 };

pub const Error = error{ OutOfMemory, Refused };

pub const Options = struct {
    /// ASCII letters match either case, folded into the program as it is
    /// compiled: a class is folded before its `^` (`[^a]` takes neither `a`
    /// nor `A`), as Python's is.
    nocase: bool = false,
};

// ── the pattern, read ───────────────────────────────────────────────────

const Quant = enum { one, star, plus, opt };

/// A pattern's alternatives, each a run of nodes.
const Alt = []const []const Node;

const Node = struct {
    kind: enum { byte, any, set, start, end, boundary, not_boundary, group },
    c: u8 = 0,
    set: u16 = 0,
    quant: Quant = .one,
    /// The group's alternatives.
    inner: Alt = &.{},
};

const Reader = struct {
    p: []const u8,
    at: usize = 0,
    /// The sets', kept in the program.
    alloc: std.mem.Allocator,
    /// The tree's, dropped when the program is made.
    tree: std.mem.Allocator,
    refused: *Refusal,
    options: Options,
    sets: std.ArrayList(Set) = .empty,
    group: bool = false,

    fn refuse(r: *Reader, at: usize, message: []const u8) Error {
        r.refused.* = .{ .at = at, .message = message };
        return error.Refused;
    }

    /// Alternatives, to the pattern's end or (in the group) its `)`.
    fn alt(r: *Reader, in_group: bool) Error!Alt {
        var seqs: std.ArrayList([]const Node) = .empty;
        while (true) {
            try seqs.append(r.tree, try r.seq(in_group));
            if (r.at < r.p.len and r.p[r.at] == '|') {
                r.at += 1;
                continue;
            }
            return seqs.items;
        }
    }

    /// A run of nodes, to the pattern's end, a `|`, or (in the group) its `)`.
    fn seq(r: *Reader, in_group: bool) Error![]const Node {
        var list: std.ArrayList(Node) = .empty;
        while (r.at < r.p.len) {
            const at = r.at;
            const c = r.p[at];
            var node: Node = switch (c) {
                ')' => {
                    if (in_group) return list.items;
                    return r.refuse(at, "a `)` with no `(` before it: `\\)` is the byte");
                },
                '|' => return list.items,
                '(' => blk: {
                    if (r.at + 1 < r.p.len and r.p[r.at + 1] == '?') return r.refuse(at, "`(?` is not in this subset: no lookaround and no groups that do not capture");
                    if (in_group or r.group) return r.refuse(at, "one capture group a pattern: a second `(` is not in this subset (`\\(` is the byte)");
                    r.group = true;
                    r.at += 1;
                    const inner = try r.alt(true);
                    if (r.at >= r.p.len) return r.refuse(at, "a `(` that is never closed");
                    r.at += 1; // )
                    break :blk .{ .kind = .group, .inner = inner };
                },
                '{' => return r.refuse(at, "`{n,m}` is not in this subset: write the part out as often as it must come (`\\d\\d\\d?`), or `\\{` for the byte"),
                '*', '+', '?' => return r.refuse(at, "a `*`, `+` or `?` with nothing before it to repeat"),
                '.' => blk: {
                    r.at += 1;
                    break :blk .{ .kind = .any };
                },
                '^' => blk: {
                    r.at += 1;
                    break :blk .{ .kind = .start };
                },
                '$' => blk: {
                    r.at += 1;
                    break :blk .{ .kind = .end };
                },
                '[' => try r.class(),
                '\\' => try r.escape(),
                else => blk: {
                    r.at += 1;
                    break :blk try r.byteNode(c);
                },
            };
            if (r.at < r.p.len) switch (r.p[r.at]) {
                '*', '+', '?' => |q| {
                    if (node.kind == .start or node.kind == .end or node.kind == .boundary or node.kind == .not_boundary)
                        return r.refuse(r.at, "`^`, `$`, `\\b` and `\\B` are places, not bytes: they cannot repeat");
                    node.quant = switch (q) {
                        '*' => .star,
                        '+' => .plus,
                        else => .opt,
                    };
                    r.at += 1;
                    if (r.at < r.p.len) switch (r.p[r.at]) {
                        '?' => return r.refuse(r.at, "lazy repetition (`*?`, `+?`, `??`) is not in this subset: every repetition takes as much as it can"),
                        '*', '+' => return r.refuse(r.at, "a repetition repeated (`a**`, `a+*`): one is enough"),
                        '{' => return r.refuse(r.at, "`{n,m}` is not in this subset: write the part out as often as it must come (`\\d\\d\\d?`), or `\\{` for the byte"),
                        else => {},
                    };
                },
                '{' => return r.refuse(r.at, "`{n,m}` is not in this subset: write the part out as often as it must come (`\\d\\d\\d?`), or `\\{` for the byte"),
                else => {},
            };
            try list.append(r.tree, node);
        }
        return list.items;
    }

    /// A byte, or under `nocase` a letter's two cases.
    fn byteNode(r: *Reader, c: u8) Error!Node {
        if (r.options.nocase and std.ascii.isAlphabetic(c)) {
            var s = Set.initEmpty();
            s.set(std.ascii.toLower(c));
            s.set(std.ascii.toUpper(c));
            return r.newSet(s);
        }
        return .{ .kind = .byte, .c = c };
    }

    fn newSet(r: *Reader, s: Set) Error!Node {
        try r.sets.append(r.alloc, s);
        return .{ .kind = .set, .set = @intCast(r.sets.items.len - 1) };
    }

    /// `\d \w \s` and their capitals, as a set; null for any other escape.
    fn shorthand(c: u8) ?Set {
        var s = Set.initEmpty();
        switch (std.ascii.toLower(c)) {
            'd' => s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
            'w' => {
                s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true);
                s.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true);
                s.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true);
                s.set('_');
            },
            's' => for (" \t\n\r\x0b\x0c") |b| s.set(b),
            else => return null,
        }
        if (std.ascii.isUpper(c)) s.toggleAll();
        return s;
    }

    /// The byte an escape that is one byte stands for: `\n \t \r`, or a
    /// byte that is not a letter or digit, itself.
    fn escapedByte(r: *Reader, at: usize, c: u8) Error!u8 {
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            '0'...'9' => return r.refuse(at, "backreferences (`\\1`) are not in this subset"),
            else => {},
        }
        if (std.ascii.isAlphabetic(c)) return r.refuse(at, "an escape this subset does not have: `\\d \\w \\s` (and `\\D \\W \\S`), `\\b \\B`, `\\n \\t \\r`, or `\\` before a byte that is not a letter or digit");
        return c;
    }

    fn escape(r: *Reader) Error!Node {
        const at = r.at;
        if (at + 1 >= r.p.len) return r.refuse(at, "a pattern that ends in `\\`: `\\\\` is the byte");
        const c = r.p[at + 1];
        r.at += 2;
        if (shorthand(c)) |s| return r.newSet(s);
        if (c == 'b') return .{ .kind = .boundary };
        if (c == 'B') return .{ .kind = .not_boundary };
        return r.byteNode(try r.escapedByte(at, c));
    }

    /// `[...]`: bytes, ranges (`a-z`) and shorthands; `^` first is every
    /// byte but those; a `]` first is the byte. Under `nocase` the letters
    /// are folded before the `^`.
    fn class(r: *Reader) Error!Node {
        const open = r.at;
        r.at += 1;
        var s = Set.initEmpty();
        const negated = r.at < r.p.len and r.p[r.at] == '^';
        if (negated) r.at += 1;
        var first = true;
        while (true) : (first = false) {
            if (r.at >= r.p.len) return r.refuse(open, "a `[` that is never closed");
            const at = r.at;
            const c = r.p[at];
            if (c == ']' and !first) {
                r.at += 1;
                break;
            }
            if (c == '[' and at + 1 < r.p.len and r.p[at + 1] == ':') return r.refuse(at, "`[:alpha:]` and its kind are not in this subset: write the bytes (`[a-zA-Z]`), or `\\[` for the byte");
            var lo: u8 = c;
            if (c == '\\') {
                if (at + 1 >= r.p.len) return r.refuse(open, "a `[` that is never closed");
                const e = r.p[at + 1];
                r.at += 2;
                if (shorthand(e)) |sh| {
                    s.setUnion(sh);
                    continue;
                }
                if (e == 'b' or e == 'B') return r.refuse(at, "`\\b` in a class is not in this subset: a word's edge is a place, not a byte; write it outside the `[...]`");
                lo = try r.escapedByte(at, e);
            } else r.at += 1;
            // A range, unless the `-` is the class's last byte.
            if (r.at + 1 < r.p.len and r.p[r.at] == '-' and r.p[r.at + 1] != ']') {
                const hi_at = r.at + 1;
                var hi = r.p[hi_at];
                r.at += 2;
                if (hi == '\\') {
                    if (hi_at + 1 >= r.p.len) return r.refuse(open, "a `[` that is never closed");
                    const e = r.p[hi_at + 1];
                    if (shorthand(e) != null) return r.refuse(hi_at, "a range's end must be one byte, not a class");
                    hi = try r.escapedByte(hi_at, e);
                    r.at += 1;
                }
                if (hi < lo) return r.refuse(at, "a range whose end is before its start (`z-a`): write it `a-z`");
                s.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
            } else s.set(lo);
        }
        if (r.options.nocase) {
            var folded = s;
            var it = s.iterator(.{});
            while (it.next()) |b| if (std.ascii.isAlphabetic(@intCast(b))) {
                folded.set(std.ascii.toLower(@intCast(b)));
                folded.set(std.ascii.toUpper(@intCast(b)));
            };
            s = folded;
        }
        if (negated) s.toggleAll();
        return r.newSet(s);
    }
};

// ── the program, made ───────────────────────────────────────────────────

const Emitter = struct {
    insts: std.ArrayList(Inst) = .empty,
    alloc: std.mem.Allocator,

    fn emit(e: *Emitter, i: Inst) Error!u16 {
        try e.insts.append(e.alloc, i);
        return @intCast(e.insts.items.len - 1);
    }

    fn here(e: *const Emitter) u16 {
        return @intCast(e.insts.items.len);
    }

    /// Alternatives: a split to each in turn, the leftmost preferred, each
    /// but the last ending in a jump past the rest.
    fn alt(e: *Emitter, a: Alt) Error!void {
        var ends: [pattern_most + 1]u16 = undefined;
        var n_ends: usize = 0;
        for (a, 0..) |s, k| {
            if (k + 1 == a.len) {
                try e.seq(s);
                break;
            }
            const split = try e.emit(.{ .op = .split });
            e.insts.items[split].x = split + 1;
            try e.seq(s);
            ends[n_ends] = try e.emit(.{ .op = .jmp });
            n_ends += 1;
            e.insts.items[split].y = e.here();
        }
        for (ends[0..n_ends]) |j| e.insts.items[j].x = e.here();
    }

    fn seq(e: *Emitter, nodes: []const Node) Error!void {
        for (nodes) |n| try e.node(n);
    }

    fn atom(e: *Emitter, n: Node) Error!void {
        switch (n.kind) {
            .byte => _ = try e.emit(.{ .op = .byte, .c = n.c }),
            .any => _ = try e.emit(.{ .op = .any }),
            .set => _ = try e.emit(.{ .op = .set, .x = n.set }),
            .start => _ = try e.emit(.{ .op = .start }),
            .end => _ = try e.emit(.{ .op = .end }),
            .boundary => _ = try e.emit(.{ .op = .boundary, .c = 0 }),
            .not_boundary => _ = try e.emit(.{ .op = .boundary, .c = 1 }),
            .group => {
                _ = try e.emit(.{ .op = .save, .x = 0 });
                try e.alt(n.inner);
                _ = try e.emit(.{ .op = .save, .x = 1 });
            },
        }
    }

    /// Thompson's: `e*` is a split to the part or past it and a jump back;
    /// `e+` the part and a split back; `e?` a split to the part or past it.
    /// The first way of each split is the one preferred: more, not fewer.
    fn node(e: *Emitter, n: Node) Error!void {
        switch (n.quant) {
            .one => try e.atom(n),
            .star => {
                const loop = try e.emit(.{ .op = .split });
                try e.atom(n);
                _ = try e.emit(.{ .op = .jmp, .x = loop });
                e.insts.items[loop].x = loop + 1;
                e.insts.items[loop].y = e.here();
            },
            .plus => {
                const top = e.here();
                try e.atom(n);
                const s = try e.emit(.{ .op = .split, .x = top });
                e.insts.items[s].y = s + 1;
            },
            .opt => {
                const s = try e.emit(.{ .op = .split });
                try e.atom(n);
                e.insts.items[s].x = s + 1;
                e.insts.items[s].y = e.here();
            },
        }
    }
};

/// **A PATTERN, COMPILED**, or refused (`refused` says where and why).
/// Its memory is `alloc`'s, given back by `Program.deinit`.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, options: Options, refused: *Refusal) Error!Program {
    if (pattern.len > pattern_most) {
        refused.* = .{ .at = pattern_most, .message = "a pattern of more than 256 bytes" };
        return error.Refused;
    }
    var tree = std.heap.ArenaAllocator.init(alloc);
    defer tree.deinit();
    var r: Reader = .{ .p = pattern, .alloc = alloc, .tree = tree.allocator(), .refused = refused, .options = options };
    errdefer r.sets.deinit(alloc);
    const top = try r.alt(false);
    var e: Emitter = .{ .alloc = alloc };
    errdefer e.insts.deinit(alloc);
    try e.alt(top);
    _ = try e.emit(.{ .op = .match });
    const insts = try e.insts.toOwnedSlice(alloc);
    errdefer alloc.free(insts);
    return .{
        .insts = insts,
        .sets = try r.sets.toOwnedSlice(alloc),
        .group = r.group,
        .anchored = top.len == 1 and top[0].len > 0 and top[0][0].kind == .start,
    };
}

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ── the search ──────────────────────────────────────────────────────────

/// Where a thread's string is: the match's start, the group's start and end
/// (`unset` where it has none).
const Caps = [3]usize;
const unset = std.math.maxInt(usize);

const Thread = struct { pc: u16, caps: Caps };

/// The threads waiting at one place of the string, in order of preference,
/// and every instruction the adding has been to for that place: each at
/// most once (`stamp[pc] == now`). A list made anew is a stamp later.
const List = struct {
    threads: []Thread,
    stamp: []u64,
    now: u64 = 1,
    len: usize = 0,

    fn reset(l: *List) void {
        l.len = 0;
        l.now += 1;
    }
};

/// What a search works in, made once for a program and used for every
/// search with it.
pub const Scratch = struct {
    a: List,
    b: List,
    /// The ways still to be followed while threads are added: a split's
    /// second way waits while its first is followed.
    stack: []Thread,

    pub fn init(alloc: std.mem.Allocator, p: *const Program) error{OutOfMemory}!Scratch {
        const n = p.insts.len;
        const a_threads = try alloc.alloc(Thread, n);
        errdefer alloc.free(a_threads);
        const a_stamp = try alloc.alloc(u64, n);
        errdefer alloc.free(a_stamp);
        const b_threads = try alloc.alloc(Thread, n);
        errdefer alloc.free(b_threads);
        const b_stamp = try alloc.alloc(u64, n);
        errdefer alloc.free(b_stamp);
        const stack = try alloc.alloc(Thread, n + 1);
        @memset(a_stamp, 0);
        @memset(b_stamp, 0);
        return .{ .a = .{ .threads = a_threads, .stamp = a_stamp }, .b = .{ .threads = b_threads, .stamp = b_stamp }, .stack = stack };
    }

    pub fn deinit(s: *Scratch, alloc: std.mem.Allocator) void {
        alloc.free(s.a.threads);
        alloc.free(s.a.stamp);
        alloc.free(s.b.threads);
        alloc.free(s.b.stamp);
        alloc.free(s.stack);
    }
};

pub const Found = struct {
    /// The match: `s[start..end]`.
    start: usize,
    end: usize,
    /// The group's `[start, end]`, where the match went through it.
    group: ?[2]usize,
};

pub const Searched = struct {
    found: ?Found,
    /// The string's places looked at, 0 to its length: what a search
    /// costs is this times the program's instructions.
    positions: u64,
    /// The instructions followed (a measure, for the tests: at most twice
    /// the program's instructions a place).
    work: u64,
    /// Whether the search ended; not when `positions_most` stopped it.
    finished: bool,
};

/// Every way from `first` that ends at a byte to match or at the match,
/// added to `list` in order of preference, at the string's place `pos`. A
/// way that comes to an instruction already followed for this place ends
/// there (a loop's turn that took no byte, or a way less preferred than
/// one already there), so each instruction is followed at most once a place.
fn add(p: *const Program, sc: *Scratch, list: *List, first: Thread, pos: usize, s: []const u8, work: *u64) void {
    const len = s.len;
    var top: usize = 1;
    sc.stack[0] = first;
    while (top > 0) {
        top -= 1;
        var t = sc.stack[top];
        while (true) {
            work.* += 1;
            if (list.stamp[t.pc] == list.now) break;
            list.stamp[t.pc] = list.now;
            const i = p.insts[t.pc];
            switch (i.op) {
                .jmp => t.pc = i.x,
                .split => {
                    sc.stack[top] = .{ .pc = i.y, .caps = t.caps };
                    top += 1;
                    t.pc = i.x;
                },
                .save => {
                    t.caps[1 + i.x] = pos;
                    t.pc += 1;
                },
                .start => if (pos == 0) {
                    t.pc += 1;
                } else break,
                .end => if (pos == len) {
                    t.pc += 1;
                } else break,
                .boundary => if (((pos > 0 and wordByte(s[pos - 1])) != (pos < len and wordByte(s[pos]))) == (i.c == 0)) {
                    t.pc += 1;
                } else break,
                .byte, .any, .set, .match => {
                    list.threads[list.len] = t;
                    list.len += 1;
                    break;
                },
            }
        }
    }
}

/// **THE LEFTMOST MATCH OF `p` IN `s`**, the one a backtracking matcher
/// would find first, or none; at most `positions_most` places looked at.
pub fn search(p: *const Program, sc: *Scratch, s: []const u8, positions_most: u64) Searched {
    var clist = &sc.a;
    var nlist = &sc.b;
    clist.reset();
    var matched: ?Caps = null;
    var match_end: usize = 0;
    var positions: u64 = 0;
    var work: u64 = 0;
    var pos: usize = 0;
    while (true) : (pos += 1) {
        if (positions == positions_most) return .{ .found = null, .positions = positions, .work = work, .finished = false };
        positions += 1;
        // A new start, least preferred, until there is a match.
        if (matched == null and (!p.anchored or pos == 0))
            add(p, sc, clist, .{ .pc = 0, .caps = .{ pos, unset, unset } }, pos, s, &work);
        nlist.reset();
        for (clist.threads[0..clist.len]) |t| {
            work += 1;
            const i = p.insts[t.pc];
            if (i.op == .match) {
                // Every way less preferred than this one is cut.
                matched = t.caps;
                match_end = pos;
                break;
            }
            if (pos == s.len) continue;
            const ok = switch (i.op) {
                .byte => s[pos] == i.c,
                .any => s[pos] != '\n',
                .set => p.sets[i.x].isSet(s[pos]),
                else => unreachable,
            };
            if (ok) add(p, sc, nlist, .{ .pc = t.pc + 1, .caps = t.caps }, pos + 1, s, &work);
        }
        std.mem.swap(*List, &clist, &nlist);
        if (pos == s.len) break;
        // Nothing left to follow, and nothing new will start.
        if (clist.len == 0 and (matched != null or p.anchored)) break;
    }
    const caps = matched orelse return .{ .found = null, .positions = positions, .work = work, .finished = true };
    return .{
        .found = .{ .start = caps[0], .end = match_end, .group = if (caps[1] != unset and caps[2] != unset) .{ caps[1], caps[2] } else null },
        .positions = positions,
        .work = work,
        .finished = true,
    };
}

// ── the compiled patterns, kept ─────────────────────────────────────────

/// **A PATTERN IS COMPILED ONCE A RUN, CACHED BY ITS TEXT** (QUEUE 230)
/// and its `nocase` (QUEUE 232):
/// the last `cache_most` patterns a run used, each with the scratch its
/// searches work in. A ninth takes the place of the one used longest ago.
pub const cache_most = 8;

pub const Cached = struct {
    text: []u8,
    nocase: bool,
    program: Program,
    scratch: Scratch,
    used: u64,

    fn deinit(c: *Cached, alloc: std.mem.Allocator) void {
        alloc.free(c.text);
        c.program.deinit(alloc);
        c.scratch.deinit(alloc);
    }
};

pub const Cache = struct {
    entries: [cache_most]?Cached = @splat(null),
    clock: u64 = 0,

    /// The pattern's compiled program, if the cache has it.
    pub fn get(c: *Cache, pattern: []const u8, options: Options) ?*Cached {
        c.clock += 1;
        for (&c.entries) |*e| if (e.*) |*got| if (got.nocase == options.nocase and std.mem.eql(u8, got.text, pattern)) {
            got.used = c.clock;
            return got;
        };
        return null;
    }

    /// The pattern, compiled and kept (`get` found it not there).
    pub fn put(c: *Cache, alloc: std.mem.Allocator, pattern: []const u8, options: Options, refused: *Refusal) Error!*Cached {
        var program = try compile(alloc, pattern, options, refused);
        errdefer program.deinit(alloc);
        var scratch = try Scratch.init(alloc, &program);
        errdefer scratch.deinit(alloc);
        const text = try alloc.dupe(u8, pattern);
        var slot: usize = 0;
        for (c.entries, 0..) |e, i| {
            const e_used = if (e) |got| got.used else 0;
            const slot_used = if (c.entries[slot]) |got| got.used else 0;
            if (e == null or e_used < slot_used) slot = i;
            if (e == null) break;
        }
        if (c.entries[slot]) |*old| old.deinit(alloc);
        c.entries[slot] = .{ .text = text, .nocase = options.nocase, .program = program, .scratch = scratch, .used = c.clock };
        return &c.entries[slot].?;
    }

    pub fn deinit(c: *Cache, alloc: std.mem.Allocator) void {
        for (&c.entries) |*e| if (e.*) |*got| got.deinit(alloc);
        c.* = .{};
    }
};
