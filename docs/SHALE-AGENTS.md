# Shale as an agent's tool

**Shale was made for a site's own data on bare metal, and what it does
there to stay safe is what an agent wants on Linux too:**

- **Every run is bounded.** Its steps, its reads, its changes and **what
  it prints** each have a budget (`--budget NAME=N` sets one). A script
  that would print a megabyte stops at the output budget (64 KiB in `shale` unset)
  and says so: its output is a bounded context cost, never a flood.
- **A stop is one line that says where and why**, with the calls that led
  there (`called from file:line:column (in f)`), and a class: `type`,
  `index`, `store`, `budget reads`. No traceback to read through.
- **Nothing changes unless asked.** `shale` runs dry unless told
  `--write`: every change is checked and logged, an `edit`'s diff is
  printed, and none is made. Read the diff, then run it again with
  `--write`.
- **It reads only what it is rooted at** (`--root`, else the working
  directory): no `..`, no absolute paths, no host, no clock but what it is
  handed. A script cannot reach what it was not given.

`shale` is terse: past half of any budget, or on a stop, it says what the
run used of each (`── used: 52374 of 5000000 steps, 12 of 10000 reads,
...`), so a script near an edge is known before a bigger run finds it;
`--verbose` says so always, with the effects and the programs run. With
no file and no `-e`, the script is stdin (`shale <<'SHALE'`).

```sh
zig build                      # zig-out/bin/shale
shale count.shale dir=src      # dry: changes logged, none made
shale --write rename.shale from=old to=new
shale -e 'for p in glob("src/*.zig") do print(p) end'
```

A value given as `name=value` is the script's `arg("name", default)`; a
default that is an integer or a boolean reads the value as one.

**What it has for code:** `glob(pattern)` (`**` any folders, `*` and `?`
within one; hidden names like `.git` and `.zig-cache` left out, unless `{hidden = true}`),
`grep(p, s)` (the lines holding a literal, numbered), `read_lines` and
`count_lines` for a file of any size, `re_find(s, pattern)` and
`re_match` (regular expressions, a linear-time subset: `|`, `\b`, one
capture group, `{nocase = true}`), `between(s, a, b)` (the text after one string and before the
next), `edit(p, old, new[, {all, word}])` (a literal replaced, its diff
printed) and `edit(p, {{old = ..., new = ...}, ...})` (several in sequence,
one diff, one write, none made if any fails), long strings (`[=[ ... ]=]`,
raw, for text that holds quotes and lines), `walk` with `skip`, and the
language's own `split`, `words`, `contains`, `sort`, `table` and maps. The
whole language is [`SHALE.md`](SHALE.md).

**On Linux, the Linux prelude** (`src/shale_prelude_linux.shale`; metal
has none of it):
- **Programs:** `run(argv, opts)` runs one (`timeout_ms` and a keep, `head`
  or `tail` or `whole`, are required; see SHALE.md, "The runner").
  `must(r)` gives `r` if it exited 0; otherwise it prints its output and
  fails, naming the program and how it ended. `real(p)` gives a path's OS
  path, for an argv.
- **Text:** `re_lines(s, pattern, opts?)` gives `{line, text}`, with
  `invert` and `nocase`. `head_lines(p, n)` and `tail_lines(p, n)` take a
  file of any size and give nil for a missing one. `grep_all(p, lit)` is
  `grep` for a file of any size. `unique(list)` gives each item once. `newest(dir, n)`
  gives the names that changed last.
- **Files:** `create(p, text)` refuses a file already there.
  `edits_all({{p, edits}, ...})` checks every file's edits before it writes
  any.

**A repo's own prelude** is `.shale/prelude.shale` at the root. **A
user's** is `~/.config/shale/prelude.shale` (`SHALE_PRELUDE=<file>` names
another, `SHALE_PRELUDE=` none). Each holds only functions, and none may
take an earlier prelude's name. A stop in one names it:
`stopped at .shale/prelude.shale:5:12`. A function's last parameters may
be optional (`function f(a, opts?)`): a call that leaves them out gives
them nil.

Every block of Shale below runs as a test (`src/script/agent_test.zig`), on
a small checkout shaped like zig-metal-unikernel's, as a dry run. What it
prints is under `-- prints:` (a tab shows as `<TAB>`).

## The cookbook, beside what an agent would write otherwise

Each task says what it uses: a literal finds the lines (`grep`), and a
pattern takes the field out of them (`re_find`), where a field has a
shape. A literal that is the whole of what is wanted stays a literal.

### The DEPARTS lines in `src/tcp*.zig`, counted by reason

```shale
local by = {}
local total = 0
for p in glob("src/tcp*.zig") do
  for m in grep(p, "DEPARTS (") do
    local r = re_find(m.text, "DEPARTS \\((\\w+)\\)")
    if r ~= nil then
      by[r.group] = get(by, r.group, 0) + 1
      total = total + 1
    end
  end
end
local rows = {}
for k in keys(by) do push(rows, {reason = k, lines = by[k]}) end
sort(rows, "reason")
print(table(rows, {"reason", "lines"}))
print("all", total)
-- prints:
-- reason   lines
-- bounded      1
-- fast         1
-- simpler      1
-- all<TAB>3
```

```sh
grep -h 'DEPARTS (' src/tcp*.zig | sed -E 's/.*DEPARTS \(([a-z]+)\).*/\1/' | sort | uniq -c
```

**Uses** `glob`, `grep` for the lines, `re_find` for the reason (the
`sed` expression's own pattern, and its group). The shell is one line, and
wins here. Shale's version is longer, but each step is a name an agent can
change, and `.zig-cache`'s copy of a file is never counted.

### The files over a thousand lines

```shale
local rows = {}
for p in glob("**/*.zig") do
  local n = count_lines(p)
  if n > arg("over", 1000) then push(rows, {lines = n, path = p}) end
end
sort(rows, "lines", "desc")
print(table(rows, {"lines", "path"}))
-- prints:
-- lines  path
--  1200  src/big_test.zig
```

```sh
find . -name '*.zig' -not -path './.*' | xargs wc -l | awk '$1 > 1000 && $2 != "total"' | sort -rn
```

**Uses** `glob` and `count_lines`: no text is taken apart. About even.
`count_lines` counts a last line without its newline, as `wc -l` does
not.

### Every `props.always` message, with where it is

```shale
for p in glob("src/**/*.zig") do
  for m in grep(p, "props.always(") do
    local r = re_find(m.text, "props\\.always\\([^\"]*\"([^\"]*)\"")
    if r ~= nil then print(p .. ":" .. m.line, r.group) end
  end
end
-- prints:
-- src/tcp.zig:7<TAB>tcp: what is sent was queued
-- src/tcp_timeouts.zig:3<TAB>tcp: a deadline is after the start
```

```python
import pathlib, re
for p in sorted(pathlib.Path("src").rglob("*.zig")):
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if "props.always(" in line and (m := re.search(r'"([^"]*)"', line)):
            print(f"{p}:{i}\t{m.group(1)}")
```

**Uses** `grep` for the lines and `re_find` for the message: the call's
first string literal, not merely the line's first string.
With one group and no alternation, a message holding an escaped quote
(`\"`) is cut at it, which Python's `(?:\\.|[^"\\])*` would not be; for
this tree it holds.

### A symbol renamed across a tree, its diff first

```shale
function rename_in(p, from, to) return edit(p, from, to, {all = true, word = true}) end
local n = 0
for p in glob("src/**/*.zig") do
  if #grep(p, "pastDeadline") > 0 then n = n + rename_in(p, "pastDeadline", "deadlinePassed") end
end
print(n .. " renamed")
-- prints:
-- --- a/src/tcp.zig
-- +++ b/src/tcp.zig
-- @@ -5,1 +5,1 @@
-- -pub const pastDeadline = timeouts.pastDeadline;
-- +pub const deadlinePassed = timeouts.deadlinePassed;
-- --- a/src/tcp_timeouts.zig
-- +++ b/src/tcp_timeouts.zig
-- @@ -2,1 +2,1 @@
-- -pub fn pastDeadline(now: u64) bool {
-- +pub fn deadlinePassed(now: u64) bool {
-- 3 renamed
```

```sh
grep -rlw pastDeadline src | xargs sed -i 's/\bpastDeadline\b/deadlinePassed/g' && git diff
```

**Uses** `glob`, `grep` to pass by the files without the name, and `edit`
with `word`: the name is a literal, so no pattern. Shale shows the diff
**before** anything is written, and writes only with
`--write`; `sed -i` writes first, and the diff is git's to show after.
`word = true` is `\b`'s whole-word rule. A file `edit` would change in a
way its `old` does not pin down (`old` twice, without `all`) is refused, and
says so, before anything is changed.

### Two edits to one file, each asserted, one write

```shale
local n = edit("src/tcp.zig", {
  {old = [=[
fn check() void {
    props.always(@src(), true, "tcp: what is sent was queued", .{});
}]=], new = [=[
fn check(queued: bool) void {
    props.always(@src(), queued, "tcp: what is sent was queued", .{});
}]=]},
  {old = "// DEPARTS (simpler): no SACK.", new = "// DEPARTS (simpler): no SACK, no window scaling."},
})
print(n .. " edits")
-- prints:
-- --- a/src/tcp.zig
-- +++ b/src/tcp.zig
-- @@ -4,1 +4,1 @@
-- -// DEPARTS (simpler): no SACK.
-- +// DEPARTS (simpler): no SACK, no window scaling.
-- @@ -6,3 +6,3 @@
-- -fn check() void {
-- -    props.always(@src(), true, "tcp: what is sent was queued", .{});
-- -}
-- +fn check(queued: bool) void {
-- +    props.always(@src(), queued, "tcp: what is sent was queued", .{});
-- +}
-- 2 edits
```

```python
import pathlib
p = pathlib.Path("src/tcp.zig"); s = p.read_text()
for old, new in [('fn check() void {\n    props.always(@src(), true, "tcp: what is sent was queued", .{});\n}',
                  'fn check(queued: bool) void {\n    props.always(@src(), queued, "tcp: what is sent was queued", .{});\n}'),
                 ("// DEPARTS (simpler): no SACK.", "// DEPARTS (simpler): no SACK, no window scaling.")]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
p.write_text(s)
```

**Uses** `edit`'s list form and long strings: each `old` is held to being
there exactly once, in the file as the edit before left it; one diff is
printed, and the file is written once, or not at all if any edit fails.
**About even**, and Shale's prints the diff before anything is written (and
writes nothing without `--write`). The text goes in as it is, quotes and
lines and all, with no escaping.

### A doc's `file:line` references, checked

```shale
for m in grep("docs/notes.md", ".zig:") do
  for w in words(m.text) do
    local r = re_find(w, "(\\w+\\.zig):\\d+")
    if r ~= nil then
      local name = r.group
      local n = parse_int(sub(r.text, #name + 2))
      local found = glob("**/" .. name)
      if #found == 0 then
        print(name .. ":" .. n, "no such file")
      elseif count_lines(found[1]) < n then
        print(name .. ":" .. n, found[1] .. " has " .. count_lines(found[1]) .. " lines")
      end
    end
  end
end
-- prints:
-- tcp_timeouts.zig:40<TAB>src/tcp_timeouts.zig has 5 lines
-- gone.zig:1<TAB>no such file
```

```python
import pathlib, re
for m in re.finditer(r"([\w/]+\.zig):(\d+)", pathlib.Path("docs/notes.md").read_text()):
    hits = list(pathlib.Path(".").rglob(pathlib.Path(m[1]).name))
    if not hits: print(m[0], "no such file")
    elif len(hits[0].read_text().splitlines()) < int(m[2]): print(m[0], "too short")
```

**Uses** `grep` for the lines, `words` for each reference, `re_find` for
the name (its group) and the number after it, and `glob` and `count_lines`
to check it. **About even with Python now:** where this took a seven-line
function for the digits and two `substitute`s for the punctuation around
a reference, the pattern does both; with one group, the number is what
follows the name in the match.

## Where Shale is worse, said plainly

- **Regular expressions are a subset**: one capture group, no `{n,m}`, no
  lookaround, no backreferences (each refused by name). Two fields from one
  match are the group and what follows it in the match. In return no
  pattern makes a search slower than linear, and its cost is known before
  it runs.
- **A file is read whole by `grep` and `edit`**, at most the call-bytes cap
  (1 MiB): a bigger one goes through `read_lines` a part at a time.
- **Step budgets are real.** A walk of a large tree, or a script that loops
  over every line in Shale rather than in a builtin, runs out of the
  5,000,000 steps a run has unset; `--budget steps=N` raises them, and the
  stop says which one ran out.
- **Paths are a store's**: every part must be a name FAT holds, so a file
  whose name has `:` or `"` cannot be named, and hidden folders are left
  out of a `glob`.
- **No processes, no network, no stdin**, by design: a script cannot run
  `git` or `zig`; it reads files and prints.
- **Integers only, bytes only**: no floats, and a string is its bytes.
