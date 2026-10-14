# zig-webbox

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its
store); webbox does the HTTP, the cookies, the streams and the disk, and a
host runs it.

- **Two hosts, one library.** The `webbox_linux` module runs a site as a
  Linux process. [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
  runs the same sources on a machine with no operating system, handing them
  its own `host_io`.
- **Two applications use it:** [angry-gopher](https://github.com/showell/angry-gopher)
  (lynrummy.com) and [dog-park](https://github.com/showell/dog-park).

## The modules

| module | root | what |
|---|---|---|
| `webbox` | `src/webbox.zig` | portable: what an application's code imports |
| `webbox_linux` | `src/webbox_linux.zig` | the Linux host, for a Linux `main` only |
| `host_io` | `src/host_io_std.zig` | the one file that names the host: std's `Io` here |

An application depends on this repo by path (a sibling checkout) and takes
all three from `b.dependency("webbox", ...)`. It imports the library by
module name, never a file by path.

## Scripts: Shale

`webbox.script` (`src/script/`) runs **Shale**, a small language for a
site's own data: explore the store and print, read the output, then write
a script that changes things. It has Lua's look and smaller semantics of
its own. A script **just runs**: its effects happen as it goes, and a
stopped run keeps what it already did, which its effects log says.

    script.run(io, backing_allocator, root, source, budgets, now, out) -> Result

The Result owns the run's arena (`result.deinit()`). It says the run
finished, or where it stopped (line, column, class, and the budget if a
budget stopped it). It also carries what `print` wrote (a prefix of
`out`), and every store change the script attempted, in order, each with
its outcome.

### The language

- **Statements:**
  - `local x = e`;
  - `x = e`, `t[k] = e` and `t.k = e`;
  - `if c then ... elseif c then ... else ... end`;
  - `while c do ... end`;
  - `for i = a, b[, step] do ... end`;
  - `for x in list do ... end`, which walks the list as it was when the loop began;
  - `break`, `do ... end`, and `return [e]` (at the top level it ends the script);
  - `function name(a, b) ... end`, at the top level only. A function may recurse, and may be called before it is declared.
- **Values:**
  - `nil`, `true`/`false`;
  - 64-bit integers, checked: overflow stops the script;
  - byte strings, `"..."` or `'...'`, with the escapes `\n \t \\ \" \'`;
  - lists `{1, 2}`, indexed from 1;
  - maps `{a = 1, ["b c"] = 2}`, as `m.a` or `m["a"]`.
  - `{}` takes its kind (list or map) from its first entry; using it as the other kind after that is an error.
- **Operators:** `+ - *`; `//` and `%`, which floor as Lua's do; `..` joins strings and integers; `== ~= < <= > >=`; `and or not`, where `and`/`or` short-circuit and return an operand; `#` gives a string's or a list's length.
- **Truth:** only `nil` and `false` are false.
- **Comparison:**
  - `==` across types is false;
  - `<` across types is an error;
  - `==` on a list or a map is an error;
  - strings compare byte by byte.
- **Errors, not nil:**
  - reading a missing map key, or a list index out of range;
  - `m.k = nil` (there is no remove);
  - `nil` put in a list;
  - writing a list index other than `#l + 1` past its end;
  - a literal that mixes positional and keyed entries;
  - division by zero, and minint `//` -1.
  - `has_key(m, k)` asks before you read.
- **Names:**
  - there are no globals: an undeclared name is an error, found when the script is parsed;
  - locals are block-scoped;
  - `local x = x` reads the outer `x`;
  - a function sees only its own parameters and locals, not the script's;
  - functions are not values.
- **Refused, each by name:**
  - floats and `/`;
  - `^`, hex literals and the bitwise operators;
  - long strings and comments;
  - unknown escapes;
  - `:` method calls;
  - `...`;
  - `goto` and `repeat`;
  - several locals or loop names, multiple assignment and multiple returns;
  - function values, nested and `local` functions;
  - `string.`, `table.`, `pairs`, `ipairs`, `pcall`, `require` and the rest of Lua's library.

### The builtins

| | |
|---|---|
| the store | `ls(p)` (a sorted list of names), `stat(p)` (`{size, kind}`, with no time, so runs stay deterministic), `exists(p)`, `is_dir(p)`, `read(p)`, `replace(p, s)` (never a torn file; there is no plain `write`), `append(p, s)`, `mkdir(p)`, `remove(p)`, `remove_tree(p)` |
| strings | `split(s, sep)` (an error when `sep` is `""`), `join(list, sep)`, `starts_with`, `ends_with`, `contains`, `find` (plain text, **not Lua's patterns**; nil when absent), `sub(s, i[, j])` (Lua's: 1-based, inclusive, negatives from the end, clamped), `trim`, `upper`, `lower`, `tostring` (scalars only), `tonumber` (an optional `-` and decimal digits; anything else is an error) |
| lists and maps | `push(l, x)`, `sort(l)` (in place, all integers or all strings, no comparator), `keys(m)` (insertion order), `has_key(m, k)`, `count(m)` (maps; `#` for strings and lists) |
| the host | `now()`, the integer the host handed in: the only time a script has |
| output | `print(...)` takes scalars only; it evaluates every argument first, joins them with tabs, and ends with a newline |

**Paths are confined to the root.**
- A script's path is joined to the root.
- Every part must be a name FAT holds, so `.`, `..`, empty parts and a leading `/` are refused.
- `""` is the root, for `ls`, `stat` and `exists` only. Every change needs a path of at least one part.
- The store's own limits (depth, length) still apply on top.
- `ls` of a missing folder, and `remove` or `remove_tree` of a missing path, are errors. The store itself takes them as an empty listing and as done.

**A store error stops the script,** naming the path and the store's error.
The error names (`@errorName`) can differ between Linux and metal, so
don't match on them. A failed change is in the effects log, and it is the
reason the run stopped.

### The budgets

Each budget has a default, and the caller can override any of them. A
run that hits one stops cleanly, naming it, with its line and column.

| budget | default |
|---|---|
| steps: each statement, expression and loop iteration, and every byte or element a builtin touches (a sort is charged its bound before it runs) | 5,000,000 |
| arena: every value of the run is in one arena, and any allocation that fails, a store call's included, counts against this budget | 16 MiB |
| call depth | 64 |
| depth: how many expressions and statements the walk is inside of at once, across all calls (see below) | 2,000 |
| output (at most `out.len`) | 256 KiB |
| store reads (`ls`, `stat`, `exists` and `is_dir` each count one) and read bytes (`read` gets what remains as its limit) | 10,000 and 64 MiB |
| store changes, and the bytes they write | 1,000 and 16 MiB |
| source size | 64 KiB |
| parse nesting (a parenthesis costs two: an expression and its operand) | 200 |

**The Zig stack.**
- Metal's stack is 16 MB and Linux's main thread has 8 MB.
- Debug frames are about a kilobyte, so the call depth times the nesting (64 × 200) would have needed about 20 MB.
- The walk is bounded by the **depth** budget instead, and its recursive frames are kept small.
- Measured by `interp_test.zig`:

  | | Debug | ReleaseSafe |
  |---|---|---|
  | deepest walk (depth 2,000) | 3.8 MB | 1.1 MB |
  | deepest parse | 369 KB | 123 KB |

  The test holds both under 4 MB.

**The run allocates only from its arena** and the caller's `out`, and it
assumes no threads. `src/script/portable_test.zig` reads the module's own
sources and refuses anything that names the host (`std.posix`, `std.os`,
`std.c`, `std.process`, `std.Thread`, `std.time`, `Io.Dir`, `Threaded`,
`page_allocator`, `std.debug.print`, and `std.fs` other than `std.fs.path`)
outside its tests.

### The runner

    SHALE_ROOT=/a/copy/of/data zig build script -- src/script/examples/topics.shale

`SHALE_NOW` sets `now()` (default 0). The runner sets the store's bases as
a server does, so path limits are measured as metal measures them. It
prints the output, the effects log, and how the run ended. It exits 0 if
the script finished and 1 if it stopped. **Run it against a copy**, never
the live data folder.

The examples in `src/script/examples/` run as tests against a store
shaped like angry-gopher's:
- every topic with its message count;
- files over a size;
- deleting one topic.

### On the live site: `script_route` and the signer

`webbox.script_route` (`src/script_route.zig`) is the reusable half of an
application's `POST /admin/script` (angry-gopher mounts it): the envelope
read, its Ed25519 signature checked against `{auth}/shale.conf`, the target,
the expiry and a rising sequence number, the number written durably before
the script runs (`store.makeDurable`, which each host sets), the run, its
log under `{auth}/shale/`, and the reply in the runner's layout. The format
is in the file's header; refusals are 4xx with the reason, any run that
started is 200.

`zig build shale-sign -- keygen | pubkey | sign <file.shale> <target>
[minutes]` (`src/shale_sign.zig`) makes the key pair once (the private key
at `~/.shale_signing_key`, mode 600, never printed) and signs a script with
the next sequence number. The steps for the site are in
zig-metal-unikernel's README, "Release notes: the script route".

## Checks

    zig build test

## Status (2026-10-13)

| | |
|---|---|
| Source | moved from angry-gopher's `zig-server/src`, with its history (24 files) |
| Serves | lynrummy.com, as part of angry-gopher v29 on metal |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
