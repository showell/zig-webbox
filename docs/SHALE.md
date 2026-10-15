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

    script.run(io, backing_allocator, root, source, budgets, now, out) -> Result

The `Result` owns the run's arena, so call `result.deinit()` when done. It
says:
- whether the run finished, or where it stopped: line, column, class, the
  budget if a budget stopped it, and the function it was in;
- what `print` wrote, a prefix of `out`;
- every store change the script attempted, in order, each with its outcome.

## A first script, step by step

**Look before you change.** List what is at the root:

    for name in ls("") do print(name) end

**Walk a folder** to see everything under it, one store read per folder:

    for e in walk("chat", {like = "*.md"}) do
      print(e.path, e.size, date(e.modified))
    end

**Read only what you need.** Here, a count cache's first line and the
start of a transcript:

    local cache = read("chat/1_2/sessions/hello.count")
    print(words(lines(cache)[1])[1])     -- the cached message count
    print(read("chat/1_2/sessions/hello.md", 0, 200))

**Count without holding a file.** A message is a block, and blocks are
joined by the separator:

    local sep = "\n\n-------------\n"
    print(count_in("chat/1_2/sessions/hello.md", sep) + 1)

**Then change something.** The effects log lists every change with its
outcome:

    mkdir("shale-check")
    replace("shale-check/note.txt", "written at " .. date(now()) .. "\n")

**Survive one bad file** with `attempt`, which turns an error into a
value:

    function size_of(path) return tonumber(words(read(path))[1]) end
    for e in walk("chat", {like = "*.count"}) do
      local r = attempt(size_of, e.path)
      if r.ok then print(e.path, r.value) else print(e.path, "unreadable:", r.error) end
    end

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
  recurse, and may be called before it is declared.
- `const NAME = e`, at the top level only. The name is never assigned
  again, and the functions declared after it see it. A table it names can
  still change. A function that reads a const before its line has run
  stops with an error.

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
- **A script's names may take a builtin's.** A local or const named after
  a builtin is that local wherever it is a value. A call by that name is
  the script's own function first, if it declares one anywhere, and the
  builtin otherwise. So **a builtin added to the language never breaks a
  script.** Two exceptions, for functions and calls only (a local may
  take either name):
  - Lua's library names (`pairs`, `pcall`, `string`, ...): no function
    takes one, and a call by one is refused, kept to say what to write
    instead;
  - `attempt`: no function takes it, and a call by it is the language's.
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

### `attempt`: surviving one bad file

    local r = attempt(f, a, b)

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

`--` starts a comment that runs to the end of its line.

## The builtins

**What a builtin costs:**
- **Steps.** Every builtin charges steps in proportion to the work it does:
  a step for each byte or item it touches. A sort is charged its bound
  before it runs (n log n comparisons, and every byte in each of the log n
  passes). `charge_test.zig` holds every builtin to this: its own steps at
  N and at 4N must grow by at least a step a unit. The ones whose work
  does not grow say why.
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
| `read(p)` | the whole file | a read; each byte a read byte and a step | `budget read_bytes` when the file is longer than what is left; `store` |
| `read(p, offset[, n])` | `n` bytes from byte `offset`, or to the end; fewer where the file ends, and "" from its end or past it. **Offsets are 0-based**, as the site's sidecars count them | a read; only those bytes | `argument` for a negative offset or count; `store` for a folder or a missing file |
| `count_lines(p)` | the lines in a file, as `#lines(read(p))` counts them | a read; each byte a read byte and a step; one buffer for every scan of the run, at most 64 KiB and the needle's length, whatever the file's size and however many files | `store` |
| `count_in(p, s)` | how many times `s` occurs, none overlapping | as `count_lines` | `argument` for "" or a needle over 64 KiB |
| `find_in(p, s)` | the 0-based offset of the first `s`, a `read` offset, or nil | as `count_lines`, stopping at the first | as `count_in` |
| `walk(p[, opts])` | every entry under `p`, depth first, each folder's names sorted and a folder before what it holds, as `{path, size, kind, modified}`, `path` from the root. A folder's size is 0. A symlink is `"other"` (size and `modified` 0) and is never entered | **one read a folder listed**, not one an entry; a step an entry and each path's bytes | `store`; `argument` for an unknown option |
| `replace(p, s)` | writes the file whole: never a torn file. There is no plain `write` | a change; each byte a change byte and a step | `store`, logged |
| `append(p, s)` | adds to the end | as `replace` | `store`, logged |
| `mkdir(p)` | a folder, and its parents | a change | `store`, logged |
| `remove(p)`, `remove_tree(p)` | a file, or a folder and everything in it | a change | `store` for a missing path (logged) |

**`walk`'s options:**
- `depth`: 1 lists only the folder's own entries, which is `ls` with each
  entry's stat, and a walk that stops there reads fewer folders.
- `like`: a pattern for the entries' names (`like` below). Folders are
  walked into whether they match or not.
- `kind`: `"file"`, `"directory"` or `"other"`.

An entry that `like` or `kind` leaves out is never stat'ed.

### Text

Plain text everywhere: **not Lua's patterns.** Positions in strings are
1-based, as Lua's are. **Every search is linear in its haystack**
(`find`, `contains`, `split`, `substitute`, and the store's scans): a
needle of up to 16 bytes by the usual search, at most 16 compares a byte;
a longer one by Knuth-Morris-Pratt, its table charged a step a byte.

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

| budget | what it counts | default | the site's (angry-gopher v30) |
|---|---|---|---|
| steps | each statement, expression and loop iteration, and every byte or item a builtin touches | 5,000,000 | 2,000,000 |
| arena | every value of the run lives in one arena. Every allocation counts, and a free never counts back (an arena keeps a list's outgrown buffers), so the budget bounds the arena's true size, give or take the arena's own bookkeeping and slack (about an eighth more, measured). An allocation that fails, a store call's included, stops the run here | 16 MiB | 8 MiB |
| call depth | | 64 | 64 |
| depth | expressions and statements the walk is inside of at once, across every call (see below) | 2,000 | 2,000 |
| output | at most `out.len` | 256 KiB | 256 KiB |
| reads | `ls`, `stat`, `exists`, `is_dir`, `read` and each scan count one; `walk` one a folder | 10,000 | 500 |
| read bytes | what the reads bring; `read` gets what remains as its limit | 64 MiB | 16 MiB |
| changes | each change | 1,000 | 100 |
| change bytes | what the changes write | 16 MiB | 16 MiB |
| source | | 64 KiB | 64 KiB |
| nesting | how deep the source nests when parsed (a parenthesis costs two: an expression and its operand) | 200 | 200 |

**Plan for the site's budgets.** A whole-chat line scan can't fit: the
chat is about 190 MB. Use what the site keeps instead (the `.count`
sidecars, `walk`'s sizes and times), read parts of files, and use
`budget()` to stop at a point of your own. The cookbook does all three.
At a step a byte, the site's 2M steps cover at most about 2 MB of
scanning or reading in one run.

### The Zig stack

- Metal's stack is 16 MB, and Linux's main thread has 8 MB.
- Debug frames are about a kilobyte, so the call depth times the nesting
  (64 × 200) would need about 20 MB.
- So the walk is bounded by the **depth** budget instead, and its
  recursive frames are kept small.
- Measured by `interp_test.zig`:

  | | Debug | ReleaseSafe |
  |---|---|---|
  | deepest walk (depth 2,000) | 3.8 MB | 1.1 MB |
  | deepest parse | 369 KB | 123 KB |

  The test holds both under 4 MB.

**The run allocates only from its arena** and the caller's `out`, and it
assumes no threads. `src/script/portable_test.zig` reads each of the
module's sources and refuses anything that names the host outside its
tests: `std.posix`, `std.os`, `std.c`, `std.process`, `std.Thread`,
`std.time`, `Io.Dir`, `Threaded`, `page_allocator`, `std.debug.print`, and
`std.fs` other than `std.fs.path`. The test also checks that its own list
holds every source of the module.

## The runner

    SHALE_ROOT=/a/copy/of/data zig build script -- src/script/examples/topics.shale

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

    zig build shale-sign -- keygen | pubkey | sign <file.shale> <target> [minutes]

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
- **Next to each topic:** `<sid>.reactions.jsonl`, the `<sid>.uploads/`
  folder, and `<name>.channel` (the members).

Every read-only script among them is also run under the site's own
budgets, and changes nothing.

| script | what it does | how it keeps to the budgets |
|---|---|---|
| `where_the_bytes_are.shale` | each top-level folder's files, bytes and empty files, then the largest files | `walk`: one read a folder |
| `chat_topics.shale` | the chat topic by topic: messages from the count caches, the quiet topics, and the caches stale or missing | reads no transcript: the sizes come from `walk`, the messages from the sidecars |
| `stale_caches.shale` | every count cache checked against its transcript's own separators | `count_in`, and only for transcripts under 1 MiB; the rest are listed by size |
| `find_message.shale` | a phrase found in each topic, with its message's id, sender and date | `find_in`, then 2 KiB read before the match; stops at the read budget and says how far it got |
| `topics.shale` | every topic with its message count, the old way | reads every transcript whole: small sites only |
| `big_files.shale` | files over a size | |
| `delete_topic.shale` | one topic deleted, as `chat_retire.zig` does: its transcript, sidecars and uploads | a change each |
| `first_change.shale` | one small change, a folder and a file, easy to check and to undo | |

## What was decided, and what was refused

- **No dry run.** Scripts just run (Steve).
- **No effects beyond the store.** No network, no clock but `now()`, no
  host.
- **A step a byte** for every builtin's work: simple, and the same
  everywhere. The bench says bulk byte work (a whole read, a scan) is
  cheaper than an interpreted step, so this overprices it 3 to 30 times.
  The site's step budget is the place to account for that, if ever.
- **New builtins never break a script.** A script's own names take
  precedence; Lua's library names and `attempt` are the exceptions.
- **`continue` is in; `goto` is not.** `continue` is the one new keyword,
  added while scripts are few. No more keywords are planned.
- **Errors are values only through `attempt`**, and budgets never.
- **No remove from a list or a map.** A list only grows, which is what
  lets `for x in` walk it in place.
- **No floats, no patterns, no closures.**
- **Offsets in files are 0-based; positions in strings are 1-based.** The
  first are the site's (sidecars count bytes from 0); the second are
  Lua's.
