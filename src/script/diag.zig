//! How a script stops: where, which class of error, and why. Parse errors
//! and run errors alike; tests check the class, not every message.

pub const Class = enum {
    /// Not a sentence of the language.
    syntax,
    /// Lua accepts it and this language does not (named).
    refused,
    /// A name not declared, or declared twice in one scope.
    name,
    /// A value of the wrong type for what was done with it.
    type,
    /// A map key that is not there, or a list index out of range.
    index,
    /// Overflow, division by zero.
    arithmetic,
    /// A builtin or function given the wrong arguments.
    argument,
    /// A budget ran out (`Stop.budget` names which).
    budget,
    /// A store call failed.
    store,
};

pub const Budget = enum {
    steps,
    arena,
    call_depth,
    output,
    reads,
    read_bytes,
    changes,
    change_bytes,
    source,
    nesting,
    /// The walk's own recursion, across calls: what the Zig stack bounds.
    depth,
};

/// Where and why a run stopped. `message` is owned by the run's arena (or
/// is static).
pub const Stop = struct {
    line: u32,
    column: u32,
    class: Class,
    budget: ?Budget = null,
    message: []const u8,
    /// The script's function it stopped in, by name; "" at the top level.
    function: []const u8 = "",
};
