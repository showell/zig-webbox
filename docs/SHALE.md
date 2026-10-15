# Shale

**Shale is a small language for a site's own data.** You use it to look
through the store and print what you find, then write a script that
changes things. It looks like Lua, with smaller semantics of its own. Every
effect goes through webbox's `store`, so a script does the same on Linux
and on bare metal. Every run stays inside its budgets.

A script **just runs.** Its effects happen as it goes. A run that stops
keeps what it already did, and its effects log says what that was. There
is no dry run and no rollback.

This page is the reference:
- the language and its names;
- errors, and `attempt`;
- every builtin, with its cost and its errors;
- the store and its paths;
- the budgets, and the Zig stack;
- the runner, and the signed route on the live site;
- a short tutorial and a cookbook;
- what was decided and what was refused.

The code is `src/script/`, and `script.zig` is the entry.

```zig
script.run(io, backing_allocator, root, source, budgets, now, out) -> Result
```

The `Result` owns the run's arena, so call `result.deinit()` when done. It
says:
- whether the run finished, or where it stopped: line, column, class, the
  budget if a budget stopped it, and the function it was in;
- what `print` wrote, a prefix of `out`;
- every store change the script attempted, in order, each with its outcome.

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
  builtin).
- `const NAME = e`, at the top level only. The name is never assigned
  again, and the functions declared after it see it. A table it names can
  still change. A function that reads a const before its line has run
  stops with an error.

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
| strings | bytes, `"..."` or `'...'`. The escapes are `\n \t \r \0 \xHH \\ \" \'`. A string ends on its line |
| lists | `{1, 2}`, indexed from 1 |
| maps | `{a = 1, ["b c"] = 2}`, read as `m.a` or `m["a"]`; keys are strings, kept in the order first set |

`{}` takes its kind, list or map, from its first entry; using it as the
other kind after that is an error. **Tables are shared, not copied:**
`local b = a` names the same list. Functions are not values.

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
  error; `==` on a list or a map is an error. Strings compare byte by byte.
- **A chain of `..` is joined once.** `a .. b .. c` evaluates every part
  left to right, then makes one string. When the first part is the string
  the previous chain made, and its buffer has room, the rest is written
  after it in place. So `s = s .. x` in a loop is linear, not quadratic,
  in time and in arena. No string ever changes: the room is past the end
  of every string that shares the buffer. A part that is not a string or
  an integer is a `type` error at the `..` before it (the first part's,
  at the chain's first `..`), as the nested joins would have said.

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
  in_function = "f"}`.

Two things it does not do:
- **It never catches a budget.** A budget is the run's, not the call's, so
  a run that runs out stops wherever it is.
- **It undoes nothing.** Whatever `f` did before its error stays done: its
  output, and its changes in the effects log.

### Refused, each by name

- floats and `/`;
- `^`, hex literals and the bitwise operators;
- long strings and long comments;
- decimal escapes (`\65`), `\u{...}`, `\z` and the rest;
- `:` method calls;
- `...`;
- `goto` and `repeat`;
- several locals, several loop names, multiple assignment and multiple
  returns;
- function values, nested functions and `local function`;
- `string.`, `table.`, `pairs`, `ipairs`, `pcall`, `require` and the rest
  of Lua's library.

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

`--` starts a comment that runs to the end of its line.

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

### The store

| builtin | gives | costs | errors |
|---|---|---|---|
| `ls(p)` | the names in a folder, sorted | a read; a step an entry, and the sort | `store`: missing, or not a folder |
| `stat(p)` | `{size, kind, modified}`. `kind` is `"file"`, `"directory"` or `"other"`. `modified` is in seconds since 1970, as the host keeps it: metal's FAT to 2 s, and 0 where it keeps none | a read | `store` |
| `exists(p)` | whether anything is there | a read | `store`, only for a failure other than absence |
| `is_dir(p)` | whether a folder is there | a read | `store` |
| `read(p)` | the whole file | a read; each byte a read byte, and a step for 16 | `argument` for a file over the call-bytes cap (1 MiB): read it in parts; `budget read_bytes` when the file is longer than what is left; `store` |
| `read(p, offset[, n])` | `n` bytes from byte `offset`, or to the end; fewer where the file ends, and "" from its end or past it. **Offsets are 0-based**, as the site's sidecars count them | a read; only those bytes | `argument` for a negative offset or count, or for more than the call-bytes cap; `store` for a folder or a missing file |
| `count_lines(p[, offset[, n]])` | the lines in a file, as `#lines(read(p))` counts them. **Of a range**, `n` bytes from `offset` (or to the end), the newlines in it and, if it reaches the end, a last line without one: the parts' counts add up to the whole's | a read; each byte a read byte, and a step for 16; a step a line; one buffer of 128 KiB for every scan of the run, whatever the file's size, the needle's length and however many files | `argument` for a range (the whole file, without one) over the call-bytes cap (1 MiB): scan it in parts; `store` |
| `count_in(p, s[, offset[, n]])` | how many times `s` occurs, none overlapping; of a range, the matches that start in it, each read to its end (at most `#s - 1` bytes past the range). The parts add up to the whole's unless a match that runs past a part's end overlaps one the next part counts, which only a needle that overlaps itself (`aa`) can do | as `count_lines`, and a step for each match, or first byte of one, it stops at | `argument` for "" or a needle over 64 KiB, or as `count_lines` |
| `find_in(p, s[, offset[, n]])` | the 0-based offset of the first `s`, a `read` offset, or nil; of a range, the first that starts in it, so a file found in parts gives what the whole file's would | as `count_in`, stopping at the first | as `count_in` |
| `walk(p[, opts])` | every entry under `p`, depth first, each folder's names sorted and a folder before what it holds, as `{path, size, kind, modified}`, `path` from the root. A folder's size is 0. A symlink is `"other"` (size and `modified` 0) and is never entered | **one read a folder listed**, not one an entry; a step an entry and each path's bytes | `store`; `argument` for an unknown option |
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

An entry that `like` or `kind` leaves out is never stat'ed.

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
| `rep(s, n)` | `s`, `n` times over; charged before it is made |
| `substitute(s, old, new)` | every `old` replaced by `new`, left to right, none overlapping; `old` = "" is an error |
| `tostring(v)` | a scalar's text, as `print` writes it |
| `tonumber(s)` | an optional `-` and decimal digits; anything else is an `argument` error |

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
| `reverse(l)` | in place |
| `keys(m)` | a map's keys, in the order first set |
| `has_key(m, k)` | whether `m` has `k` |
| `count(t)` | a map's entries, or a list's length (`#` works for lists and strings) |

### The host and output

| builtin | gives |
|---|---|
| `now()` | the integer the host handed in: the only time a script has |
| `budget()` | what is left of `steps`, `reads`, `read_bytes`, `changes`, `change_bytes` and `output`, so a script can stop at a point of its own |
| `print(...)` | scalars only. It evaluates every argument first, joins them with tabs, and ends with a newline |
| `yield()` | nil: a collection point, where the run keeps only the values it still reaches (see "The VM"). When a run pauses is the host's to say, never the script's |

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
that hits one stops cleanly, naming it, with its line and column.

**What metal passes** (the box's re-review, item 4): the route is the
application's, not the kernel's, so zig-metal-unikernel sets no budgets of
its own. The site's column is angry-gopher's `admin_script.budgets`, which
lynrummy.com's route hands `script_route.handle` on metal; a budget it does
not name is Shale's default, the machine's included.

| budget | what it counts | default | the site's (angry-gopher v30) |
|---|---|---|---|
| steps | each statement, expression and loop iteration, and every byte or item a builtin touches | 5,000,000 | 2,000,000 |
| arena | **the memory the run holds, all of it.** (The tree a source parses to and the machine's own memory are beside it, under the machine budget.) Every value lives in the run's own arena, which takes chunks from the host only up to this budget (its headers included), so the budget is a hard bound on the memory a script can take, whatever it does (tested: the host's peak never passes it). An allocation of 64 KiB or more has a chunk of its own, given back when it is freed, so a list grown to megabytes holds only its live buffer. An allocation that fails, a store call's included, stops the run here | 16 MiB | 8 MiB |
| call depth | | 64 | 64 |
| depth | expressions and statements the walk is inside of at once, across every call (see below) | 2,000 | 2,000 |
| output | at most `out.len` | 256 KiB | 256 KiB |
| reads | `ls`, `stat`, `exists`, `is_dir`, `read` and each scan count one; `walk` one a folder | 10,000 | 500 |
| read bytes | what the reads bring; `read` gets what remains as its limit | 64 MiB | 16 MiB |
| changes | each change | 1,000 | 100 |
| change bytes | what the changes write | 16 MiB | 16 MiB |
| machine | the machine's own memory: the tree the source parses to, the compiled code, the frames' slots, the operands, the `..` chains' parts and a yield's copying, from one arena of its own beside the values'. With the arena, the whole of what a run can take from the host (tested: 5,500 parameters 63 calls deep stop on it, the host's peak under the two). **Every source within the source budget compiles in half of it** (tested: the worst shapes, short statements and list literals, take about 113 bytes of tree and code a byte of source, 7.4 MB for 64 KiB); the other half is for the frames and the operands | 16 MiB | 16 MiB (the route sets none; with its 8 MiB arena, a run takes at most 24 MiB of the host's memory) |
| call bytes | **what one builtin call brings from the store** (QUEUE 211, the caps: a builtin is never cut, so its work is bounded instead). A `read` or a scan past it is an `argument` error; a bigger file is read or scanned in parts, `read(p, offset, n)` or `count_in(p, s, offset, n)`, a call each, so a host can let a request in between | 1 MiB | 1 MiB |
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

### The Zig stack

- Metal's stack is 16 MB, and Linux's main thread has 8 MB.
- Debug frames are about a kilobyte, so the call depth times the nesting
  (64 × 200) would need about 20 MB.
- So the walk is bounded by the **depth** budget instead, and its
  recursive frames are kept small. The VM (below) never recurses, but
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
Two planted defects fire it: `<` compiled as `<=` (six tests), and a
lost step on reading a local (55).

**The machine's memory is not the arena.** The frames, the operands and
the code come from the caller's allocator, beside the budgeted arena, so
the two engines take the same arena and stop on it at the same place.

`zig build script-bench`, ReleaseSafe, the VM's time over the walker's:

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

### The contract: a run as a host sees it

**`src/script/process.zig` is the whole of what a host may know of a
run** (metal-vmm QUEUE 211, Steve's model: "the kernel should treat the
shale VM as just an opaque black box"). A host calls these, and nothing
else of the script module's insides:

| call | what it does |
|---|---|
| `Process.start(io, allocator, root, source, mode, budgets, now, output_most)` | parse and compile; a source that doesn't parse or fit gives a process already stopped, saying why |
| `step(.{ .steps, .now })` | one slice: `paused`, `finished` or `stopped`. A slice ends between ops, after at most `steps`; `now()` is the slice's clock. An ended run says so again and runs nothing |
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
- **The one-shot route and the runner run through it too** (in one
  slice), so every test holds the contract: the gate's runs are
  processes.
- Tested (`process_test.zig`): a background run's output is the atomic
  run's in slices of 1 to 50 steps; `kill` gives back every byte, mid-run,
  finished, stopped before it ran, or holding megabytes; a background
  change is refused and changes nothing.

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

## The runner

```sh
SHALE_ROOT=/a/copy/of/data zig build script -- src/script/examples/topics.shale
```

- `SHALE_NOW` sets `now()` (default 0).
- The runner sets the store's bases as a server does, so path limits are
  measured as metal measures them.
- It prints the output, the effects log, and how the run ended, the stop
  as `name:line:column (in \`f\`)`.
- It exits 0 if the script finished and 1 if it stopped.

**Run it against a copy**, never the live data folder.

`zig build script-bench` times the interpreter's hot paths in ReleaseSafe:
a loop's iteration, a while loop, a list, a map, calls, a string built by
`..` and by `join`, a scan, and a whole read. An interpreted step takes 7
to 15 ns. A byte read whole takes 0.4 ns; a byte scanned takes 3.7 ns,
with a match every 4 bytes.

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
zig-metal-unikernel's README, "Release notes: the script route".

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
| `where_the_bytes_are.shale` | each top-level folder's files, bytes and empty files, then the largest files | `walk`: one read a folder |
| `chat_topics.shale` | the chat topic by topic: messages from the count caches, the quiet topics, and the caches stale or missing | reads no transcript: the sizes come from `walk`, the messages from the sidecars |
| `stale_caches.shale` | every count cache checked against its transcript's own separators | `count_in`, and only for transcripts under 1 MiB; the rest are listed by size |
| `find_message.shale` | a phrase found in each topic, with its message's id, sender and date | `find_in`, a megabyte at a time (the call-bytes cap), then 2 KiB read before the match; stops at the read budget and says how far it got |
| `topics.shale` | every topic with its message count, the old way | reads every transcript whole: small sites only |
| `big_files.shale` | files over a size | |
| `delete_topic.shale` | one topic deleted, as `chat_retire.zig` does: its transcript, sidecars and uploads | a change each |
| `first_change.shale` | one small change, a folder and a file, easy to check and to undo | |

### How large a site each script fits

`zig build shale-scale` (src/shale_scale.zig) generates a store shaped
like angry-gopher's, at a growing number of topics, and runs each
read-only script on it under the site's budgets (steps 2M, arena 8 MiB,
500 reads, 16 MiB read) until it no longer fits. A topic is its
transcript, its `.count`, a `.reactions.jsonl` for one in three, and an
`.uploads/` of five images for one in ten. Only a topic's last message
has `find_message`'s phrase, so it searches every transcript to the end.
The sizes are to within a tenth.

| script | messages a topic | the largest site that fits | its transcripts | what stops it past that |
|---|---|---|---|---|
| `topics` | 10 (~2 KiB) | 343 topics | 729 KiB | reads |
| `topics` | 100 (~21 KiB) | 163 topics | 3.4 MiB | arena |
| `topics` | 1000 (~215 KiB) | 17 topics | 3.6 MiB | steps |
| `stale_caches` | 10 | 124 topics | 263 KiB | reads |
| `stale_caches` | 100 | 124 topics | 2.6 MiB | reads |
| `stale_caches` | 1000 | 72 topics | 15.2 MiB | steps |
| `find_message` | 10 | 196 topics | 416 KiB | reads |
| `find_message` | 100 | 196 topics | 4.1 MiB | reads |
| `find_message` | 1000 | 72 topics | 15.2 MiB | read bytes: it stops itself and says how far it got |
| `chat_topics` | any | 196 topics | 41 MiB at 1000 | reads: an `exists` and a `read` a topic |
| `where_the_bytes_are` | any | 1175 topics (about 3,500 files) | 249 MiB at 1000 | arena: every entry held, as maps |
| `big_files` | any | 46 topics | 9.7 MiB at 1000 | reads: an `is_dir` and a `stat` an entry |

**The news is mostly bad.** At angry-gopher's scale (its chat is about
190 MB), nothing that reads transcripts finishes in one run: a
transcript-reading script answers for a few hundred topics at most, and
for a few dozen when they are large. The read count, not the bytes,
binds first. Even the scripts that read no transcript stop near 200
topics (`chat_topics`, two reads a topic) and 1,200 (`where_the_bytes_are`,
its arena). `big_files`, the old way (`ls`, `is_dir` and `stat` an entry),
fits 46 topics; `walk` does the same work in one read a folder.

## What was decided, and what was refused

- **No dry run.** Scripts just run (Steve).
- **No effects beyond the store.** No network, no clock but `now()`, no
  host.
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
- **No floats, no patterns, no closures.**
- **Offsets in files are 0-based; positions in strings are 1-based.** The
  first are the site's (sidecars count bytes from 0); the second are
  Lua's.
