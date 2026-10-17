# Shale as an agent's tool

**Shale was made for a site's own data on bare metal, and what it does
there to stay safe is what an agent wants on Linux too:**

- **Every run is bounded.** Its steps, its reads, its changes and **what
  it prints** each have a budget (`--budget NAME=N` sets one). A script
  that would print a megabyte stops at the output budget (256 KiB unset)
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

```sh
zig build                      # zig-out/bin/shale
shale count.shale dir=src      # dry: changes logged, none made
shale --write rename.shale from=old to=new
shale -e 'for p in glob("src/*.zig") do print(p) end'
```

A value given as `name=value` is the script's `arg("name", default)`; a
default that is an integer or a boolean reads the value as one.

**What it has for code:** `glob(pattern)` (`**` any folders, `*` and `?`
within one; hidden names like `.git` and `.zig-cache` left out),
`grep(p, s)` (the lines holding a literal, numbered), `read_lines` and
`count_lines` for a file of any size, `edit(p, old, new[, {all, word}])`
(a literal replaced, its diff printed), `walk` with `skip`, and the
language's own `split`, `words`, `contains`, `sort`, `table` and maps. The
whole language is [`SHALE.md`](SHALE.md).

Every block of Shale below runs as a test (`src/script/agent_test.zig`), on
a small checkout shaped like zig-metal-unikernel's, as a dry run. What it
prints is under `-- prints:` (a tab shows as `<TAB>`).

## The cookbook, beside what an agent would write otherwise

### The DEPARTS lines in `src/tcp*.zig`, counted by reason

```shale
local by = {}
local total = 0
for p in glob("src/tcp*.zig") do
  for m in grep(p, "DEPARTS (") do
    local reason = split(split(m.text, "DEPARTS (")[2], ")")[1]
    by[reason] = get(by, reason, 0) + 1
    total = total + 1
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

The shell is one line, and wins here. Shale's version is longer, but each
step is a name an agent can change without re-deriving a `sed` expression,
and `.zig-cache`'s copy of a file is never counted.

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

About even. `count_lines` counts a last line without its newline, as `wc
-l` does not.

### Every `props.always` message, with where it is

```shale
for p in glob("src/**/*.zig") do
  for m in grep(p, "props.always(") do
    local q = split(m.text, "\"")
    if #q >= 3 then print(p .. ":" .. m.line, q[2]) end
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

Shale has no regular expressions: the first string literal is the second
piece of a `split` on `"`, which an escaped quote inside the message would
break. For this tree it holds; a regex would hold for more.

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

Shale shows the diff **before** anything is written, and writes only with
`--write`; `sed -i` writes first, and the diff is git's to show after.
`word = true` is `\b`'s whole-word rule. A file `edit` would change in a
way its `old` does not pin down (`old` twice, without `all`) is refused, and
says so, before anything is changed.

### A doc's `file:line` references, checked

```shale
function leading_int(s)
  local n = 0
  while n < #s and contains("0123456789", sub(s, n + 1, n + 1)) do n = n + 1 end
  if n == 0 then return nil end
  return parse_int(sub(s, 1, n))
end
for m in grep("docs/notes.md", ".zig:") do
  for w in words(m.text) do
    local parts = split(substitute(substitute(w, "`", ""), "(", ""), ".zig:")
    local n = nil
    if #parts == 2 then n = leading_int(parts[2]) end
    if n ~= nil then
      local name = basename(parts[1]) .. ".zig"
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

**Python wins this one.** Without a regular expression, taking the number
after `.zig:` is a seven-line function, and taking the name is two
`substitute`s for the punctuation a doc puts around it.

## Where Shale is worse, said plainly

- **No regular expressions** (a question for Steve, in metal-vmm's
  FEEDBACK). Extracting a field is `split`, `words`, `sub` and a helper.
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
