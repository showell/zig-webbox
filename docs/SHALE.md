# Shale

**Shale is a small language for a site's own data.** You use it to look
through the store and print what you find, then write a script that
changes things. It looks like Lua, with smaller semantics of its own. Every
effect goes through webbox's `store`, so a script does the same on Linux
and on bare metal. Every run stays inside its budgets.

A script **just runs.** Its effects happen as it goes. A run that stops
keeps what it already did, and its effects log says what that was. There
is no rollback; on Linux, git is the undo.

**For an agent choosing a tool** (in place of Python, sed or awk, on a code
checkout or any folder): [`SHALE-AGENTS.md`](SHALE-AGENTS.md). **The
budgets are the feature there:** every run is bounded in its steps, its
reads, its changes and **what it prints**, so its output is a bounded
context cost; a stop says where and why in one line, with the calls that
led there; and an `edit` says what it changes before it writes, as a
one-line summary, or the whole diff with `--verbose`.

This page is in three parts:
- **for a script's author:** a first script, what a run may do, the
  language, every builtin (one index, then each topic's table), the
  prelude, the store's paths, the budgets, and the cookbook;
- **for running one:** the runner, and the signed route on the live site;
- **for a host:** the Zig API, the contract a host holds a run to, the VM,
  `yield`, and the Zig stack.

It ends with what was decided and what was refused. The code is
`src/script/`.

## Before you send a script: the author's checklist

The traps the cookbook's scripts fell into on the live site, each with
what avoids it:

1. **Guard every budget a loop spends.** A loop over a walk or a file's
   parts runs until something stops it; let it be you. Walk with
   `walk_upto(p, opts, keep)`, which stops before the reads would leave
   fewer than `keep`, and guard each entry's work with `room_for({reads =
   1, read_bytes = n})`. Print what you have and `resume after <path>`
   (a `const START` takes it back), never nothing.
2. **Gather, then print? Print what you have when stopped.** A run that
   stops on a budget keeps its output so far: a script that gathers
   everything and prints at the end prints nothing at all.
3. **The index traps.** `l[0]` and `l[#l + 1]` are errors, and so is
   `m.k` for a key that is not there. On data you did not write, `get(t,
   k, default)` never stops the run; `has_key(m, k)` asks first.
4. **`parse_int` over `tonumber` for data.** `tonumber("log-x")` stops the
   whole report on one stray file; `parse_int` gives nil, and you decide.
5. **Read a `more` entry's `kind` first.** A `walk` part ends with `{kind
   = "more"}` when there is more: its path is where the next goes on, not
   a file. `walk_all` and `walk_upto` leave it out for you.
6. **A line is not 200 bytes.** `read(p, f, 200)` cuts a long line;
   `line_at(p, offset)` gives the whole line around an offset, and
   `read_lines` whole lines a part at a time.
7. **Look before you change.** On Linux, work in a git checkout, so a
   run's changes can be seen (`git diff`) and taken back; `edit` prints its
   diff before it writes. On metal there is no undo: rehearse a script on
   a copy of the data first (Steve, 2026-10-17).

When a run stops, its report names the line, and the calls that led
there:

```text
── stopped at seq 12:18:14 (in `the prelude's walk_all`): budget reads: the store-read budget (count) ran out (134718 steps)
   called from seq 12:31:15 (in `sizes`)
   called from seq 12:40:1
```

**Where it runs, and what it may do there:**

| where | modes | its budgets |
|---|---|---|
| lynrummy.com (`POST /admin/script`, angry-gopher's `admin_script`) | atomic (changes, holds the turn); background (reads only, in slices) | atomic: 2,000,000 steps, 500 reads, 16 MiB read, 100 changes, 8 MiB arena; background: the same but 10,000 reads |
| Dog Park (`POST /admin/script`, its `src/play/shale.zig`) | background only: an atomic run is refused | 50,000,000 steps, 10,000 reads, 256 MiB read, no changes, 8 MiB arena |
| an installed suite (`src/shale_suite.zig`) | background, on a schedule | the application's background budgets, its output at most 64 KiB |
| Linux, `shale` | atomic | Shale's defaults (the budgets' table), each settable with `--budget NAME=N` |

## A first script, step by step

Every block of Shale on this page runs as a test, on a store shaped like
angry-gopher's (the cookbook's below), at `now()` = 2026-10-14. What it
prints is under `-- prints:` (a tab shows as `<TAB>`), or how it stops
under `-- stops:`.

**Look before you change.** List what is at the root:

```shale
for name in ls("") do print(name) end
-- prints:
-- chat
-- games
```

**Walk a folder** to see everything under it, one store read per folder:

```shale
for e in walk("chat", {like = "*.md"}) do
  print(e.path, e.size)
end
-- prints:
-- chat/1_2/sessions/hello.md<TAB>293
-- chat/channels/general/sessions/lunch.md<TAB>87
-- chat/channels/general/sessions/plans.md<TAB>4166
-- chat/channels/random/sessions/misc.md<TAB>188
```

**Read only what you need.** Here, a count cache's first line and the
start of a transcript:

```shale
local cache = read("chat/1_2/sessions/hello.count")
print(words(lines(cache)[1])[1])     -- the cached message count
print(read("chat/1_2/sessions/hello.md", 0, 40))
-- prints:
-- 3
-- MSG_hello_1
-- from: steve
-- date: 2026-10-13
```

**Count without holding a file.** A message is a block, and blocks are
joined by the separator:

```shale
local sep = "\n\n-------------\n"
print(count_in("chat/1_2/sessions/hello.md", sep) + 1)
-- prints:
-- 3
```

**Then change something.** The effects log lists every change with its
outcome:

```shale
mkdir("shale-check")
replace("shale-check/note.txt", "written at " .. date(now()) .. "\n")
print(read("shale-check/note.txt"))
-- prints:
-- written at 2026-10-14T00:00:00Z
--
```

**Survive one bad file** with `attempt`, which turns an error into a
value:

```shale
function size_of(path) return tonumber(words(read(path))[1]) end
replace("chat/1_2/sessions/torn.count", "x y\n")
for e in walk("chat", {like = "*.count"}) do
  local r = attempt(size_of, e.path)
  if r.ok then print(e.path, r.value) else print(e.path, "unreadable:", r.class) end
end
-- prints:
-- chat/1_2/sessions/hello.count<TAB>3
-- chat/1_2/sessions/torn.count<TAB>unreadable:<TAB>argument
-- chat/channels/general/sessions/lunch.count<TAB>1
-- chat/channels/general/sessions/plans.count<TAB>40
```

**A name that is a value can't be called:**

```shale
local remove = 1
remove("chat/1_2/sessions/hello.md")
-- stops: refused
```

Three things a first script needs to know, each said again below:
- **Paths are from the data root,** `""` is the root itself, and no path
  leaves it ("The store").
- **A function sees only its own parameters and locals, and the `const`s
  above it,** never the script's `local`s: give it what it needs as
  arguments, or as a `const` (Names).
- **A big file is read or scanned in parts:** one call brings at most a
  megabyte. The prelude's `walk_all`, `count_all` and `find_next` do the
  parts for you (The prelude).

## What a run may do: atomic or background

The host chooses, not the script; a signed request names it
(`mode=background`, or none for atomic):

| | atomic | background |
|---|---|---|
| when it runs | whole, inside one request, holding the site's other requests up | in slices between requests: a slice ends after any store call or a number of steps |
| may change the store | yes | **no**: `replace`, `append`, `mkdir`, `remove` and `remove_tree` stop it, an `argument` error naming `atomic` |
| its budgets on the live sites | the site's own, small: lynrummy.com's 500 reads, 16 MiB read, 2M steps | the background's, larger: 10,000 reads (Dog Park's, `budgets` in its `src/play/shale.zig`) |

- **The runner** (`shale`, `zig build script`, below) runs atomic, with
  Shale's default budgets, each of which `--budget NAME=N` sets (the
  table in "The budgets").
- **Dog Park takes background runs only.** lynrummy.com's route runs
  both: atomic ones, and background ones its host steps between requests
  (since v32, metal-vmm QUEUE 222; angry-gopher
  `admin_script.background_budgets`).
- A script can ask what is left with `budget()`, but not which mode it is
  in: write a script that changes nothing when it may run either way.

## The language

### Statements

- `local x = e`, or `local x` (nil).
- `x = e`, `t[k] = e`, `t.k = e`.
- `if c then ... elseif c then ... else ... end`.
- `while c do ... end`.
- `for i = a, b[, step] do ... end`. The step defaults to 1; a step of 0
  is an error. A loop that would go past the largest integer stops there.
- `for x in list do ... end`. It visits the first `#list` items, `#list`
  as it was when the loop began. An item pushed during the loop is not
  visited; an item changed during the loop is seen as it is when the loop
  reaches it. Nothing is copied.
- `break`, and `continue` (the loop's next turn). Each acts on its own
  loop, the innermost.
- `do ... end`.
- `return [e]`, the last statement of its block. At the top level it ends
  the script.
- `function name(a, b) ... end`, at the top level only. A function may
  recurse, and **is called only after it is declared**, as in Lua: a call
  above the declaration is an error (or, for a builtin's name, the
  builtin). **A call gives every parameter**, or it is an error when the
  script is parsed, **except an optional one**: `function f(a, b?)`
  marks `b` optional, the optional ones last, and a call that leaves one
  out gives it nil (`f(1)` is `f(1, nil)`). An options map is the usual
  one (`re_lines(s, p, opts?)`).
- `const NAME = e`, at the top level only. The name is never assigned
  again, and the functions declared after it see it. A table it names can
  still change. A function that reads a const before its line has run
  stops with an error.


**No separator is needed** between statements: `local x = 1 local y = 2`
is two statements on one line. A `;` may stand between them.

**Two functions cannot call each other** (mutual recursion): the first
one's call to the second is above the second's declaration, a
`name` error when the script is parsed:

```shale
function is_even(n) if n == 0 then return true end return is_odd(n - 1) end
function is_odd(n) if n == 0 then return false end return is_even(n - 1) end
-- stops: name
```

Write it as one function that recurses, with a parameter saying which
of the two it is being:

```shale
function parity(n, even)
  if n == 0 then return even end
  return parity(n - 1, not even)
end
print(parity(4, true), parity(3, true))
-- prints:
-- true<TAB>false
```

### Values

| type | |
|---|---|
| `nil` | |
| booleans | `true`, `false` |
| integers | 64-bit and checked: overflow stops the script. Literals are decimal. The smallest, `-9223372036854775808`, is written with its minus; its magnitude alone is too big |
| strings | bytes, `"..."` or `'...'`. The escapes are `\n \t \r \0 \xHH \\ \" \'`. A string ends on its line; a long string does not |
| lists | `{1, 2}`, indexed from 1 |
| maps | `{a = 1, ["b c"] = 2}`, read as `m.a` or `m["a"]`; keys are strings, kept in the order first set |

**Long strings, for text that holds quotes and lines** (metal-vmm QUEUE
232): `[=[ ... ]=]`, `[==[ ... ]==]`, a level of one or more `=`, closed by
`]`, the same number of `=`, `]`. **A level is required**: `[[` is refused,
since code being edited is full of `]]`. The bytes are the source's, raw:
no escapes, a CRLF kept as its two bytes; a newline right after the opener
is dropped (a CRLF one whole), and a newline before the closer is part of
the string. A syntax error right after a long string says where it closed
and the level that would hold what closed it.

```shale
local old = [=[
if (x[i]] == "a\n") {
]=]
print(#old, sub(old, 1, 9), contains(old, "\\n"))
-- prints:
-- 22<TAB>if (x[i]]<TAB>true
```

`{}` takes its kind, list or map, from its first entry; using it as the
other kind after that is an error. **Tables are shared, not copied:**
`local b = a` names the same list. Functions are not values.

**An empty `{}` is both until its first entry.** `#keys({})` is 0,
`has_key({}, "a")` is false, `for x in {}` runs no turns, `sort` of it does
nothing, and `push` makes it a list; once it holds a key, it is a map, and
`push` on it is a `type` error.

### Operators

From the loosest to the tightest:

| | |
|---|---|
| `or` | short-circuits, and returns an operand |
| `and` | short-circuits, and returns an operand |
| `== ~= < <= > >=` | |
| `..` | right-associative; joins strings and integers |
| `+ -` | |
| `* // %` | `//` and `%` floor, as Lua's do |
| `not - #` (unary) | `#` is a string's length in bytes, or a list's length |

- **Truth:** only `nil` and `false` are false.
- **Comparison:** `==` across types is false; `<` across types is an
  error; `==` on a list or a map is an error, **but for the written `nil`**:
  `m == nil` and `nil ~= m` are as for any value (QUEUE 231), so a result
  that is a map or nil (`re_find`) is told by `if m == nil`. A local that
  holds nil is still a value: `m == x` with a map stops whatever `x` is.
  Strings compare byte by byte.
- **A chain of `..` is joined once.** `a .. b .. c` evaluates every part
  left to right, then makes one string. When the first part is the string
  the previous chain made, and its buffer has room, the rest is written
  after it in place. So `s = s .. x` in a loop is linear, not quadratic,
  in time and in arena. No string ever changes: the room is past the end
  of every string that shares the buffer. A part that is not a string or
  an integer is a `type` error at the `..` before it (the first part's,
  at the chain's first `..`), as the nested joins would have said.
- **Operands of the wrong kind stop the script,** a `type` error: `+ - *
  // %` and unary `-` take integers only (`"1" + 1` and `nil + 1` stop:
  `tonumber(s)` reads an integer from a string); `#` takes a string or a
  list (`count(m)` for a map); `..` takes strings and integers (not a
  boolean or nil); a string cannot be indexed (`sub(s, i, i)`).
- **Comparisons do not chain:** `1 < 2 < 3` compares `true` with 3, a
  `type` error.
- **`//` and `%` floor:** `-7 // 2` is -4 and `-7 % 3` is 2.

### Names

- There are no globals: an undeclared name is an error, found when the
  script is parsed.
- Locals are block-scoped. `local x = x` reads the outer `x`.
- A function sees only its own parameters and locals, and the `const`s
  declared above it, never the script's `local`s.
- **A call is resolved where it stands,** in this order:
  1. a name that is a value there (a local, a parameter, a `const`) is
     **refused**: `local remove = 1  remove("d/s.txt")` is an error, not a
     deletion;
  2. the script's own function, declared **above** the call (or the one
     being declared, which may call itself);
  3. the builtin;
  4. Lua's library names, refused with what to write instead.

  A function declared later never takes over an earlier call. So **a
  builtin added to the language never changes what a script does**: an
  old script's call by that name was already its own function, above it,
  or an error.
- **A script's names may take a builtin's,** as a local, a parameter, a
  const or a function. Two exceptions, for functions and calls only (a
  local may take either name):
  - Lua's library names (`pairs`, `pcall`, `string`, ...): no function
    takes one, and a call by one is refused, kept to say what to write
    instead;
  - `attempt`: no function takes it, and a call by it is the language's.

  **`table` is both** a builtin and one of Lua's library names, and the
  order above settles it: `table(rows, columns)` is the builtin (step 3),
  `table.insert(l, x)` is refused with `push(l, x)` to write instead, a
  function may not be named `table`, and a local or a key may (`x.table`
  is any map's key). **`type` is only refused:** this language has no
  `type()`, and a value's kind is known from where it came (`stat(p).kind`
  for the store's).
- Keywords: `and break const continue do else elseif end false for
  function if in local nil not or return then true while`.

### Errors, not nil

Each of these stops the script:
- reading a missing map key (`has_key(m, k)` asks first), or a list index
  out of range;
- `m.k = nil` (there is no remove);
- `nil` put in a list, or a list index other than `#l + 1` written past
  its end;
- a table literal that mixes positional and keyed entries;
- division or `%` by zero, overflow, and the smallest integer `// -1`.

**A stop says where:** its line and column, its class, and the function it
was in. The classes are:

| class | |
|---|---|
| `syntax` | not a sentence of the language |
| `refused` | Lua has it and this language does not (named) |
| `name` | a name not declared, or declared twice in one scope |
| `type` | a value of the wrong type for what was done with it |
| `index` | a missing key, or an index out of range |
| `arithmetic` | overflow, or division by zero |
| `argument` | a builtin or function given the wrong arguments |
| `store` | a store call failed (it names the path) |
| `budget` | a budget ran out (it names which) |
| `fail` | the script's own: `fail(msg)`, its message as given (QUEUE 232) |

**How a stop reads,** on the runner and in the route's reply:

```text
── stopped at <script>:<line>:<column> (in `<function>`): <class>[ <budget>]: <message> (<steps> steps)
   called from <script>:<line>:<column> (in `<caller>`)
   called from <script>:<line>:<column>
```

`(in ...)` is there when it stopped inside a function, `<budget>` when a
budget stopped it, and a function of the prelude is named "the prelude's
<name>", its line the prelude's.

**The trail** (metal-vmm QUEUE 229): after a stop inside a function, one
`called from` line for each call that led there, innermost first, out to
the top level, whose line has no `(in ...)`. A call made inside a prelude
function reads `called from the prelude:<line>:<column>`, its line the
prelude's. So a budget that runs out in the prelude's `walk_all` names the
line of the script that called it:

```text
── stopped at seq 12:18:14 (in `the prelude's walk_all`): budget reads: the store-read budget (count) ran out (134718 steps)
   called from seq 12:31:15 (in `sizes`)
   called from seq 12:40:1
```


**The message says what to do.** Each one names what was wrong and, where
there is one, the way that works: a store error gives its plain words, its
name and what asks first (`` `read("none.txt")`: not found (FileNotFound):
`exists(p)` asks first ``); a budget gives its number. The golden corpus,
`src/script/errors_test.zig`, holds a wrong script of every kind and the
exact class, place and message it gets, so a message changed is a line
changed in review.

### `attempt`: surviving one bad file

```shale
function half(n) return tonumber(n) // 2 end
local good = attempt(half, "10")
local bad = attempt(half, "ten")
print(good.ok, good.value)
print(bad.ok, bad.class, bad.line, bad.in_function)
-- prints:
-- true<TAB>5
-- false<TAB>argument<TAB>1<TAB>half
```

`attempt` calls the script's function `f` with the arguments. The
arguments are evaluated first, outside the attempt, as Lua's `pcall` does.
It gives back a map:
- `{ok = true, value = v}` when `f` returned (with no `value` if it
  returned nil);
- or `{ok = false, error = "...", class = "store", line = 12, column = 9,
  in_function = "f", trail = {...}}`. `trail` is the stop's calls,
  innermost first, as the report's `called from` lines: a list of `{line,
  column, in_function}` maps, out to the top level: the `attempt`
  itself is one of them, the call of `f`, and the calls before it.

**It catches a `fail`** as any other error: `fail(msg)` is how a function
says it could not do what it was asked, and `attempt` gives `class =
"fail"`, `error = msg`.

Two things it does not do:
- **It never catches a budget.** A budget is the run's, not the call's, so
  a run that runs out stops wherever it is.
- **It undoes nothing.** Whatever `f` did before its error stays done: its
  output, and its changes in the effects log.

- **It calls a function of the script's,** declared above it: never a
  builtin directly. Wrap one in a function of your own, as `size_of` above
  wraps `read`.
- **A failed attempt has no `value`;** read it after `r.ok`, or
  `has_key(r, "value")` (a function that returned nil has none either).

### Refused, each by name

- floats and `/`;
- `^`, hex literals and the bitwise operators;
- a long string or a block comment without a level (`[[ ... ]]`,
  `--[[ ... ]]`);
- decimal escapes (`\65`), `\u{...}`, `\z` and the rest;
- `:` method calls;
- `...`;
- `goto` and `repeat`;
- several locals, several loop names, multiple assignment and multiple
  returns;
- function values, nested functions and `local function`;
- `string.`, `table.`, `pairs`, `ipairs`, `pcall`, `require` and the rest
  of Lua's library.

What to write instead of Lua's: `push(l, x)` for `table.insert`;
`for x in l` and `for k in keys(m)` for `ipairs` and `pairs`; `attempt(f,
...)` for `pcall`; `sub`, `find`, `split`, `upper`, `lower`, `rep` for
`string.`'s; `join` for `table.concat`; `count(m)` for `#` of a map.

### The grammar

```ebnf
script    = { stat } ;
stat      = "local" NAME [ "=" expr ]
          | "const" NAME "=" expr                         (top level)
          | target "=" expr
          | call
          | "if" expr "then" block { "elseif" expr "then" block } [ "else" block ] "end"
          | "while" expr "do" block "end"
          | "for" NAME "=" expr "," expr [ "," expr ] "do" block "end"
          | "for" NAME "in" expr "do" block "end"
          | "function" NAME "(" [ NAME { "," NAME } ] ")" block "end"   (top level)
          | "do" block "end"
          | "break" | "continue"
          | "return" [ expr ]                             (last in its block)
          | ";" ;
block     = { stat } ;
target    = NAME | value "[" expr "]" | value "." NAME ;
expr      = expr binop expr | unop expr | value ;
value     = primary { "[" expr "]" | "." NAME } ;
primary   = "nil" | "true" | "false" | INT | STRING | NAME | call
          | "(" expr ")" | "{" [ field { ( "," | ";" ) field } [ "," | ";" ] ] "}" ;
call      = NAME "(" [ expr { "," expr } ] ")"
          | "attempt" "(" NAME { "," expr } ")" ;
field     = expr | NAME "=" expr | "[" STRING "]" "=" expr ;
binop     = "or" | "and" | "==" | "~=" | "<" | "<=" | ">" | ">=" | ".."
          | "+" | "-" | "*" | "//" | "%" ;
unop      = "not" | "-" | "#" ;
```

`--` starts a comment that runs to the end of its line; `--[=[ ... ]=]`,
at any level of `=` as a long string, is a block comment (`--[=x` is a
line comment). A `STRING` is
`"..."`, `'...'` or a long string, `[=[ ... ]=]` at any level of `=`.

## The builtins

**What a builtin costs:**
- **Steps.** Every builtin charges steps in proportion to the work it does:
  a step for each byte or item it touches, except **bulk byte work, a
  step for every 16 bytes** (or part of 16): what a `read` brings, what a
  scan (`count_lines`, `count_in`, `find_in`) looks at, and the haystack
  a search (`find`, `contains`, `starts_with`, `ends_with`, `split`,
  `substitute`) runs over. **A search also pays for what it finds:** a
  step for every place its fast pass stops (a match, or a first byte that
  begins one), and a step for 16 bytes it compares there, so a match every
  byte costs a step a match and a long near-match pays for its compares.
  Measured in ReleaseSafe, the worst shapes a cold review found (a
  substitution matching every byte, scans of a file of newlines, of prose
  for a space, near-matches) run at 10 to 24 ns a step, against 7 to 15
  ns for the interpreter's own steps (they ran at 67 to 713 before
  matches were charged). The operators are held to it too: a map's key is charged its
  length wherever it is hashed. A sort is charged its bound before it
  runs (n log n comparisons, and every byte in each of the log n passes).
  `charge_test.zig` holds every builtin and operator to this: its own
  steps at N and at 4N must grow by at least a step a unit (a step for 16,
  for bulk work). The ones whose work does not grow say why.
- **Reads** count store calls that look, and **read bytes** the bytes they
  bring.
- **Changes** count store calls that change, and **change bytes** the bytes
  they write.

The arguments' types are checked, and a wrong one is a `type` error that
names the builtin and the argument.

### Every builtin, at a glance

Each in its topic's table below, with what it costs. A wrong argument's
type is a `type` error, a wrong count of arguments an `argument` error;
the errors column says the rest.

| builtin | gives | errors (besides a wrong type or count) |
|---|---|---|
| `ls(p)` | a folder's names, sorted | `store` |
| `stat(p)` | `{size, kind, modified}` | `store` |
| `exists(p)`, `is_dir(p)` | booleans | `store` (never for absence) |
| `read(p[, offset[, n]])` | a file, or its part | `argument` past the call-bytes cap; `budget read_bytes`; `store` |
| `read_or(p, default)` | a file, or `default` when nothing is there | as `read`; a folder is `store` |
| `read_lines(p[, offset[, n]])` | `{lines, next, done}`: whole lines from `offset` | `argument` for `n` past the call-bytes cap or a line longer; `store` |
| `line_at(p, offset)` | the line holding `offset`, or nil past the end | `argument` for a line past the call-bytes cap; `store` |
| `grep(p, s)` | the lines holding `s`, as `{line, text}` | `argument` for a file past the call-bytes cap; `store` |
| `edit(p, old, new[, opts])`, `edit(p, {{old, new}, ...})` | the number replaced, the diff printed first | `argument` for `old` not there, or there twice without `all`; as `replace` |
| `count_lines(p[, offset[, n]])` | the lines in a file or a range | `argument` past the cap; `store` |
| `count_in(p, s[, offset[, n]])` | `s`'s occurrences in a file or a range | `argument` for "" or past the cap; `store` |
| `find_in(p, s[, offset[, n]])` | the first `s`'s 0-based offset, or nil | as `count_in` |
| `walk(p[, opts])` | the entries under `p`, a part at a time | `argument` for an unknown option or a bad `after`; `store` |
| `replace(p, s)`, `append(p, s)` | a file written whole, or added to | `store`; in a background run, `argument` |
| `mkdir(p)`, `remove(p)`, `remove_tree(p)` | a folder made; a file or a tree removed | `store` (a missing path too); in a background run, `argument` |
| `split(s, sep)`, `lines(s)`, `words(s)` | lists of strings | `argument` for `sep` = "" |
| `join(l, sep)` | one string | `type` for an item not a string or integer |
| `starts_with`, `ends_with`, `contains` `(s, t)` | booleans | |
| `find(s, t)` | `t`'s 1-based position, or nil | |
| `sub(s, i[, j])` | a part of `s` | |
| `trim`, `upper`, `lower` `(s)` | strings | |
| `like(s, pattern)` | a boolean | |
| `match_path(path, pattern)` | a boolean | `argument` past 64 parts |
| `between(s, a, b)` | the text between, or nil | |
| `re_find(s, pattern[, {nocase}])` | the leftmost match, `{at, text[, group]}`, or nil | `argument` for a pattern past 256 bytes or with what the subset leaves out |
| `re_match(s, pattern[, {nocase}])` | a boolean: whether `s` holds a match | as `re_find` |
| `rep(s, n)` | `s`, `n` times | `argument` for `n` < 0 |
| `substitute(s, old, new)` | `s` with each `old` replaced | `argument` for `old` = "" |
| `path(a, b, ...)` | the parts joined with `/` | |
| `basename(p)`, `strip_suffix(s, t)` | strings | |
| `tostring(v)` | a scalar's text | `type` for a list or map |
| `tonumber(s)` | an integer | `argument` for anything but digits |
| `parse_int(s)` | an integer, or nil | none: anything but an integer is nil |
| `min`, `max` `(a, b[, c[, d]])` | integers | `argument` for one or more than four |
| `abs(n)` | an integer | `arithmetic` for the smallest |
| `date(seconds)`, `seconds(text)` | each other's inverse | `argument` out of range or unreadable |
| `human(bytes)`, `pad(v, width)`, `table(rows, columns)` | text | `index` for a row missing a column |
| `push(l, x)` | nil | `type` for a map or for nil |
| `sort(l)`, `sort(rows, key[, "asc" or "desc"])` | nil: in place | `type` for mixed kinds; `index` for a row with no `key`; `argument` for another order |
| `take(l, n)` | a new list of the first `n` | `argument` for `n` < 0 |
| `last(l, n)` | a new list of the last `n` | `argument` for `n` < 0 |
| `reverse(l)` | nil: in place | |
| `keys(m)`, `has_key(m, k)`, `count(t)` | a list; a boolean; an integer | |
| `get(t, k[, default])` | `t[k]`, or `default` where there is none | `type` for a key of the wrong kind |
| `now()`, `budget()` | the host's time; what is left | |
| `print(...)` | nil | `type` for a list or map |
| `yield()` | nil | |
| `arg(name[, default])` | the run's value by that name, or `default` | `argument` for a value not of an integer or boolean default's kind |
| `fail(msg)` | never returns: the run stops | `fail`, with `msg` |
| `attempt(f, ...)` | `{ok, value}` or `{ok = false, error, class, line, column, in_function, trail}` | (the language's own: see `attempt`) |
| the prelude's `walk_all(p, opts)`, `walk_upto(p, opts, keep)`, `count_all(p, s)`, `find_next(p, s, at)`, `room_for(need)`, `glob(pattern[, {hidden}])`, `drop(l, n)` | every entry; as many as the reads allow; every occurrence; the next one; whether the budgets hold `need`; the files a glob names; all but the first `n` | as `walk`, `count_in`, `find_in`, `match_path` |

### The store

| builtin | gives | costs | errors |
|---|---|---|---|
| `ls(p)` | the names in a folder, sorted | a read; a step an entry, and the sort | `store`: missing, or not a folder |
| `stat(p)` | `{size, kind, modified}`. `kind` is `"file"`, `"directory"` or `"other"`. `modified` is in seconds since 1970, as the host keeps it: metal's FAT to 2 s, and 0 where it keeps none | a read | `store` |
| `exists(p)` | whether anything is there | a read | `store`, only for a failure other than absence |
| `is_dir(p)` | whether a folder is there | a read | `store` |
| `read(p)` | the whole file | a read; each byte a read byte, and a step for 16 | `argument` for a file over the call-bytes cap (1 MiB): read it in parts; `budget read_bytes` when the file is longer than what is left; `store` |
| `read_or(p, default)` | the whole file, or `default` when nothing is at `p` | one read: where `exists` then `read` was two; its bytes as `read`'s | as `read`; a folder is `store` |
| `read(p, offset[, n])` | `n` bytes from byte `offset`, or to the end; fewer where the file ends, and "" from its end or past it. **Offsets are 0-based**, as the site's sidecars count them | a read; only those bytes | `argument` for a negative offset or count, or for more than the call-bytes cap; `store` for a folder or a missing file |
| `read_lines(p[, offset[, n]])` | `{lines, next, done}`: the whole lines from byte `offset` (0 unset), at least `n` bytes (64 KiB unset) and on to the end of the line it stops in, so no line is cut; `lines` as `lines` splits them; `next` where the next part starts; `done` whether that is the file's end. `offset` is a line's start, as `next` is | a read; the part's bytes, and up to 512 past it for the last line's end; the whole part at most the call-bytes cap | `argument` for a negative offset, `n` under 1 or past the cap, or a line longer than the cap; `store` |
| `grep(p, s)` | the lines of the file holding `s`, a literal, as `{line, text}`, `line` 1-based, in order, a line once however often it holds `s` | a read; the file whole, a step for 16 bytes, and each line kept a step a byte. At most the call-bytes cap: a bigger file goes through `read_lines` | `argument` for `s` empty or a file past the cap; `store` |
| `edit(p, old, new[, {all, word}])` | the number of occurrences of `old` replaced by `new`; **the change's diff is printed first** (unified: `--- a/p`, `+++ b/p`, a hunk for the lines each occurrence is on). `old` must be in the file once, unless `all`; `word` takes only whole words (no letter, digit or `_` either side). Logged as `edit`. **Where the host says `summary`** (`Options.diffs`; the Linux CLI unless `--verbose`), the diff is one line, `edit p: N hunks, -O +N lines`, printed where the diff is, before the change budgets are checked; the hunk walk is charged as in full, and only the writes' charge goes. **`edit(p, {{old = ..., new = ...[, all = true][, word = true]}, ...})`**, its list form (metal-vmm QUEUE 232): at most 64 edits a call, in sequence, each to the file as the one before left it, each held to the rules above; one diff, from the file as it was to the file as the last edit left it; one write. An edit that fails stops the run with nothing printed and nothing written, and its error says which edit it was | a read, the file whole (at most the call-bytes cap), a step for 16 bytes, each edit; then `replace`'s change | `argument` for `old` empty, not there, or there more than once without `all`, and for an edit with no `old` or `new` or another key; `type` for an edit not a map; as `read` and `replace` |
| `line_at(p, offset)` | the whole line holding byte `offset`, without its newline (a newline is its own line's last byte); nil at the file's end or past it | a read; the line, read back and on from `offset` 512 bytes at a time, then once more whole | `argument` for a negative offset or a line longer than the call-bytes cap; `store` |
| `count_lines(p[, offset[, n]])` | the lines in a file, as `#lines(read(p))` counts them. **Of a range**, `n` bytes from `offset` (or to the end), the newlines in it and, if it reaches the end, a last line without one: the parts' counts add up to the whole's | a read; each byte a read byte, and a step for 16; a step a line; one buffer of 128 KiB for every scan of the run, whatever the file's size, the needle's length and however many files | `argument` for a range (the whole file, without one) over the call-bytes cap (1 MiB): scan it in parts; `store` |
| `count_in(p, s[, offset[, n]])` | how many times `s` occurs, none overlapping; of a range, the matches that start in it, each read to its end (at most `#s - 1` bytes past the range). The parts add up to the whole's unless a match that runs past a part's end overlaps one the next part counts, which only a needle that overlaps itself (`aa`) can do | as `count_lines`, and a step for each match, or first byte of one, it stops at | `argument` for "" or a needle over 64 KiB, or as `count_lines` |
| `find_in(p, s[, offset[, n]])` | the 0-based offset of the first `s`, a `read` offset, or nil; of a range, the first that starts in it, so a file found in parts gives what the whole file's would | as `count_in`, stopping at the first | as `count_in` |
| `walk(p[, opts])` | every entry under `p`, depth first, each folder's names sorted and a folder before what it holds, as `{path, size, kind, modified}`, `path` from the root. A folder's size is 0. A symlink is `"other"` (size and `modified` 0) and is never entered | **a read a folder listed and an entry stat'ed** (each a store call, a disk command on metal); a step an entry and each path's bytes. **At most `call_entries` (256) entries a call**: with more to come, the list ends with `{path, kind = "more"}`, and `walk(p, {after = that path})` goes on from it: the prelude's `walk_all` does the parts ("The prelude"). The `more` entry is always the part's last, `kind` and `like` keep it, and its `size` and `modified` are 0. A background run passes by an entry gone between its folder's listing and its stat | `store`; `argument` for an unknown option, or an `after` not under `p` |
| `replace(p, s)` | writes the file whole: never a torn file. There is no plain `write` | a change; each byte a change byte and a step | `store`, logged |
| `append(p, s)` | adds to the end | as `replace` | `store`, logged |
| `mkdir(p)` | a folder, and its parents | a change | `store`, logged |
| `remove(p)`, `remove_tree(p)` | a file, or a folder and everything in it | **a change, however big the tree**: its size is the store's to bound (its depth, the volume), and a script may call it at most `changes` times | `store` for a missing path (logged). A tree the store fails partway through is logged as one effect with the store's error, and what it had removed by then is gone |

**`walk`'s options:**
- `depth`: 1 lists only the folder's own entries, which is `ls` with each
  entry's stat, and a walk that stops there reads fewer folders.
- `like`: a pattern for the entries' names (`like` below). Folders are
  walked into whether they match or not.
- `kind`: `"file"`, `"directory"` or `"other"`.
- `skip`: a pattern (`like`'s) for names passed by whole: neither given
  nor walked into, nor stat'ed (QUEUE 229: `skip = ".*"` passes by `.git`
  and `.zig-cache`; the prelude's `glob` uses it).
- `after`: where an earlier call's part ended (its `more` entry's path,
  or "" for the start). The walk goes on after it in its own order, the
  path there or not: each folder on it is listed again, and the walk
  takes the first name past it. In parts, a walk gives each entry once.
- `keep_reads`: the reads to keep for the rest of the run (QUEUE 229).
  The part ends with its `more` entry before an entry could leave fewer:
  an entry takes at most two (its stat, and a folder's listing). With no
  room for the walk's own listings and one entry, it reads nothing and
  gives only `{kind = "more"}` at `after`. The prelude's `walk_upto` uses it.

An entry that `like` or `kind` leaves out is never stat'ed.

**One listing is one call, whatever the folder's size.** An `ls`, or a
walk's listing of a folder, reads the whole folder in that call: on metal,
all its directory sectors; and only a walk's stats are capped. How big a
folder grows is the application's to bound (the box's cold review of 214,
dropped as a cap: a site keeps its folders small).

### Text

Plain text everywhere: **not Lua's patterns.** Positions in strings are
1-based, as Lua's are. **Every search is charged by its work**
(`find`, `contains`, `split`, `substitute`, and the store's scans): the
haystack a step for 16 bytes, every place the search stops at a step, and
the bytes compared there a step for 16 (see "What a builtin costs").

| builtin | gives |
|---|---|
| `split(s, sep)` | the pieces between each `sep`; `sep` = "" is an error |
| `lines(s)` | `s` split at each `\n`, with no last empty piece after a final newline: `#lines("a\nb\n")` is 2 |
| `words(s)` | the runs between ASCII whitespace, none empty |
| `join(list, sep)` | strings and integers, joined |
| `starts_with(s, t)`, `ends_with(s, t)`, `contains(s, t)` | booleans |
| `find(s, t)` | where `t` first is in `s`, 1-based; nil when absent |
| `sub(s, i[, j])` | Lua's: 1-based, inclusive, negatives counted from the end, clamped |
| `trim(s)`, `upper(s)`, `lower(s)` | ASCII only |
| `like(s, pattern)` | whether the whole of `s` matches: `*` is any run of bytes, `?` is one byte, any other byte is itself. Every byte looked at is a step, so a pattern that backtracks a long string runs out of steps |
| `between(s, a, b)` | the text after the first `a` in `s` and before the first `b` after it, or nil when either is not there; `a` of "" is the start, `b` of "" the end: `between(line, "DEPARTS (", ")")`. A field between two literals; `re_find` where a field has a shape |
| `match_path(path, pattern)` | whether a path matches a glob, part by part on `/`: `**` is any number of parts, none included; in any other part `*` and `?` are `like`'s, never across a `/`. `src/**/*.zig` is every `.zig` under `src`, `src/tcp*.zig` only those in it. The prelude's `glob` uses it |
| `rep(s, n)` | `s`, `n` times over; charged before it is made |
| `substitute(s, old, new)` | every `old` replaced by `new`, left to right, none overlapping; `old` = "" is an error |
| `tostring(v)` | a scalar's text, as `print` writes it |
| `tonumber(s)` | an optional `-` and decimal digits; anything else is an `argument` error |
| `parse_int(s)` | the integer `s` says, the blanks around it let be (spaces, tabs, `\r`, `\n`), or nil for anything else: a word, a torn line, a number past 64 bits. nil gives nil and an integer itself, so a field that is missing (`get`) reads as no number. For data the script did not write |
| `path(a, b, ...)` | the parts (one to four) joined with `/`, each "" left out, so "" is the root: `path("", "top.txt")` is `top.txt` |
| `basename(p)` | what follows the last `/`, or all of `p` |
| `strip_suffix(s, t)` | `s` without `t` at its end, or `s` as it is |


**At the edges:** `lines("")` and `words("")` are empty lists;
`split("", ",")` is `{""}` and `split("a,", ",")` is `{"a", ""}`;
`find(s, "")` is 1 and `contains(s, "")` is true; `sub("abc", 3, 1)` is
""; `pad(v, 0)` and a width shorter than the text keep the text whole.

**ONE BASE FOR STRINGS, ANOTHER FOR FILES.** A string's positions are
1-based (`find`, `sub`); a file's offsets are 0-based (`read(p, o, n)`,
`find_in`, the sidecars). The same text gives `find(s, t) == find_in(p, t)
+ 1`. Feeding one to the other is where an off-by-one bites:

```shale
replace("shale-check/off.txt", "abcdef")
local o = find_in("shale-check/off.txt", "cd")
print(o, read("shale-check/off.txt", o, 2))  -- an offset reads from there
local s = read("shale-check/off.txt")
print(find(s, "cd"), sub(s, o + 1, o + 2))   -- a position is one more
-- prints:
-- 2<TAB>cd
-- 3<TAB>cd
```

### Regular expressions

**A small subset, and linear** (metal-vmm QUEUES 230 and 232; Steve,
2026-10-17).
A field taken out of a line is one call, where `between`, `split` and a
helper took three:

```shale
local m = re_find("src/tcp.zig:412: DEPARTS (bounded) the window", "DEPARTS \\((\\w+)\\)")
if m ~= nil then print(m.at, m.text, m.group) end
print(re_match("  pub fn deadline(", "^\\s*pub fn"), re_match("x", "\\d"))
local r = re_find("see tcp.zig:40 and gone.zig:1", "(\\w+\\.zig):\\d+")
print(r.group, parse_int(sub(r.text, #r.group + 2)))
print(re_find("error: test 4 FAILED", "\\b(fail|error|panic)", {nocase = true}).group)
-- prints:
-- 18<TAB>DEPARTS (bounded)<TAB>bounded
-- true<TAB>false
-- tcp.zig<TAB>40
-- error
```

| builtin | gives |
|---|---|
| `re_find(s, pattern[, {nocase = true}])` | the leftmost match: `at` (1-based, as `find`) and `text`, and `group`, the capture group's text, when the pattern has one ("" where the match did not go through it); nil when there is none: `if m == nil` (or `if m then`). `nocase`: ASCII letters match either case |
| `re_match(s, pattern[, {nocase = true}])` | whether `s` holds a match, anywhere, as `grep` says of a line; `^` and `$` pin it to the whole |

| in a pattern | is |
|---|---|
| a byte | itself; `\` before any byte that is not a letter or digit is that byte (`\.`, `\(`, `\[`, `\\`) |
| `.` | any byte but a newline |
| `[abc]`, `[a-z]`, `[^...]` | one byte of the class, or (`^` first) one not in it; `\d \w \s` may be in it; a `]` first is the byte |
| `\d`, `\w`, `\s`, and `\D \W \S` | a digit, a letter, digit or `_`, a blank (space, tab, newline, `\r`, `\v`, `\f`); the capitals, any other byte |
| `\n`, `\t`, `\r` | a newline, a tab, a carriage return |
| `*`, `+`, `?` | the part before, any number of times, at least once, or once or not; **each takes as much as it can** |
| `^`, `$` | the string's start, its end |
| `\b`, `\B` | a word's edge (a letter, digit or `_` on one side and not the other, or the string's end), and a place that is not one (QUEUE 232) |
| `a\|b` | either, **the loosest** (`^error\|warn` is `^error` or `warn`), the leftmost alternative that matches taken first (QUEUE 232) |
| `( ... )` | **one capture group a pattern**, which may hold alternatives, `(info\|warn)`; it may repeat, `(ab)*`, and keeps its last turn |

**`{nocase = true}`** folds ASCII letters when the pattern compiles (a step
a byte more), so the search costs what it would without; a class is
folded before its `^`, so `[^a]` takes neither `a` nor `A`, as Python's.
The run's cache keeps a pattern's two compilations apart.

**Refused, each by name** (`argument`, saying what to write instead):
`{n,m}`, a second `(`, `(?...)` (no lookaround, no groups that do not
capture), `\1` (no backreferences), `\b` inside a class, lazy `*?`, a
repetition repeated (`a**`) or of a place (`\b+`), `[:alpha:]`, and a
pattern of more than 256 bytes. A pattern is written in a Shale string, so its `\` is written
`\\`: `"\\d+"` is the pattern `\d+`.

**What it costs: linear, whatever the pattern.** A pattern compiles to a
few instructions a byte (once a run: the run keeps the last 8 by their
text, a step a byte to compile), and a search runs every way through them
at once, a byte at a time, each instruction at most once a byte: **a step
a byte of the string, and one for its end, times the pattern's
instructions**. `a*b` is 5 instructions, `(a*)*b` 9: on 20,000 `a`s they
cost 100,013 and 180,020 steps, and four times the string four times the
steps (props_test). A backtracking engine's `(a*)*b` would take time
exponential in the string; here no pattern can make a step count a lie.
The match is the one a backtracking matcher would find first, tested
against one on 20,000 random patterns and strings (alternatives, `\b`
and `nocase` among them), with one rule of Thompson's: **a loop's turn
that matches nothing ends the loop** (and is never followed by another).
Perl and Python sometimes take one more turn after it, so on "a",
`(a?)*`'s group here is "a", there "".

### Numbers

| builtin | gives |
|---|---|
| `min(a, b, ...)`, `max(a, b, ...)` | the least or the most of two to four integers |
| `abs(n)` | the size of an integer; `abs` of the smallest one is an overflow |

### Dates and formatting

| builtin | gives |
|---|---|
| `date(seconds)` | `2026-10-14T03:00:00Z`, UTC, from 1970 to the end of 9999 |
| `seconds(text)` | `date`'s inverse, over the same range. It takes an RFC 3339 time with `Z` or `±HH:MM` (a fraction of a second is dropped), or a date alone, which is its midnight UTC. Anything else, an unreal day among them, is an error |
| `human(bytes)` | `512 B`, `1.5 KiB`, up to `EiB`: one decimal, rounded half up |
| `pad(v, width)` | a string or an integer padded with spaces to `width` on the right, or to `-width` on the left; longer text is kept whole |
| `table(rows, columns)` | a list of maps as aligned text: a line of the column names, then one a row, two spaces apart. A column of integers is aligned right. Every row must have every column. There is no newline at the end: `print` adds it. Charged a step a cell before the grid is made |

### Lists and maps

| builtin | gives |
|---|---|
| `push(l, x)` | `x` added to the end |
| `sort(l)` | in place, all integers or all strings, no comparator |
| `sort(rows, key)` | a list of maps, in place, by each one's `key`: all integers or all strings. **Stable**: equal keys keep their order, so sorting by one key then another orders by both |
| `sort(rows, key, "desc")` | the same, descending, **still stable**: equal keys keep their order (a sort then `reverse` reversed them). `"asc"` is the default |
| `take(l, n)` | a new list of `l`'s first `n` items, or all of a shorter one: the top N of a sorted list |
| `last(l, n)` | a new list of `l`'s last `n` items, in order, or all of a shorter one: the tail of a log's lines (QUEUE 232). A count below 0 is an error, as `take`'s: a count gone negative never quietly becomes a tail |
| `reverse(l)` | in place |
| `keys(m)` | a map's keys, in the order first set |
| `has_key(m, k)` | whether `m` has `k` |
| `get(t, k[, default])` | `t[k]`, a map's value or a list's item, or `default` (nil unset) where there is none: no stop for a missing key or an index out of range. A key of the wrong kind for the table is still a `type` error |
| `count(t)` | a map's entries, or a list's length (`#` works for lists and strings) |

### The host and output

| builtin | gives |
|---|---|
| `now()` | the integer the host handed in: the only time a script has |
| `budget()` | a map of what is left of `steps`, `reads`, `read_bytes`, `changes`, `change_bytes` and `output`, so a script can stop at a point of its own (the other budgets are not in it) |
| `print(...)` | scalars only. It evaluates every argument first, joins them with tabs, and ends with a newline: `print()` is an empty line, `print(nil, true)` is `nil<TAB>true` |
| `arg(name[, default])` | the value the run was given as `name` (the runner's `name=value`), or `default` (nil unset): a script's inputs. An integer or boolean default reads the value as one (`true`, `false`, `1`, `0`); any other, the string. The live site's route gives no values |
| `fail(msg)` | the run stops here, class `fail`, `msg` its message: one line and its trail, as any stop (QUEUE 232). The script's own assertion: `if #found == 0 then fail("no config under " .. dir) end`. `attempt` catches it; the CLI exits 1 on it |
| `yield()` | nil: a collection point, where the run keeps only the values it still reaches (see "The VM"). When a run pauses is the host's to say, never the script's |

## The prelude

**Functions every script has, written in Shale** (`src/script/prelude.shale`).
Each part of their work is one builtin call under its cap, so a run's
slices and budgets are as if the script had written them itself. **A
script may declare a function of the same name:** its calls are then its
own, from its line on. **Only what a script calls is in its run** (metal-vmm
QUEUE 230): a prelude function is parsed and compiled at its first call,
with those it calls in turn (`glob` brings `walk_all`), so a script that
calls none holds none of it in its machine. A prelude function's own calls
are the prelude's, whatever the script has declared.

| function | gives | costs |
|---|---|---|
| `walk_all(p, opts)` | every entry `walk(p, opts)` gives, across all its parts, the `more` entries left out; `opts` is not changed | `walk`'s, a part at a time |
| `count_all(p, s)` | `s`'s occurrences in the whole file | a stat, then a `count_in` a megabyte |
| `find_next(p, s, at)` | the 0-based offset of the first `s` at or after `at`, or nil | a `find_in` from `at`; a stat and more parts only when that finds nothing |
| `walk_upto(p, opts, keep)` | `{entries, more, done}`: every entry from `opts.after` on, as `walk_all`, until the walk ends (`done`, `more` is "") or its reads would leave fewer than `keep` (not `done`: `more` is the path the next walk goes on after) | `walk`'s, a part at a time, with `keep_reads = keep` |
| `glob(pattern[, {hidden}])` | every file whose path matches `pattern` (`match_path`), in the walk's order; the walk starts at the parts before the first wildcard and passes by hidden names (`walk`'s `skip = ".*"`) unless `{hidden = true}`. A pattern with no wildcard is that file, if it is one | `walk_all`'s |
| `room_for(need)` | whether what is left of the budgets holds `need`, a map of `budget()`'s names: `room_for({reads = 3, read_bytes = n})` | a `budget()` |
| `drop(l, n)` | a new list of all but `l`'s first `n` items, in order (none of a list no longer than `n`), so a part of a list is `take(drop(l, from), count)`; a count below 0 is a stop (class `fail`) | a `last` |

**A walk past what the budget walks, told in parts** (metal-vmm QUEUE
229): `walk_upto` walks as far as the reads allow, keeping `keep` for what
the script does next, and says where it stopped; the script prints what it
found and `resume after <path>`, and a later run starts from there (`const
START`, given to `opts.after`). Work done an entry at a time guards each
with `room_for` and resumes after the last entry it finished. The
cookbook's walks all do this:

```shale
const START = ""
local part = walk_upto("chat", {kind = "file", after = START}, 1)
local bytes = 0
for e in part.entries do bytes = bytes + e.size end
print(#part.entries, bytes, part.done)
if not part.done then print("resume after " .. part.more) end
-- prints:
-- 10<TAB>4780<TAB>true
```

**The walk in parts, in full,** as `walk_all` does it: each call
considers at most 256 entries and ends its part with `{kind = "more"}`,
whose path is where the next part starts.

```shale
function every_entry(path, opts)
  local o = {after = ""}
  for k in keys(opts) do o[k] = opts[k] end
  local got = {}
  while true do
    local more = nil
    for e in walk(path, o) do
      if e.kind == "more" then more = e.path else push(got, e) end
    end
    if more == nil then return got end
    o.after = more
  end
end
print(#every_entry("chat", {like = "*.md"}), #walk_all("chat", {like = "*.md"}))
-- prints:
-- 4<TAB>4
```

**Each finding in a file of any size,** with `find_next`:

```shale
local at = 0
local found = 0
while true do
  local f = find_next("chat/channels/general/sessions/plans.md", "MSG_", at)
  if f == nil then break end
  found = found + 1
  at = f + 1
end
print(found, count_all("chat/channels/general/sessions/plans.md", "MSG_"))
-- prints:
-- 40<TAB>40
```

**A big file's lines, a part at a time,** with `read_lines`: each part is
whole lines, at least the bytes asked and on to the end of the line it
stops in, and says where the next starts. Here, the lines holding `from:`,
in parts of 512 bytes:

```shale
function lines_with(path, s, part)
  local n = 0
  local at = 0
  while true do
    local r = read_lines(path, at, part)
    for l in r.lines do
      if contains(l, s) then n = n + 1 end
    end
    if r.done then return n end
    at = r.next
  end
end
print(lines_with("chat/channels/general/sessions/plans.md", "from:", 512))
-- prints:
-- 40
```

**Data a script did not write** (a log, a sidecar, a line torn by a crash)
stops a report on its first odd line if it is read strictly. Three
builtins read it leniently: `parse_int(s)` is an integer or nil where
`tonumber` stops the run; `get(t, k, default)` is `t[k]` or the default,
never a missing key's stop; `line_at(p, offset)` is the whole line around
an offset a search found:

```shale
local fields = words("2026-10-17 GET /x 200 log-x")
print(parse_int(get(fields, 4, "")), parse_int(get(fields, 5, "")), get(fields, 9, "none"))
local at = find_in("chat/channels/general/sessions/plans.md", "message 7,")
print(line_at("chat/channels/general/sessions/plans.md", at))
-- prints:
-- 200<TAB>nil<TAB>none
-- message 7, a line of it
```

## The store

**Paths are confined to the root:**
- A script's path is joined to the root.
- Every part must be a name FAT holds, so `.`, `..`, empty parts and a
  leading `/` are refused before the store is asked.
- `""` is the root, for `ls`, `stat`, `exists` and `walk` only. Every
  change needs a path of at least one part.
- The store's own limits (a name's length, a path's, its depth) still
  apply on top.

**Missing paths are errors here,** though the store itself is lenient:
- `ls` of a missing folder is an error, where the store gives an empty
  listing;
- `remove` or `remove_tree` of a missing path is an error, where the store
  takes it as done.

**A store error stops the script,** naming the path and the store's
error. The error names can differ between Linux and metal, so don't match
on them. A failed change is in the effects log, and it is the reason the
run stopped.

**The same on both hosts.** Every store builtin goes through webbox's
`store` (list, stat, read, readAt, replace, append, makeDir, remove,
removeTree), which Linux and metal both implement. The one value that can
differ is `modified` (above).

## The budgets

Each budget has a default, and the caller can override any of them. A run
that hits one stops cleanly, naming it, with its line and column. A stop
names a budget as `budget()` spells it: `steps`, `reads`, `read_bytes`,
`changes`, `change_bytes`, `output`, and the rest by the names below
(`arena`, `machine`, `kept`, `depth`, `call_depth`, `source`, `nesting`).
**Three are spelled with their unit where a host or the CLI sets them**
(`interp.Budgets`, `--budget`): `arena_bytes` is `arena`, `output_bytes`
is `output`, `source_bytes` is `source`.

**What metal passes:** the route is the
application's, not the kernel's, so zig-metal-unikernel sets no budgets of
its own. The site's column is angry-gopher's `admin_script.budgets`, which
lynrummy.com's route hands `script_route.handle` on metal; a budget it does
not name is Shale's default, the machine's included.

| budget | what it counts | default | the site's (angry-gopher `admin_script.budgets`) |
|---|---|---|---|
| steps | each statement, expression and loop iteration, and every byte or item a builtin touches | 5,000,000 | 2,000,000 |
| arena | **the memory the run holds, all of it.** (The tree a source parses to and the machine's own memory are beside it, under the machine budget.) Every value lives in the run's own arena, which takes chunks from the host only up to this budget (its headers included), so the budget is a hard bound on the memory a script can take, whatever it does (tested: the host's peak never passes it). An allocation of 64 KiB or more has a chunk of its own, given back when it is freed, so a list grown to megabytes holds only its live buffer. An allocation that fails, a store call's included, stops the run here | 16 MiB | 8 MiB |
| call depth | | 64 | 64 |
| depth | expressions and statements the walk is inside of at once, across every call (see below) | 2,000 | 2,000 |
| output | at most `out.len` | 256 KiB | 256 KiB |
| reads | `ls`, `stat`, `exists`, `is_dir`, `read` and each scan count one; `walk` one a folder and one an entry's stat | 10,000 | 500 |
| read bytes | what the reads bring; `read` gets what remains as its limit | 64 MiB | 16 MiB |
| changes | each change | 1,000 | 100 |
| change bytes | what the changes write | 16 MiB | 16 MiB |
| machine | the machine's own memory: the tree the source parses to, the compiled code, the frames' slots, the operands, the `..` chains' parts and a yield's copying, from one arena of its own beside the values'. With the arena, the whole of what a run can take from the host (tested: 5,500 parameters 63 calls deep stop on it, the host's peak under the two). **Every source within the source budget compiles in half of it** (tested: the worst shapes, short statements and list literals, take about 113 bytes of tree and code a byte of source, 7.4 MB for 64 KiB); the other half is for the frames and the operands | 16 MiB | 16 MiB (the route sets none; with its 8 MiB arena, a run takes at most 24 MiB of the host's memory) |
| call bytes | **what one builtin call brings from the store** (QUEUE 211, the caps: a builtin is never cut, so its work is bounded instead). A `read` or a scan past it is an `argument` error; a bigger file is read or scanned in parts, `read(p, offset, n)` or `count_in(p, s, offset, n)`, a call each, so a host can let a request in between | 1 MiB | 1 MiB |
| call entries | **what one `walk` call considers** (QUEUE 211, the caps): its folders' entries, each a stat if it is kept. A walk with more ends its part with a `more` entry and goes on from it | 256 | 256 |
| kept | what a `yield` keeps: the arena it copies the reachable values into (see "The VM") | 1 MiB | 1 MiB |
| source | | 64 KiB | 64 KiB |
| nesting | how deep the source nests when parsed (a parenthesis costs two: an expression and its operand) | 200 | 200 |

**Plan for the site's budgets.** A whole-chat line scan can't fit: the
chat is about 190 MB. Use what the site keeps instead (the `.count`
sidecars, `walk`'s sizes and times), read parts of files, and use
`budget()` to stop at a point of your own. The cookbook does all three.
At a step for 16 bytes, the site's whole read budget is in reach: its
16 MiB of read bytes cost 1M of its 2M steps when read, more when
scanned for something that is often there (a step a match). On a
site-shaped folder of 3.9 MB, the cookbook's scans went from about 2.8M
steps at a step a byte to about 0.26M.

## The cookbook

The scripts in `src/script/examples/` run as tests (`examples_test.zig`)
against a store shaped like angry-gopher's own data. Its formats come from
angry-gopher's sources:
- **Transcripts:** `chat/<a>_<b>/sessions/<sid>.md` and
  `chat/channels/<name>/sessions/<sid>.md`. Each message is a block,
  `MSG_<sid>_<n>\nfrom: <name>\ndate: <RFC 3339>\n\n<body>`, and blocks are
  joined by `\n\n-------------\n` (`chat_store.zig`, `chat_codec.zig`).
- **Count sidecars:** `<sid>.count`, "<count> <size>\n<offset> <uid>\n".
  `<offset>` is where the last message's block begins, the separator
  before it, or 0 for a first message; `<uid>` is `-` when unknown
  (`chat_count.zig`).
- **Next to each topic:** `<sid>.reactions.jsonl` and the `<sid>.uploads/`
  folder; and, from an older server, `<sid>.lastauthor`, which nothing
  writes or reads now (the `.count` carries the author, zig-metal-unikernel
  153(1)) but which angry-gopher's `chat_retire.zig` removes with its topic,
  as `delete_topic.shale` does.
- **Each channel's members:** `chat/channels/<name>.channel`, beside the
  channel's folder (`chat_paths.zig`), not inside it.

Every read-only script among them is also run under the site's own
budgets, and changes nothing.

| script | what it does | how it keeps to the budgets |
|---|---|---|
| `where_the_bytes_are.shale` | each top-level folder's files, bytes and empty files, then the largest files | the prelude's `walk_upto`: a read a folder and an entry, as far as the reads go, then `resume after` |
| `chat_topics.shale` | the chat topic by topic: messages from the count caches, the quiet topics, and the caches stale or missing | reads no transcript: the sizes come from `walk`, the messages from the sidecars; the walk takes at most half the reads, each cache `room_for` one, then `resume after` |
| `stale_caches.shale` | every count cache checked against its transcript's own separators | `count_all`, a transcript of any size, until the read budget has no room for the next; the rest are listed by size; past the reads, `resume after` |
| `find_message.shale` | a phrase found in each topic, with its message's id, sender and date | `find_next`, a megabyte at a time (the call-bytes cap), then 2 KiB read before the match; stops at the read budget, says how far it got and where to resume |
| `topics.shale` | every topic with its message count | `count_in` of `MSG_` a transcript, `count_all` past the cap: none held |
| `big_files.shale` | files over a size | `walk_upto`, files only, then `resume after` |
| `delete_topic.shale` | one topic deleted, as `chat_retire.zig` does: its transcript, sidecars and uploads | a change each |
| `first_change.shale` | one small change, a folder and a file, easy to check and to undo | |

### How large a site each script fits

`zig build shale-scale` (src/shale_scale.zig; the table below is its
output of 2026-10-16, and running it again gives it afresh) generates a store shaped
like angry-gopher's, at a growing number of topics, and runs each
read-only script on it under the site's budgets (steps 2M, arena 8 MiB,
500 reads, 16 MiB read) until it no longer fits. A topic is its
transcript, its `.count`, a `.reactions.jsonl` for one in three, and an
`.uploads/` of five images for one in ten. Only a topic's last message
has `find_message`'s phrase, so it searches every transcript to the end.
The sizes are to within a tenth.


| mode | script | messages a topic | largest site that fits | its transcripts | past it |
|---|---|---|---|---|---|
| atomic | `topics` | 10 (~2 KiB each) | 179 topics | 380 KiB | budget reads |
| atomic | `stale_caches` | 10 (~2 KiB each) | 94 topics | 199 KiB | budget reads |
| atomic | `find_message` | 10 (~2 KiB each) | 124 topics | 263 KiB | budget reads |
| atomic | `where_the_bytes_are` | 10 (~2 KiB each) | 94 topics | 199 KiB | budget reads |
| atomic | `chat_topics` | 10 (~2 KiB each) | 72 topics | 152 KiB | budget reads |
| atomic | `big_files` | 10 (~2 KiB each) | 124 topics | 263 KiB | budget reads |
| atomic | `topics` | 100 (~21 KiB each) | 179 topics | 3.8 MiB | budget reads |
| atomic | `stale_caches` | 100 (~21 KiB each) | 94 topics | 2.0 MiB | budget reads |
| atomic | `find_message` | 100 (~21 KiB each) | 124 topics | 2.6 MiB | budget reads |
| atomic | `where_the_bytes_are` | 100 (~21 KiB each) | 94 topics | 2.0 MiB | budget reads |
| atomic | `chat_topics` | 100 (~21 KiB each) | 72 topics | 1.5 MiB | budget reads |
| atomic | `big_files` | 100 (~21 KiB each) | 124 topics | 2.6 MiB | budget reads |
| atomic | `topics` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | budget read_bytes |
| atomic | `stale_caches` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | budget steps |
| atomic | `find_message` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | reads to its budget, then says how far it got |
| atomic | `where_the_bytes_are` | 1000 (~215 KiB each) | 94 topics | 19.8 MiB | budget reads |
| atomic | `chat_topics` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | budget reads |
| atomic | `big_files` | 1000 (~215 KiB each) | 124 topics | 26.1 MiB | budget reads |
| background | `topics` | 10 (~2 KiB each) | 2079 topics | 4.3 MiB | budget steps |
| background | `stale_caches` | 10 (~2 KiB each) | 1292 topics | 2.7 MiB | budget arena |
| background | `find_message` | 10 (~2 KiB each) | 804 topics | 1.7 MiB | budget arena |
| background | `where_the_bytes_are` | 10 (~2 KiB each) | 1069 topics | 2.2 MiB | budget arena |
| background | `chat_topics` | 10 (~2 KiB each) | 1292 topics | 2.7 MiB | budget arena |
| background | `big_files` | 10 (~2 KiB each) | 2514 topics | 5.2 MiB | budget steps |
| background | `topics` | 100 (~21 KiB each) | 731 topics | 15.4 MiB | budget read_bytes |
| background | `stale_caches` | 100 (~21 KiB each) | 550 topics | 11.6 MiB | budget steps |
| background | `find_message` | 100 (~21 KiB each) | 605 topics | 12.7 MiB | budget steps |
| background | `where_the_bytes_are` | 100 (~21 KiB each) | 1069 topics | 22.5 MiB | budget arena |
| background | `chat_topics` | 100 (~21 KiB each) | 1292 topics | 27.2 MiB | budget arena |
| background | `big_files` | 100 (~21 KiB each) | 2514 topics | 53.1 MiB | budget steps |
| background | `topics` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | budget read_bytes |
| background | `stale_caches` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | budget steps |
| background | `find_message` | 1000 (~215 KiB each) | 72 topics | 15.2 MiB | reads to its budget, then says how far it got |
| background | `where_the_bytes_are` | 1000 (~217 KiB each) | 1069 topics | 226.2 MiB | budget arena |
| background | `chat_topics` | 1000 (~217 KiB each) | 1292 topics | 273.6 MiB | budget arena |
| background | `big_files` | 1000 (~217 KiB each) | 2514 topics | 533.3 MiB | budget steps |

**Two modes, two budgets** (Steve, 2026-10-15): an **atomic** run holds up
the site's requests, so it keeps the site's 500 reads; a **background**
run only fills the gaps between them, so it may read 10,000 (angry-gopher
`admin_script.background_budgets`). Since walk's stats count as reads
(each a store call, a disk command on metal), every script that walks
the chat fits fewer topics atomically than in the background, where the
arena or the steps bind instead.

**With the prelude (QUEUE 220),** atomically: `big_files` fits 124 topics
where its `ls`, `is_dir` and `stat` an entry fit 46; `chat_topics` 72
where 60 (`read_or`, one read a cache); `topics` 179 at 10 and 100
messages a topic, and 72 at 1,000, where reading each transcript whole fit
343, 163 and 17; the rest as they were.

**The news is still mostly bad.** At angry-gopher's scale (its chat is
about 190 MB), nothing that reads transcripts finishes in one run: a
transcript-reading script answers for a few hundred topics at most, and
for a few dozen when they are large. The read count, not the bytes, binds
first.

## The runner

```sh
shale [--root DIR] [--verbose] [--budget NAME=N]... [FILE | -e SOURCE] [NAME=VALUE]...
shale <<'SHALE'                  # no FILE, no -e: the script is stdin
SHALE_ROOT=/a/copy/of/data zig build script -- src/script/examples/topics.shale
```

- **The root** is `--root`, else `SHALE_ROOT`, else the working
  directory.
- **A run makes its changes and runs its programs**: on Linux, git is
  the undo ("What was decided": no dry run).
- `--budget NAME=N` sets one budget: `steps`, `reads`, `read_bytes`,
  `output_bytes`, `changes`, `change_bytes`, `arena_bytes`, `call_bytes`
  or `call_entries`. **The runner's own defaults** (metal-vmm QUEUE 233):
  output 64 KiB, `call_bytes` 64 MiB, 64 programs a run; the rest the
  core's.
- `-e SOURCE` is the script itself, in place of a file. **With neither,
  the script is stdin**, and a stop names it `stdin`; a terminal on stdin
  is refused.
- `NAME=VALUE` is a value the script reads with `arg(NAME, default)`.
  On the live site's route a script has no values: `arg` gives its
  default.
- `now()` is the wall clock; `SHALE_NOW` pins it.
- **The Linux host** is behind the core's seam (`src/shale_host_linux.zig`):
  `host("run", argv, opts)` runs a program, `host("real", path)` gives a
  path's OS path, and a path whose first part has a `:` is a mount's
  (`runs:gates/summary`). The mounts are in `SHALE_MOUNTS`'s file, else
  `~/.config/shale/mounts` (`name = /abs/path` or `name = ~/path` a line,
  ` ro` after it for a read-only mount: every change through it is
  refused before anything is written, at the one point every change
  passes, `PathHook.may_change`, which only a `host_io` saying
  `shale_change_check` compiles; another word after the path, or a path
  with a space, is a mistake named by its line). A mount's own path is
  resolved once, at load. **The store follows no symbolic link** below
  the root or a mount's folder: the path hook walks each part with
  `lstat` (a component walk, a step a part) and a link stops the run,
  `refused`, for every read, change, `exists`/`stat` and listing; `walk`
  passes the links it lists by.
- **The preludes after the core's**: the Linux prelude (`run`, `must`,
  `re_lines`, `head_lines`, `tail_lines`, `grep_all`, `unique`, `newest`,
  `create`, `edits_all`, `zig_rename`, `zig_decls`, `zig_move` and
  `zig_imports` (Zig's
  tokenizer and parser, over the host's calls of those names), and the jobs, `job_start`, `job_alive`, `job_stop`
  and `job_wait`: SHALE-AGENTS.md), the git prelude (`git_status`,
  `git_log`, `git_commit`, ...), the repo's
  (`.shale/prelude.shale` at the root) and the user's (`SHALE_PRELUDE`'s
  file, `""` none, else `~/.config/shale/prelude.shale`). A later one may
  not redefine an earlier one's function.
- The runner sets the store's bases as a server does, so path limits are
  measured as metal measures them.
- **Terse**: it prints the output, then a stop as `name:line:column (in
  \`f\`)` (a later prelude's line by that prelude's name) and its trail;
  what the run used only past half a budget or on a stop; an `edit`'s
  diff as one line, `edit p: N hunks, -O +N lines`.
  `--verbose` adds the effects, the programs run and their logs, what the
  run used, always, and every diff in full.
- **What goes where:** the script's own output on stdout; on stderr the
  report: a stop and its trail, the effects, the programs run, and
  `── used:`, which is what the run took of four budgets
  (steps, reads, read bytes, output bytes) beside each budget. Both
  stream, so `> f 2>&1` keeps them in order.
- It exits 0 if the script finished, 1 if it stopped, 2 if the command
  line, the script's file, the mounts or a prelude could not be taken.

**Run it against a copy**, never the live data folder.

`zig build script-bench` (run it again to measure again; these are of
2026-10-15) times the interpreter's hot paths in ReleaseSafe:
a loop's iteration, a while loop, a list, a map, calls, a string built by
`..` and by `join`, a scan, and a whole read. An interpreted step takes 7
to 15 ns. A byte read whole takes 0.4 ns; a byte scanned takes 3.7 ns,
with a match every 4 bytes.

## On Linux: behind the seam

**Metal's core and Linux's are one** (the lexer, the parser, both
engines, the budgets, the store, text, regex, lists); the Linux CLI hands
it three things through `Options`, and metal hands none
(`docs/designs/DESIGN-shale-dogfood.md`):

- **`host(name, ...)`**, the one builtin that reaches outside. It is
  `Options.host`, and on metal it stops with class `host` ("not on this
  host"). On Linux it is `src/shale_host_linux.zig`:
  - `run`, a program under a timeout, a keep and a filter;
  - `real`, a path's OS path;
  - the jobs, `src/shale_host_jobs.zig` over `src/shale_jobs.zig`.
- **`Options.path_hook`**, called first in every store call's path. Linux's
  is the mounts: a path whose first part has a `:` is a mount's
  (`runs:gates/summary`), named in `SHALE_MOUNTS`'s file or
  `~/.config/shale/mounts`. Mounts are naming, not a sandbox.
- **`Options.preludes`**, the preludes after the core's, in order:
  - the Linux prelude (`src/shale_prelude_linux.shale`): the names a
    script types, such as `run`, `real`, `must`, the `job_*` calls and
    the text and file helpers;
  - the git prelude (`src/shale_prelude_git.shale`);
  - the repo's `.shale/prelude.shale`, as metal-vmm's queue tool is;
  - the user's.
  
  A later prelude may not redefine an earlier one's function. **Metal's
  parse compiles none of this**: `host_io_std.zig` says
  `shale_preludes`, and metal's host_io doesn't.
- **A run runs at most 64 programs** (`budget runs`).
- **The gate** (`tools/shale_gate.zig`, installed on the box) is the PreToolUse
  hook that holds an agent to Shale (SHALE-AGENTS.md, "The gate").

What each function takes and gives is in SHALE-AGENTS.md; the tests are
`src/shale_*_test.zig` and the host's own, through the gate where a run
can happen three times alike.

## On the live site: `script_route` and the signer

`webbox.script_route` (`src/script_route.zig`) is the reusable half of an
application's `POST /admin/script`, which angry-gopher mounts. In order,
it:
1. reads the envelope;
2. checks its Ed25519 signature against `{auth}/shale.conf`;
3. checks the target, the expiry, and a rising sequence number;
4. writes the number durably before the script runs (`store.makeDurable`,
   which each host sets);
5. runs the script and logs the run under `{auth}/shale/`;
6. replies in the runner's layout.

The envelope's format is in the file's header. Refusals are 4xx with the
reason; any run that started is 200.

**Keys and the sequence.** A key is set only by `installKey`
(angry-gopher's `/admin/script-key`), which raises the sequence to the
clock's seconds with it. A missing sequence file is refused, never read as
0, and a key set again reopens nothing signed before.

**The roots.** The route refuses when the auth root and the data root
nest, by their spellings. Symlinks inside the data root are not checked
(metal has none).

```sh
zig build shale-sign -- keygen | pubkey | sign <file.shale> <target> [minutes]
```

`src/shale_sign.zig` makes the key pair once (the private key goes at
`~/.shale_signing_key`, mode 600, never printed) and signs a script with
the next sequence number. The steps for the site are in
zig-metal-unikernel's DEPLOY.md, "Shale scripts: looking inside a droplet".

## The installed suite: scripts on a schedule

**An application's own scripts, run every so often** (`src/shale_suite.zig`,
metal-vmm QUEUE 229): it declares each as `{name, source =
@embedFile(...), args, period_s}`, installs them once (`Suite.install`, with
its long-lived allocator, the background budgets and the auth paths), and
calls `suite.step(io, now)` from its `between`, which answers a `Wake`.

- **Each runs as a background run**: it only reads, a slice at a time
  between requests. A change is the background run's `argument` error.
- **On a schedule**: every script at the first step, then every
  `period_s` from when it was due (`wake.periodAfter`), never from when it
  ran, so lateness does not accumulate. One runs at a time.
- **A signed background run goes first**: while one is going, the suite
  waits.
- **What it keeps**: each name's last run, `{auth}/shale/suite/<name>.out`,
  replaced whole: its first line `<unix seconds> <how it ended>`, then what
  it printed, at most 64 KiB (the run's output budget, capped). A line in
  `shale/log` as each ends. `readKept` reads one; `writeStatus` is a GET's
  page of them.
- **Not built: running one by name on request.** It would be a run behind
  the admin's bearer key alone, with no signature: the auth path's call,
  proposed, not made.

## For a host

### The Zig API

```zig
script.run(io, backing_allocator, root, source, budgets, now, out) -> Result
```

The `Result` owns the run's arena, so call `result.deinit()` when done. It
says:
- whether the run finished, or where it stopped: line, column, class, the
  budget if a budget stopped it, and the function it was in;
- what `print` wrote, a prefix of `out`;
- every store change the script attempted, in order, each with its outcome.

A script's top-level `return v` ends it; `v` goes nowhere.


### The contract: a run as a host sees it

**`src/script/process.zig` is the whole of what a host may know of a
run** (metal-vmm QUEUE 211, Steve's model: "the kernel should treat the
shale VM as just an opaque black box"). A host calls these, and nothing
else of the script module's insides:

| call | what it does |
|---|---|
| `Process.start(io, allocator, root, source, mode, budgets, now, output_most)` | parse and compile; a source that doesn't parse or fit gives a process already stopped, saying why |
| `Process.startWith(io, allocator, root, source, options, budgets, now, output_most)` | the same, with `Options`: the mode, the script's values (`arg`), and on Linux the host, its path hook and the preludes after the core's |
| `step(.{ .steps, .now })` | one slice: `paused`, `finished` or `stopped`. A slice ends between ops, after at most `steps` **or after any store call**, whichever comes first; `now()` is the slice's clock. An ended run says so again and runs nothing |
| `output()` | what it has printed |
| `status()` | its state, steps, slices, effects and its stop |
| `kill()` | every byte it holds, given back, whatever state it is in |

- **It owns all it holds,** from the allocator `start` is handed, never a
  request's heap: the values' arena, the machine's memory and its
  output, each under its budget. A second run later needs no host change
  but a count.
- **Two modes.** `atomic` is today's run, whole inside one handler, and
  may change the store. `background` is stepped in slices between
  handlers and **only reads**: `replace`, `append`, `mkdir`, `remove`
  and `remove_tree` are `argument` errors naming `atomic`. A script that
  finds and then deletes is a background run to find, then an atomic
  one to act.
- **A slice ends after any store call** (Steve: "let the kernel swap it
  out on any I/O request"): a store call is synchronous, so its end is
  where a host can let a request in, whether it returned or failed into
  an `attempt`. Pure work is cut by `steps`; a builtin is never cut, its
  work bounded by the caps instead (`call_bytes`, `call_entries`).
- **The one-shot route and the runner run through it too** (slice after
  slice, with nothing between), so every test holds the contract: the
  gate's runs are processes.
- Tested (`process_test.zig`): a background run's output is the atomic
  run's in slices of 1 to 50 steps; `kill` gives back every byte, mid-run,
  finished, stopped before it ran, or holding megabytes; a background
  change is refused and changes nothing.

### The VM

**A script runs on a bytecode VM** (`src/script/compile.zig`,
`src/script/vm.zig`; metal-vmm QUEUE 211). The route and the runner use
it. The tree-walker it replaced (`interp.zig`) stays in the tests as the
second implementation. The VM is a stack machine over the walker's own
semantics: every operator, index, builtin and charge is the walker's
code, called from an op. What is the VM's own is the control flow: the
operand stack, the frames, the loops' hidden slots, and `attempt` as a
frame marked with its answer. It never recurses, so a run's whole state
is data, which a later `yield` can keep.

**The same run, step for step.** The walker charges a step as it enters
each node, and checks the depth budget there. The compiler keeps those
enters in the walker's order, each with its node's place and its depth in
its function, and hangs each run of them on the op whose work follows.
The VM charges a run at once when it fits the budgets, and node by node
when it doesn't, so a stop names the same node.

**The gate.** In the tests every `script.run` runs twice: the VM on the
store it was given, and the walker on a copy made before (same path
length, same file times). The two must agree on the output, the
effects, the stop (class, budget, line, column, function, message), the
steps, the work counted, the arena held, and the store each leaves.
Every interpreter, builtin, example, cookbook, error-corpus, property,
snippet and fuzz test is therefore a parity test. A difference panics
with both runs, and the test it happened in is the reproduction.
Planted defects fire it: `<` compiled as `<=`, and a lost step on
reading a local, each in many tests.

**The machine's memory is not the arena.** The frames, the operands and
the code come from the machine's own arena (the `machine` budget,
`machine_bytes`), beside the values' arena, so the two engines take the
same values' arena and stop on it at the same place.

`zig build script-bench`, ReleaseSafe, the VM's time over the walker's
(2026-10-15's run; the step measures it again):

| case | walker | VM |
|---|---|---|
| a loop's iteration | 8.5 ns a step | 6.7 (0.79x) |
| a while loop | 7.9 | 6.4 (0.81x) |
| a list, built and indexed | 10.8 | 10.6 (0.98x) |
| a map's fields | 9.1 | 7.1 (0.78x) |
| calls | 13.2 | 10.6 (0.80x) |
| a string built by `..` | 7.2 | 4.6 (0.64x) |
| `count_in` over 8 MiB | 13.0 | 13.5 (1.04x) |
| `read` 8 MiB whole | 9.8 | 11.4 (1.15x) |
| a string built by `join` | 11.9 | 9.0 (0.76x) |

Where the interpreter's own work dominates, the VM takes about four
fifths of the walker's time. Where a builtin's work dominates (a scan, a
read), the two are within this box's noise, since the work is the same
code. Speed is not the VM's point; the state a yield can keep is.

### `yield`: a collection point

`yield()` **collects** (metal-vmm QUEUE 211, as Steve's model of
2026-10-15 left it): the run keeps only the values it still reaches. It
takes nothing and schedules nothing. Where a long run pauses is the
host's to choose (after a store call, or a number of steps), never the
script's.

- **What a yield keeps:** the values the run still reaches are copied
  into a fresh arena: every local of every frame, the parts of an
  expression half evaluated, a loop's list, the `const`s, `attempt`'s
  answers being made, and the effects log. The old arena is then freed
  whole, so whatever the script made and let go of goes with it. A run
  that yields every minute holds what it keeps, not what it ever made.
- **A table reached twice is still one table** after the copy. Strings
  have no identity a script can see.
- **The copy is charged:** a step for each value and a step for every 16
  bytes of string. What is kept may be at most the **kept** budget (1 MiB by
  default); past it, the run stops with `budget kept`.
- **The code is not copied:** the tree and its literals have their own
  arena beside the values'.

```shale
local total = 0
for i = 1, 1000 do
  local junk = {}
  for j = 1, 20 do push(junk, "item " .. j) end
  total = total + #junk
  yield()
end
print(total)
-- prints:
-- 20000
```

The tree-walker kept as the VM's second implementation never collects,
so the tests' gate holds a script that yields to the same output,
effects and stop, but not to the same steps or arena.

### The Zig stack, and the run's memory

- Metal's stack is 16 MB, and Linux's main thread has 8 MB.
- Debug frames are about a kilobyte, so the call depth times the nesting
  (64 × 200) would need about 20 MB.
- So the walk is bounded by the **depth** budget instead, and its
  recursive frames are kept small. The VM (above) never recurses, but
  keeps the depth budget exactly, so a script stops at the same place on
  either.
- Measured by `interp_test.zig`:

  | | Debug | ReleaseSafe |
  |---|---|---|
  | deepest walk (depth 2,000) | 3.8 MB | 1.1 MB |
  | deepest parse | 369 KB | 123 KB |

  The test holds both under 4 MB.

**The run allocates its values only from its arena** and writes only
the caller's `out`; the machine's own memory (the frames' slots, the VM's
operands and frames, the compiled code) comes from the caller's
allocator beside the arena, bounded by the call-depth and depth budgets
and freed when the run ends. It assumes no threads. `src/script/portable_test.zig` reads each of the
module's sources and refuses anything that names the host outside its
tests: `std.posix`, `std.os`, `std.c`, `std.process`, `std.Thread`,
`std.time`, `Io.Dir`, `Threaded`, `page_allocator`, `std.debug.print`, and
`std.fs` other than `std.fs.path`. The test also checks that its own list
holds every source of the module.

## What was decided, and what was refused

- **No dry run** (Steve, 2026-10-17, deleting the one the Linux CLI had,
  QUEUE 229's `Mode.dry_run` and 234's overlay): on Linux, git is the
  undo; on metal, rehearse a script on a copy of the data.
- **On metal, no effects beyond the store.** No network, no clock but
  `now()`, no host. Linux's Shale has more behind one seam, metal's
  unchanged ("On Linux: behind the seam"; zig-webbox
  `docs/designs/DESIGN-shale-dogfood.md`).
- **A step a byte for a builtin's work, and a step for 16 bytes of bulk
  byte work** (Steve, 209): reads, scans and the haystacks of searches.
  A search also pays a step a place it stops and for its compares, after
  a cold review timed a dense substitution at 33 times its budget's time
  without that.
- **A function is called only after it is declared,** and a name that is
  a value in scope can't be called (Steve, 209). So a new builtin never
  changes what a script does.
- **`continue` is in; `goto` is not.** `continue` is the one new keyword,
  added while scripts are few. No more keywords are planned.
- **Errors are values only through `attempt`**, and budgets never.
- **No remove from a list or a map.** A list only grows, which is what
  lets `for x in` walk it in place.
- **No floats, no closures.** Patterns only as the regular expressions'
  linear subset, `re_find` and `re_match` (Steve, 2026-10-17: "yes to
  regex"; alternation, `\b` and `nocase` with the dogfood design): one
  group, no backreferences, no backtracking.
- **Offsets in files are 0-based; positions in strings are 1-based.** The
  first are the site's (sidecars count bytes from 0); the second are
  Lua's.
