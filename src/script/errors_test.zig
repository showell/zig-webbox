//! **THE GOLDEN CORPUS OF ERRORS** (metal-vmm QUEUE 209(d)): a wrong
//! script of each kind, and exactly what the person who wrote it is told:
//! the class, the line and column, the function it stopped in, and the
//! message, word for word. A message changed is a line of this file
//! changed, read in review; every class the language has is here
//! (the test below checks it).

const std = @import("std");
const script = @import("script.zig");
const testing = std.testing;

const Case = struct {
    src: []const u8,
    line: u32,
    column: u32,
    function: ?[]const u8 = null,
    class: script.diag.Class,
    budget: ?script.diag.Budget = null,
    message: []const u8,
};

const cases = [_]Case{
    .{ .src = "x = 1", .line = 1, .column = 1, .class = .name, .message = "no local `x`: declare it with `local x = ...` (there are no globals)" },
    .{ .src = "print(y)", .line = 1, .column = 7, .class = .name, .message = "no local `y`: declare it with `local y = ...` (there are no globals)" },
    .{ .src = "local a = 1 local a = 2", .line = 1, .column = 13, .class = .name, .message = "`a` is already a local in this block" },
    .{ .src = "function f() end function f() end", .line = 1, .column = 18, .class = .name, .message = "a function `f` is already declared" },
    .{ .src = "nosuch(1)", .line = 1, .column = 1, .class = .name, .message = "no function `nosuch` above this line: a function is called only after it is declared" },
    .{ .src = "function f(a) end f(1, 2)", .line = 1, .column = 19, .class = .argument, .message = "`f` takes 1 argument, given 2" },
    .{ .src = "local s = string.upper(\"a\")", .line = 1, .column = 11, .class = .refused, .message = "the standard library is not in this language: call the builtin, `upper(s)`, not `string.upper(s)`" },
    .{ .src = "table.insert(l, 1)", .line = 1, .column = 1, .class = .refused, .message = "the standard library is not in this language: call the builtin, `push(l, x)`, not `table.insert(l, x)`" },
    .{ .src = "for k, v in pairs(m) do end", .line = 1, .column = 6, .class = .refused, .message = "several loop names are not in this language: `for k in keys(m) do ... m[k] ... end`" },
    .{ .src = "pcall(f)", .line = 1, .column = 1, .class = .refused, .message = "`pcall` is not in this language: `attempt(f, ...)` calls a function and gives its error as a value" },
    .{ .src = "local a, b = 1, 2", .line = 1, .column = 8, .class = .refused, .message = "declaring several locals at once is not in this language: one `local` each" },
    .{ .src = "local a = 1 local b = 2 a, b = b, a", .line = 1, .column = 26, .class = .refused, .message = "multiple assignment is not in this language: one assignment each" },
    .{ .src = "function f() return 1, 2 end", .line = 1, .column = 22, .class = .refused, .message = "multiple returns are not in this language: return a list or a map" },
    .{ .src = "local f = function() end", .line = 1, .column = 11, .class = .refused, .message = "functions are not values in this language: declare one at the top level with `function name(...)`" },
    .{ .src = "local function f() end", .line = 1, .column = 1, .class = .refused, .message = "`local function` is not in this language: functions are declared at the top level with `function name(...)`" },
    .{ .src = "function f() function g() end end", .line = 1, .column = 14, .class = .refused, .message = "functions are top-level statements only: nested functions and closures are not in this language" },
    .{ .src = "local x = print", .line = 1, .column = 11, .class = .refused, .message = "`print` is a builtin, not a value: call it, `print(...)`" },
    .{ .src = "local s = 1 s(2)", .line = 1, .column = 13, .class = .refused, .message = "`s` is a value here, not a function: a local, a parameter or a `const` of that name hides the function or builtin; name it otherwise" },
    .{ .src = "print \"hi\"", .line = 1, .column = 7, .class = .refused, .message = "a call needs its parentheses: `f(\"x\")`, not `f \"x\"`" },
    .{ .src = "local t = {1, a = 2}", .line = 1, .column = 15, .class = .type, .message = "a table literal mixes positional and keyed entries: a list or a map, not both" },
    .{ .src = "local t = {1, nil}", .line = 1, .column = 15, .class = .type, .message = "a list cannot hold nil" },
    .{ .src = "local t = {a = 1, a = 2}", .line = 1, .column = 19, .class = .index, .message = "the key `a` is given twice" },
    .{ .src = "if true then\n", .line = 2, .column = 1, .class = .syntax, .message = "expected `end` to close the `if`, found the end of the script" },
    .{ .src = "end", .line = 1, .column = 1, .class = .syntax, .message = "`end` with nothing open to close" },
    .{ .src = "break", .line = 1, .column = 1, .class = .syntax, .message = "`break` outside a loop" },
    .{ .src = "continue", .line = 1, .column = 1, .class = .syntax, .message = "`continue` outside a loop" },
    .{ .src = "return 1 print(2)", .line = 1, .column = 10, .class = .syntax, .message = "`return` must be the last statement of its block" },
    .{ .src = "1 + 2", .line = 1, .column = 1, .class = .syntax, .message = "a statement must be a call or an assignment, found `+`" },
    .{ .src = "local x = )", .line = 1, .column = 11, .class = .syntax, .message = "expected a value, found `)`" },
    .{ .src = "local x = (1\n", .line = 2, .column = 1, .class = .syntax, .message = "expected `)`, found the end of the script" },
    .{ .src = "print(1) = 2", .line = 1, .column = 1, .class = .syntax, .message = "only a local or an element `t[k]`, `t.k` can be assigned" },
    // `fail` (the design, final; QUEUE 232): the script's own stop, its
    // message as given; Lua's `error` refused, naming it.
    .{ .src = "function f() fail(\"no config in \" .. \"etc\") end\nf()", .line = 1, .column = 14, .function = "f", .class = .fail, .message = "no config in etc" },
    .{ .src = "error(\"x\")", .line = 1, .column = 1, .class = .refused, .message = "`error` is not in this language: `fail(msg)` stops the run with your message, and `attempt` catches it" },
    .{ .src = "local x = 1.5", .line = 1, .column = 11, .class = .refused, .message = "float literals are not in this language: integers only" },
    // Long strings (QUEUE 232): a level is required, and a syntax error
    // right after one says where it closed.
    .{ .src = "local s = [=[\nfirst\nsecond ]] ]=]\nlocal x = 1 // 0", .line = 4, .column = 13, .class = .arithmetic, .message = "integer division by zero" },
    .{ .src = "local s = [[a]]", .line = 1, .column = 11, .class = .refused, .message = "a long string needs a level: `[=[ ... ]=]` (code being edited is full of `]]`)" },
    .{ .src = "print([=[a]=]b]=])", .line = 1, .column = 14, .class = .syntax, .message = "expected `)` to close the call, found the name `b` (the long string at 1:7 closed at 1:11; if it holds `]=]`, open it with `[==[`)" },
    .{ .src = "local x = 0x10", .line = 1, .column = 11, .class = .refused, .message = "hexadecimal literals are not in this language: write the number in decimal" },
    .{ .src = "local x = a / b", .line = 1, .column = 13, .class = .refused, .message = "`/` divides into a float, and this language has no floats: use `//` (integer division)" },
    .{ .src = "s:upper()", .line = 1, .column = 2, .class = .refused, .message = "`:` method calls are not in this language: call a builtin, `f(x, ...)`" },
    .{ .src = "goto done", .line = 1, .column = 1, .class = .refused, .message = "`goto` is not in this language: `break` and `continue` leave or go round a loop" },
    .{ .src = "repeat x = 1 until x", .line = 1, .column = 1, .class = .refused, .message = "`repeat ... until` is not in this language: use `while`" },
    .{ .src = "local x = 2 ^ 3", .line = 1, .column = 13, .class = .refused, .message = "`^` (exponent) gives a float, and this language has no floats: multiply, `x * x`" },
    .{ .src = "local x = \"\\q\"", .line = 1, .column = 12, .class = .refused, .message = "an escape this language does not have: only \\n, \\t, \\r, \\0, \\xHH, \\\\, \\\" and \\'" },
    .{ .src = "local x = \"abc\n", .line = 1, .column = 11, .class = .syntax, .message = "a string runs past the end of its line: write \\n" },
    .{ .src = "local x = 99999999999999999999", .line = 1, .column = 11, .class = .syntax, .message = "an integer literal too big for 64 bits: they run from -9223372036854775808 to 9223372036854775807" },
    .{ .src = "local x = 1 @", .line = 1, .column = 13, .class = .syntax, .message = "a character no token starts with, `@`" },
    .{ .src = "const X = 1 X = 2", .line = 1, .column = 13, .class = .name, .message = "a `const` is never assigned: declare a `local` to change it" },
    .{ .src = "function f() const Y = 1 end", .line = 1, .column = 14, .class = .refused, .message = "`const` is a top-level statement only: a function or a block declares `local`s" },
    .{ .src = "print(g()) function g() return 1 end", .line = 1, .column = 7, .class = .name, .message = "no function `g` above this line: a function is called only after it is declared" },
    .{ .src = "local remove = 1 remove(\"x\")", .line = 1, .column = 18, .class = .refused, .message = "`remove` is a value here, not a function: a local, a parameter or a `const` of that name hides the function or builtin; name it otherwise" },
    .{ .src = "function attempt() end", .line = 1, .column = 1, .class = .name, .message = "`attempt` is the language's own: name the function otherwise" },
    .{ .src = "local r = attempt(nosuch)", .line = 1, .column = 19, .class = .name, .message = "`attempt` calls a function of the script declared above it, and there is no function `nosuch` above this line" },
    .{ .src = "local x = 1 + \"a\"", .line = 1, .column = 13, .class = .type, .message = "`+` takes integers, and its right is a string (`tonumber(s)` reads one from a string)" },
    .{ .src = "local x = \"a\" .. {}", .line = 1, .column = 15, .class = .type, .message = "`..` takes strings and integers, not an empty table" },
    .{ .src = "local x = 1 < \"a\"", .line = 1, .column = 13, .class = .type, .message = "`<` compares an integer with a string" },
    .{ .src = "local x = {} == {}", .line = 1, .column = 14, .class = .type, .message = "`==` on a list or a map is not in this language" },
    // Only the literal `nil` meets a map or a list (QUEUE 231): a value
    // that is nil when the line runs is still a value compared with it.
    .{ .src = "local m = {} local x = 1 local b = m == x", .line = 1, .column = 38, .class = .type, .message = "`==` on a list or a map is not in this language" },
    .{ .src = "local m = {} local x = nil local b = x ~= m", .line = 1, .column = 40, .class = .type, .message = "`==` on a list or a map is not in this language" },
    .{ .src = "local x = -\"a\"", .line = 1, .column = 11, .class = .type, .message = "`-` takes an integer, not a string" },
    .{ .src = "local x = #5", .line = 1, .column = 11, .class = .type, .message = "`#` takes a string or a list, not an integer" },
    .{ .src = "local l = {1} local x = l.a", .line = 1, .column = 26, .class = .type, .message = "a list's keys are integers: this one is a list, indexed by a string" },
    .{ .src = "local m = {a = 1} local x = m[1]", .line = 1, .column = 30, .class = .type, .message = "a map's keys are strings: this one is a map, indexed by an integer" },
    .{ .src = "local x = (5)[1]", .line = 1, .column = 14, .class = .type, .message = "only a list or a map can be indexed, not an integer" },
    .{ .src = "local l = {} l[3] = 1", .line = 1, .column = 15, .class = .index, .message = "index 3 is outside the list (length 0): only index 1 appends, and `push(l, x)` says so" },
    .{ .src = "local l = {} l[1] = nil", .line = 1, .column = 15, .class = .type, .message = "a list cannot hold nil" },
    .{ .src = "local m = {} m.k = nil", .line = 1, .column = 15, .class = .type, .message = "a map cannot hold nil (`m.k = nil` is an error: there is no remove)" },
    .{ .src = "local m = {a = 1} local x = m.b", .line = 1, .column = 30, .class = .index, .message = "no key \"b\" in the map (`has_key` asks first)" },
    .{ .src = "local l = {1, 2} local x = l[3]", .line = 1, .column = 29, .class = .index, .message = "index 3 is outside the list (length 2)" },
    .{ .src = "local l = {1} local x = l[0]", .line = 1, .column = 26, .class = .index, .message = "index 0 is outside the list (length 1)" },
    .{ .src = "local x = 1 // 0", .line = 1, .column = 13, .class = .arithmetic, .message = "integer division by zero" },
    .{ .src = "local x = 1 % 0", .line = 1, .column = 13, .class = .arithmetic, .message = "`%` by zero" },
    .{ .src = "local x = 9223372036854775807 + 1", .line = 1, .column = 31, .class = .arithmetic, .message = "9223372036854775807 + 1 overflows 64 bits" },
    .{ .src = "local x = -9223372036854775808 // -1", .line = 1, .column = 32, .class = .arithmetic, .message = "-9223372036854775808 // -1 overflows 64 bits" },
    .{ .src = "local x = -(-9223372036854775808)", .line = 1, .column = 11, .class = .arithmetic, .message = "negating -9223372036854775808 overflows 64 bits" },
    .{ .src = "for i = 1, 10, 0 do end", .line = 1, .column = 1, .class = .argument, .message = "a `for` with a step of 0 never ends" },
    .{ .src = "for x in 5 do end", .line = 1, .column = 10, .class = .type, .message = "`for x in` takes a list, given an integer" },
    .{ .src = "for x in {a = 1} do end", .line = 1, .column = 10, .class = .type, .message = "`for x in` a map: walk `keys(m)` instead" },
    .{ .src = "for i = \"a\", 2 do end", .line = 1, .column = 9, .class = .type, .message = "a `for`'s start must be an integer, not a string" },
    .{ .src = "print({})", .line = 1, .column = 7, .class = .type, .message = "`print` takes scalars, not an empty table: `for x in l do print(x) end` takes a list's items one by one" },
    .{ .src = "local x = tostring({})", .line = 1, .column = 11, .class = .type, .message = "`tostring` takes scalars, not an empty table: `for x in l do tostring(x) end` takes a list's items one by one" },
    .{ .src = "local x = tonumber(\"12a\")", .line = 1, .column = 11, .class = .argument, .message = "`tonumber`: \"12a\" is not an integer (an optional `-`, then decimal digits)" },
    .{ .src = "local x = split(\"a\", \"\")", .line = 1, .column = 11, .class = .argument, .message = "`split` by \"\" is an error: there is no empty separator" },
    .{ .src = "local x = sub(\"abc\", \"x\")", .line = 1, .column = 11, .class = .type, .message = "`sub`: its start must be an integer, not a string" },
    .{ .src = "local x = upper(1)", .line = 1, .column = 11, .class = .type, .message = "`upper`: its first argument must be a string, not an integer" },
    .{ .src = "local x = join({1, {}}, \",\")", .line = 1, .column = 11, .class = .type, .message = "`join` takes strings and integers, and item 2 is an empty table" },
    .{ .src = "local x = sort({1, \"a\"})", .line = 1, .column = 11, .class = .type, .message = "`sort` takes all integers or all strings, and item 2 is a string" },
    .{ .src = "local x = sort({{a = 1}, {b = 1}}, \"a\")", .line = 1, .column = 11, .class = .index, .message = "`sort`: item 2 has no \"a\"" },
    .{ .src = "local x = keys({1, 2})", .line = 1, .column = 11, .class = .type, .message = "`keys` takes a map, given a list (`#l` is a list's length)" },
    .{ .src = "local x = has_key({1}, \"a\")", .line = 1, .column = 11, .class = .type, .message = "`has_key` takes a map, given a list (`#l` is a list's length)" },
    .{ .src = "local x = count(5)", .line = 1, .column = 11, .class = .type, .message = "`count` takes a map or a list, not an integer" },
    .{ .src = "local x = push(5, 1)", .line = 1, .column = 11, .class = .type, .message = "`push` takes a list, not an integer" },
    .{ .src = "local x = seconds(\"2026-13-01\")", .line = 1, .column = 11, .class = .argument, .message = "`seconds`: \"2026-13-01\" is not an RFC 3339 time (2026-10-14T03:00:00Z, or +02:00 for Z) nor a date (2026-10-14)" },
    .{ .src = "local x = date(-1)", .line = 1, .column = 11, .class = .argument, .message = "`date`: -1 is outside 1970-01-01 to 9999-12-31" },
    .{ .src = "local x = human(\"a\")", .line = 1, .column = 11, .class = .type, .message = "`human`: its size must be an integer, not a string" },
    .{ .src = "local x = pad({}, 3)", .line = 1, .column = 11, .class = .type, .message = "`pad` takes a string or an integer, not an empty table" },
    .{ .src = "local x = table({{a = 1}}, {\"b\"})", .line = 1, .column = 11, .class = .index, .message = "`table`: row 1 has no \"b\"" },
    .{ .src = "local x = rep(\"a\", -1)", .line = 1, .column = 11, .class = .argument, .message = "`rep`: -1 times" },
    .{ .src = "local x = substitute(\"a\", \"\", \"b\")", .line = 1, .column = 11, .class = .argument, .message = "`substitute` of \"\" is an error: there is nothing to replace" },
    .{ .src = "local x = abs(-9223372036854775808)", .line = 1, .column = 11, .class = .arithmetic, .message = "abs(-9223372036854775808) overflows 64 bits" },
    .{ .src = "local x = min(1)", .line = 1, .column = 11, .class = .argument, .message = "`min` takes 2 to 4 arguments, given 1" },
    .{ .src = "local x = trim(\"a\", \"b\")", .line = 1, .column = 11, .class = .argument, .message = "`trim` takes 1 argument, given 2" },
    .{ .src = "local x = read(\"../auth/secret\")", .line = 1, .column = 11, .class = .argument, .message = "`read`: \"../auth/secret\" has a part (\"..\") that is not a name: no `.`, `..`, empty parts or characters FAT refuses" },
    .{ .src = "local x = read(\"/etc/passwd\")", .line = 1, .column = 11, .class = .argument, .message = "`read`: \"/etc/passwd\" is absolute: paths are relative to the data root" },
    .{ .src = "local x = ls(\"none\")", .line = 1, .column = 11, .class = .store, .message = "`ls(\"none\")`: not found (FileNotFound): `exists(p)` asks first" },
    .{ .src = "local x = read(\"none.txt\")", .line = 1, .column = 11, .class = .store, .message = "`read(\"none.txt\")`: not found (FileNotFound): `exists(p)` asks first" },
    .{ .src = "remove(\"none.txt\")", .line = 1, .column = 1, .class = .store, .message = "`remove(\"none.txt\")`: not found (FileNotFound): `exists(p)` asks first" },
    .{ .src = "local x = read(\"x\", -1)", .line = 1, .column = 11, .class = .argument, .message = "`read`: offset -1 is before the file's start" },
    .{ .src = "local x = walk(\"\", {deep = 1})", .line = 1, .column = 11, .class = .argument, .message = "`walk` takes `depth`, `like`, `kind`, `skip`, `after` and `keep_reads`, not `deep`" },
    .{ .src = "local x = walk(\"\", {keep_reads = -1})", .line = 1, .column = 11, .class = .argument, .message = "`walk`: `keep_reads` of -1: it is a count of reads" },
    .{ .src = "local x = walk(\"\", {depth = 0})", .line = 1, .column = 11, .class = .argument, .message = "`walk`: a depth of 0: 1 is the folder's own entries" },
    .{ .src = "local x = count_in(\"x\", \"\")", .line = 1, .column = 11, .class = .argument, .message = "`count_in` of \"\" is an error: there is nothing to look for" },
    .{ .src = "mkdir(\"\")", .line = 1, .column = 1, .class = .argument, .message = "`mkdir(\"\")` would act on the whole root: a change needs a path of at least one part" },
    .{ .src = "function f(n) return f(n + 1) end f(1)", .line = 1, .column = 22, .function = "f", .budget = .call_depth, .class = .budget, .message = "calls nest deeper than the call-depth budget (64)" },
    .{ .src = "while true do end", .line = 1, .column = 7, .budget = .steps, .class = .budget, .message = "the step budget (100000 steps) ran out" },
    .{ .src = "function g(x) return x + {} end print(g(1))", .line = 1, .column = 24, .function = "g", .class = .type, .message = "`+` takes integers, and its right is an empty table" },
    // Regular expressions (QUEUE 230): every construct the subset leaves out, refused by name.
    .{ .src = "local m = re_find(\"x\", \"a|b\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: `|` is not in this subset: no alternation; a class (`[ab]`) is one byte of several, or call `re_find` once for each" },
    .{ .src = "local m = re_find(\"x\", \"a{2}\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: `{n,m}` is not in this subset: write the part out as often as it must come (`\\d\\d\\d?`), or `\\{` for the byte" },
    .{ .src = "local m = re_find(\"x\", \"(?:a)\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: `(?` is not in this subset: no lookaround and no groups that do not capture" },
    .{ .src = "local m = re_find(\"x\", \"(a)(b)\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 4: one capture group a pattern: a second `(` is not in this subset (`\\(` is the byte)" },
    .{ .src = "local m = re_find(\"x\", \"(a(b))\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 3: one capture group a pattern: a second `(` is not in this subset (`\\(` is the byte)" },
    .{ .src = "local m = re_find(\"x\", \"a)\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: a `)` with no `(` before it: `\\)` is the byte" },
    .{ .src = "local m = re_find(\"x\", \"(a\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: a `(` that is never closed" },
    .{ .src = "local m = re_find(\"x\", \"[ab\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: a `[` that is never closed" },
    .{ .src = "local m = re_find(\"x\", \"*a\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: a `*`, `+` or `?` with nothing before it to repeat" },
    .{ .src = "local m = re_find(\"x\", \"a**\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 3: a repetition repeated (`a**`, `a+*`): one is enough" },
    .{ .src = "local m = re_find(\"x\", \"a*?\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 3: lazy repetition (`*?`, `+?`, `??`) is not in this subset: every repetition takes as much as it can" },
    .{ .src = "local m = re_find(\"x\", \"^*\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: `^` and `$` are places, not bytes: they cannot repeat" },
    .{ .src = "local m = re_find(\"x\", \"(a)\\\\1\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 4: backreferences (`\\1`) are not in this subset" },
    .{ .src = "local m = re_find(\"x\", \"\\\\bword\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: `\\b` is not in this subset: no word boundaries; `\\W` or `^` and `$` where the edge is a byte or the string's end" },
    .{ .src = "local m = re_find(\"x\", \"\\\\q\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 1: an escape this subset does not have: `\\d \\w \\s` (and `\\D \\W \\S`), `\\n \\t \\r`, or `\\` before a byte that is not a letter or digit" },
    .{ .src = "local m = re_find(\"x\", \"a\\\\\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: a pattern that ends in `\\`: `\\\\` is the byte" },
    .{ .src = "local m = re_find(\"x\", \"[z-a]\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: a range whose end is before its start (`z-a`): write it `a-z`" },
    .{ .src = "local m = re_find(\"x\", \"[[:alpha:]]\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 2: `[:alpha:]` and its kind are not in this subset: write the bytes (`[a-zA-Z]`), or `\\[` for the byte" },
    .{ .src = "local m = re_find(\"x\", \"[a-\\\\d]\")", .line = 1, .column = 11, .class = .argument, .message = "`re_find`'s pattern, at its byte 4: a range's end must be one byte, not a class" },
    .{ .src = "local m = re_match(\"x\", rep(\"a\", 257))", .line = 1, .column = 11, .class = .argument, .message = "`re_match`'s pattern is 257 bytes, and one may be at most 256" },
};

var out_buf: [4096]u8 = undefined;

test "errors: every wrong script in the corpus is told exactly what it is told here" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDir(io, "data", .default_dir);
    try tmp.dir.createDir(io, "auth", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "auth/secret", .data = "s" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data/x", .data = "hi\n" });
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    defer testing.allocator.free(root);

    var wrong: usize = 0;
    for (cases) |c| {
        var r = script.run(io, testing.allocator, root, c.src, .{ .steps = 100_000 }, 0, &out_buf);
        defer r.deinit();
        const s = r.stop orelse {
            std.debug.print("{s}\n  finished, and should stop: {s}\n", .{ c.src, c.message });
            wrong += 1;
            continue;
        };
        const same = s.line == c.line and s.column == c.column and s.class == c.class and s.budget == c.budget and
            std.mem.eql(u8, s.function, c.function orelse "") and std.mem.eql(u8, s.message, c.message);
        if (!same) {
            std.debug.print("{s}\n  want {d}:{d} ({s}) {s} {?s}: {s}\n  got  {d}:{d} ({s}) {s} {?s}: {s}\n", .{
                c.src,  c.line,   c.column,   c.function orelse "", @tagName(c.class),                       if (c.budget) |b| @tagName(b) else null, c.message,
                s.line, s.column, s.function, @tagName(s.class),    if (s.budget) |b| @tagName(b) else null, s.message,
            });
            wrong += 1;
        }
    }
    try testing.expectEqual(0, wrong);
}

test "errors: the corpus holds every class of stop" {
    var seen = std.EnumSet(script.diag.Class).initEmpty();
    for (cases) |c| seen.insert(c.class);
    var missing = std.EnumSet(script.diag.Class).initFull();
    missing.setIntersection(seen.complement());
    var it = missing.iterator();
    while (it.next()) |class| std.debug.print("no case of class {s}\n", .{@tagName(class)});
    try testing.expectEqual(0, missing.count());
}

// ── the call trail (metal-vmm QUEUE 229, chunk 1) ────────────────────────────

/// A call site in a trail as a case says it: the function the call is in
/// ("" at the top level), its line and column.
const Site = struct { function: []const u8, line: u32, column: u32 };

const TrailCase = struct {
    src: []const u8,
    /// Where it stopped, and in which function.
    line: u32,
    column: u32,
    function: []const u8,
    /// The call sites, innermost first: where the stopped function was
    /// called, then where that one was, out to the top level.
    trail: []const Site,
};

const trail_cases = [_]TrailCase{
    // A nested call: g stopped, called from f, called from the top.
    .{ .src = "function g(x) return x + {} end\nfunction f() return g(1) end\nprint(f())", .line = 1, .column = 24, .function = "g", .trail = &.{ .{ .function = "f", .line = 2, .column = 21 }, .{ .function = "", .line = 3, .column = 7 } } },
    // A recursion: the same function at every level, each its own site.
    .{ .src = "function r(n)\n  if n == 0 then return 1 // 0 end\n  return r(n - 1)\nend\nr(2)", .line = 2, .column = 27, .function = "r", .trail = &.{ .{ .function = "r", .line = 3, .column = 10 }, .{ .function = "r", .line = 3, .column = 10 }, .{ .function = "", .line = 5, .column = 1 } } },
    // A stop in the prelude, called from the script: the stop's own line is
    // the prelude's, and the trail says where the script called it.
    .{ .src = "function f() return count_all(\"none\", \"x\") end\nf()", .line = 0, .column = 16, .function = "the prelude's count_all", .trail = &.{ .{ .function = "f", .line = 1, .column = 21 }, .{ .function = "", .line = 2, .column = 1 } } },
    // At the top level: no trail.
    .{ .src = "local x = 1 // 0", .line = 1, .column = 13, .function = "", .trail = &.{} },
};

/// The 1-based line of the prelude that is `text`.
fn preludeLine(text: []const u8) u32 {
    var it = std.mem.splitScalar(u8, script.parse.prelude, '\n');
    var n: u32 = 1;
    while (it.next()) |l| : (n += 1) if (std.mem.eql(u8, l, text)) return n;
    unreachable;
}

fn trailRoot(io: std.Io, tmp: *testing.TmpDir) ![]u8 {
    try tmp.dir.createDir(io, "data", .default_dir);
    return std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
}

test "errors: a stop names every call between it and the top level, innermost first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try trailRoot(io, &tmp);
    defer testing.allocator.free(root);
    for (trail_cases) |c| {
        var r = script.run(io, testing.allocator, root, c.src, .{}, 0, &out_buf);
        defer r.deinit();
        const s = r.stop orelse return error.TestUnexpectedResult;
        // Line 0: the prelude's own line of `count_all`'s stat, wherever
        // the prelude has it.
        try testing.expectEqual(if (c.line == 0) preludeLine("  local size = stat(path).size") else c.line, s.line);
        try testing.expectEqual(c.column, s.column);
        try testing.expectEqualStrings(c.function, s.function);
        try testing.expectEqual(c.trail.len, s.trail.len);
        // `Stop.trail` is outermost first, as the calls were made.
        for (c.trail, 0..) |want, k| {
            const got = s.trail[s.trail.len - 1 - k];
            try testing.expectEqualStrings(want.function, got.function);
            try testing.expectEqual(want.line, got.line);
            try testing.expectEqual(want.column, got.column);
        }
    }
}

test "errors: the report keeps its first line, then says where each call was made" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try trailRoot(io, &tmp);
    defer testing.allocator.free(root);
    var r = script.run(io, testing.allocator, root, trail_cases[2].src, .{}, 0, &out_buf);
    defer r.deinit();
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try script.report(&r, "seq 7", &w);
    const want =
        \\── effects (0) ──
        \\── stopped at seq 7:{d}:16 (in `the prelude's count_all`): store: `stat("none")`: not found (FileNotFound): `exists(p)` asks first (
    ;
    var want_buf: [512]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, w.buffered(), try std.fmt.bufPrint(&want_buf, want, .{preludeLine("  local size = stat(path).size")})));
    try testing.expect(std.mem.endsWith(u8, w.buffered(), " steps)\n   called from seq 7:1:21 (in `f`)\n   called from seq 7:2:1\n"));
}

test "errors: a call site in the prelude is the prelude's line, and the report says so" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try trailRoot(io, &tmp);
    defer testing.allocator.free(root);
    // `walk_all` calls `walk`, a builtin: a script's own function of a
    // prelude function's name is the script's. So a prelude function that
    // calls a function of the script: none does; the line is held through
    // `walk_all`'s own builtin stop instead, with the script calling it.
    var r = script.run(io, testing.allocator, root, "local x = walk_all(\"none\", {})", .{}, 0, &out_buf);
    defer r.deinit();
    const s = r.stop.?;
    try testing.expectEqualStrings("the prelude's walk_all", s.function);
    try testing.expectEqual(@as(usize, 1), s.trail.len);
    try testing.expectEqualStrings("", s.trail[0].function);
    try testing.expectEqual(@as(u32, 11), s.trail[0].column);
}

test "errors: `attempt`'s failure gives the trail too, innermost first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try trailRoot(io, &tmp);
    defer testing.allocator.free(root);
    const src =
        \\function g() return 1 // 0 end
        \\function f() return g() end
        \\local a = attempt(f)
        \\print(#a.trail)
        \\for t in a.trail do print(t.in_function, t.line, t.column) end
        \\local b = attempt(f)
        \\print(#b.trail)
    ;
    var r = script.run(io, testing.allocator, root, src, .{}, 0, &out_buf);
    defer r.deinit();
    try testing.expectEqual(@as(?script.Stop, null), r.stop);
    try testing.expectEqualStrings("2\nf\t2\t21\n\t3\t11\n2\n", r.output);
}
