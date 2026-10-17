//! **THE TREE** a script parses to: every node with its line and column,
//! every name already resolved to a slot in its function's frame, every
//! call to a builtin or a function by index. All of it in the run's arena.

pub const Pos = struct { line: u32, column: u32 };

pub const Builtin = enum {
    // the store
    ls,
    stat,
    exists,
    is_dir,
    read,
    read_or,
    read_lines,
    line_at,
    grep,
    count_lines,
    count_in,
    find_in,
    replace,
    append,
    mkdir,
    remove,
    remove_tree,
    walk,
    edit,
    // strings
    split,
    join,
    starts_with,
    ends_with,
    contains,
    find,
    sub,
    trim,
    upper,
    lower,
    tostring,
    tonumber,
    parse_int,
    lines,
    words,
    like,
    rep,
    substitute,
    path,
    match_path,
    basename,
    strip_suffix,
    between,
    // regular expressions (QUEUE 230)
    re_find,
    re_match,
    // numbers
    min,
    max,
    abs,
    // dates and formatting
    date,
    seconds,
    human,
    pad,
    table,
    // lists and maps
    push,
    sort,
    keys,
    has_key,
    get,
    count,
    reverse,
    take,
    last,
    // the host
    now,
    arg,
    fail,
    host,
    budget,
    yield,
    print,
};

/// `eq_nil` and `ne_nil` are `==` and `~=` with the literal `nil` on a
/// side (metal-vmm QUEUE 231): the one comparison a map or a list may be
/// in, so `if m == nil` reads as written.
pub const BinOp = enum { add, sub, mul, idiv, mod, concat, eq, ne, eq_nil, ne_nil, lt, le, gt, ge, @"and", @"or" };
pub const UnOp = enum { neg, not, len };

pub const Expr = struct {
    pos: Pos,
    kind: Kind,

    pub const Kind = union(enum) {
        nil,
        boolean: bool,
        int: i64,
        string: []const u8,
        local: u16,
        /// A top-level `const`, read in a function: an index into the
        /// run's constants (`Program.const_names`).
        constant: u16,
        index: struct { obj: *Expr, key: *Expr },
        call: Call,
        binary: struct { op: BinOp, left: *Expr, right: *Expr },
        unary: struct { op: UnOp, operand: *Expr },
        list: []*Expr,
        map: []MapEntry,
        empty_table,
    };
};

pub const MapEntry = struct { key: []const u8, value: *Expr, pos: Pos };

pub const Call = struct {
    target: Target,
    args: []*Expr,

    pub const Target = union(enum) {
        builtin: Builtin,
        /// An index into `Program.functions`, set
        /// as the call is parsed (a function is called only after it is declared).
        function: u32,
        /// `attempt(f, ...)`: the function `f` (an index, as `function`)
        /// called with the rest of the arguments, its error a value.
        attempt: u32,
    };
};

pub const Stmt = struct {
    pos: Pos,
    kind: Kind,

    pub const Kind = union(enum) {
        local: struct { slot: u16, value: ?*Expr },
        /// `const NAME = e`, at the top level: the script's own slot, and
        /// the constant the functions declared after it read.
        constant: struct { slot: u16, index: u16, value: *Expr },
        assign: struct { target: *Expr, value: *Expr },
        call: *Expr,
        @"if": struct { arms: []Arm, otherwise: ?[]Stmt },
        @"while": struct { cond: *Expr, body: []Stmt },
        numeric_for: struct { slot: u16, from: *Expr, to: *Expr, step: ?*Expr, body: []Stmt },
        list_for: struct { slot: u16, list: *Expr, body: []Stmt },
        @"return": ?*Expr,
        @"break",
        @"continue",
        do: []Stmt,
    };
};

pub const Arm = struct { cond: *Expr, body: []Stmt };

pub const Function = struct {
    name: []const u8,
    pos: Pos,
    params: u16,
    /// The last of `params` that may be left out (`b?`): a call that
    /// leaves them out is given nil for them, by the parse.
    optional: u16 = 0,
    /// Slots in its frame: parameters first, then every local it declares.
    frame: u16,
    body: []Stmt,
};

pub const Program = struct {
    /// The script's functions and the prelude's it calls (QUEUE 230), in
    /// the order the parse met them.
    functions: []Function,
    /// The top-level `const`s, in order, by name.
    const_names: []const []const u8 = &.{},
    /// The script's own top level, a function with no parameters.
    main: Function,
};
