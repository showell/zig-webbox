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
- **A run makes its changes; git is the undo.** There is no dry run
  (Steve, 2026-10-17): every change is checked and logged, an `edit`'s
  diff is printed before it is written, and an edit that would not pin its
  text down is refused before anything is changed. Work in a checkout, so
  `git diff` shows what a run did and `git checkout --` takes it back.
- **It reads only what it is rooted at** (`--root`, else the working
  directory) and its mounts (`runs:x`): no `..`, no absolute paths. It
  reaches past them only by running a program (`run`).

`shale` is terse: past half of any budget, or on a stop, it says what the
run used of four, steps, reads, read bytes and output bytes (`── used:
52374 of 5000000 steps, 12 of 10000 reads, ...`), so a script near an edge
is known before a bigger run finds it;
`--verbose` says so always, with the effects and the programs run. An
`edit`'s diff is one line, `edit p: 3 hunks, -4 +5 lines`, unless
`--verbose`, which prints it in full. With
no file and no `-e`, the script is stdin (`shale <<'SHALE'`).

```sh
zig build                      # zig-out/bin/shale: put it on PATH
shale count.shale dir=src
shale rename.shale from=old to=new
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
- **Jobs**, programs that outlive the call:
  - `job_start(argv, {log, cwd, env})` starts one under a detached reaper.
    `log` is required, and there are no `secrets`. A log whose job still
    runs, or whose reaper has yet to write its end, is refused: stop or
    wait for it, or use another. Once `job_wait` says `exited`, the log
    takes a new job at once.
  - Its record is `<log>.job`. `job_alive`, `job_stop` (TERM, 2 seconds,
    then KILL) and `job_wait(job, {timeout_ms, file, contains})` take the
    job or that path, so a later call carries on.
  - `job_wait` gives `{ended = "exited" | "found" | "timeout" | "lost"[,
    code | signal]}`. `exited` always has a `code` or a `signal`; `lost` is
    a job gone with its reaper and no end written (the reaper was itself
    ended). `contains` reads only what the file gained since the last
    look, so a long wait on a large log costs the log once; a file that
    cannot be read stops the run, named.
  - **Keep `timeout_ms` under the Bash call's own timeout** (120 s unless
    raised), because Shale cannot see it.
- **Files:** `create(p, text)` refuses a file already there.
  `edits_all({{p, edits}, ...})` checks every file's edits before it writes
  any. `zig_rename(p, from, to, {lines}?)` renames a Zig identifier as
  Zig's tokenizer sees it, giving `{renamed, left_in_comments}` (the
  cookbook's "A symbol renamed across a tree").
  `zig_decls(p)` lists a Zig file's top-level declarations, from Zig's
  own parser, in file order: `{kind, name, name_form, visibility, linkage,
  first, last, start, stop[, comment_above]}`. A span runs from its doc
  comment to the `}`, `;` or field's `,` that ends it (`read(p, start,
  stop - start)` is it); `comment_above` is the plain `//` lines directly
  over it. A file that does not parse stops, naming the line. **The
  analysis is Zig's parser and its tokens, not types**: what it cannot
  see (a method reached through a value), the compiler judges after
  (`same_tests.shale`).
  `zig_move(from, to, names, {comment, after}?)` moves top-level
  declarations (a name, or `{kind, name}` when one name is two) from one
  Zig file to another (made if missing; written first, then `from` cut),
  and says what the move broke: `{moved, needs_pub, needs_import,
  needs_from_from, uses_left}`, each `{name, line}` (`needs_import` with
  its `target`, the value `from` gives it). `uses_left` is the code's uses
  only: mentions in comments are yours. Not reported: a method called
  through a value (`hold.begin()`), a name through an `@This()` alias.
  The blank lines it puts between declarations end as `to`'s lines do
  (CRLF or LF; an empty `to` as `from`'s).
  `zig_imports(p)` lists a Zig file's `@import`s and `@embedFile`s, from
  Zig's parser (a split call is one, a comment's or a string's none):
  `{kind, target, name, line, file}`, `file` being `"found"` or
  `"missing"` beside it, or `"module"` (no extension: `std`, `host_io`).
  It is library_test.zig's reading too (webbox's `zig_refs`).
  `zig_rename` and `zig_move` read identifiers one way
  (`shale_zig_ast.identifiers`): a field, an enum's member or a nested
  container's own declaration of the name is another thing, and
  `[]const X` is a use of `X`.

**Git, in the git prelude** (`src/shale_prelude_git.shale`). Every call
runs git under `run`. A `repo` is a Shale path, `""`
or `"."` for the root and `repos:dog-park` for a mount.
- **Reading:** `git_status(repo)` gives `{code, path[, from]}`.
  `git_log(repo, {n, range, ref, fields})` gives `{hash, subject, date,
  author}`. `git_diff(repo, {range, paths, stat})` and `git_show(repo,
  "rev:path")` give text. `git_ls_files(repo)`, `git_is_clean(repo)` and
  `git_head(repo)` give the tracked paths, whether the tree is clean, and
  the head's short hash.
- **Changing:**
  - `git_commit(repo, msg, {add = "tracked" | "all" | {paths}})` passes
    the message on stdin and gives the new head.
  - `git_push(repo, {remote, branch})` sets the upstream, as `push -u`
    does.
  - `git_fetch(repo, {all})`, `git_pull_ff(repo)` and `git_merge_ff(repo,
    ref)`.
  - `git_merge(repo, ref)` makes a merge commit when one is needed and
    gives the new head. On a conflict it undoes the merge (`merge
    --abort`) and stops, naming the conflicted paths, so the checkout is
    never left half merged.
  - `git_worktree_add(repo, dir, {branch, new})`,
    `git_worktree_remove(repo, dir, {force})` and `git_branch_delete(repo,
    name, {force})`.
- **Errors:** a git error stops the run with the call as you typed it and
  git's first line: `` `git show HEAD:nope` exited 128: fatal: ... ``.
  Each call has 60 seconds unless given `timeout_ms`.

**Claude's commit belongs in the user prelude**, not the git prelude: it
refuses a message without its attribution.

```lua
-- ~/.config/shale/prelude.shale
function commit(repo, msg, opts)
  local signed = false
  for l in lines(msg) do
    if starts_with(l, "Co-Authored-By:") then signed = true end
  end
  if not signed then fail("`commit`: the message has no Co-Authored-By: line") end
  return git_commit(repo, msg, opts)
end
```

**A repo's own prelude** is `.shale/prelude.shale` at the root. **A
user's** is `~/.config/shale/prelude.shale` (`SHALE_PRELUDE=<file>` names
another, `SHALE_PRELUDE=` none). Each holds only functions, and none may
take an earlier prelude's name. A stop in one names it:
`stopped at .shale/prelude.shale:5:12`. A function's last parameters may
be optional (`function f(a, opts?)`): a call that leaves them out gives
them nil.

Every block of Shale below runs as a test (`src/script/agent_test.zig`), on
a small checkout shaped like zig-metal-unikernel's, a fresh one each. What it
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

### A symbol renamed across a tree, as Zig sees it

```shale-linux
local n = 0
for p in glob("src/**/*.zig") do
  if #grep(p, "pastDeadline") > 0 then
    local r = zig_rename(p, "pastDeadline", "deadlinePassed")
    n = n + r.renamed
    if r.left_in_comments > 0 then print(p .. ": " .. r.left_in_comments .. " left in comments") end
    -- What reaches it through a module is after a `.`: its own edit.
    if #grep(p, "timeouts.pastDeadline") > 0 then edit(p, "timeouts.pastDeadline", "timeouts.deadlinePassed", {all = true}) end
  end
end
print(n .. " renamed")
-- (the CLI's summary of each diff; --verbose for the diffs)
-- prints:
-- edit src/tcp.zig: 1 hunk, -1 +1 lines
-- edit src/tcp.zig: 1 hunk, -1 +1 lines
-- edit src/tcp_timeouts.zig: 1 hunk, -1 +1 lines
-- 2 renamed
```

```sh
grep -rlw pastDeadline src | xargs sed -i 's/\bpastDeadline\b/deadlinePassed/g' && git diff
```

**Uses** `zig_rename` (metal-vmm QUEUE 234, 3): Zig's own tokenizer, so
it renames identifier tokens and nothing else: not a field or an enum
literal after `.` (the essay's `.watch`), not `@"pastDeadline"`, not a
string, a test's name or a comment (it counts the comments' mentions in
`left_in_comments`, for you to decide), and not part of a longer name.
`sed`'s `\b`, and `edit`'s `word`, take every one of those. **The
analysis is tokens, not types:** a name reached through a module
(`timeouts.pastDeadline`) is after a `.` and is left, so the qualified
uses get their own `edit`, and the compiler judges after
(`same_tests.shale`). `opts.lines = {first, last}` limits it to a range.

**Moving a block to another file, then its uses** (the linux_host split):
move the declarations, then rename what the old file still says to the
qualified name:

```shale-linux
local r = zig_rename("src/linux_host.zig", "kept_write_deadline_ms", "linux_writes.kept_write_deadline_ms")
-- stops: argument
```

A `to` with a `.` where the name is still **declared** (after `const`,
`var` or `fn`, before a `:`, in a capture, an enum's member) stops the run,
naming the line, with nothing written: `pub const
linux_writes.kept_write_deadline_ms` was the essay's worst miss. So the
stop says the block was not moved yet, as it does here. The rename
writes as it goes, so `git diff` shows it and `git checkout` takes it
back. (A `shale-linux` block runs with the Linux prelude, in
`src/shale_doc_linux_test.zig`.)

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
**About even**, and Shale's prints the diff before anything is written.
The text goes in as it is, quotes and
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

## If you write Lua

Shale reads like Lua, and an agent's Lua habits are most of its first
stops (the box's first afternoon under the gate: essay
`notes/shale-from-the-inside.md`). Most are a clear stop; the first
two can give a quiet wrong answer, an empty list:

- **Patterns are regular expressions, not Lua's.** The escape is `\`
  (`"\\."` in a string), and `%` is a plain character, so Lua's `%d+` or
  `[%w_]` matches nothing it should and finds nothing, quietly. One capture
  group at most, and no `(?:`. A match is `{at, text, group}`.
- **`grep(p, text)` is plain text**, and finding nothing is an empty list,
  not an error. So `grep(p, "edit%(")` quietly finds nothing. A pattern over
  a file is `re_lines(read(p), pattern)`.
- **A missing key is a stop, not nil**: `has_key(m, k)` first, or
  `get(m, k, default)`. `(m[k] or 0)` stops on the index.
- **`take`, `last` and `drop` take lists**; a part of a string is
  `sub(s, i, j)`.
- **There is no `write`**: `replace(p, s)` writes a file whole, `append`
  adds, and `create` refuses one already there.
- **Functions are not values**: no closures and no anonymous functions.
  Declare `function name(...)` at the top level.
- **Loops are `for x in l do`** over a list's items (no `ipairs`, no
  `pairs`, no `range`), or `while`. Not-equal is `~=`.
- **`run`'s keep is a size**: `whole = <bytes>`, `tail = <lines>` or
  `head = <lines>`, and `timeout_ms` is required. `must(r)` takes `run`'s
  answer; the git prelude's calls stop by themselves (`git_commit` gives
  the new head, `git_push` nothing), so no `must` around them.
- **A path is the root's.** Another place is a mount, `name:path`; the
  box's are in `~/.config/shale/mounts`. An absolute path is refused.
  A mount line ending in ` ro` is read-only: every change through it
  (`edit`, `replace`, `create`, `append`, `remove`, `mkdir`,
  `remove_tree`, `edits_all`, `zig_rename`, `zig_move`) stops, `refused:
  ... mount `x` is read-only`, before anything is written; reads work. A
  `run` with its `cwd` there runs: Shale cannot see what a program
  writes.
- **The store follows no symbolic link.** A path any part of which, below
  the root or a mount's own folder, is a link stops the run, `refused:
  <path> is a symbolic link`, for a read, a change, `exists`, `stat` and
  a listing alike. A mount's own path is resolved once, when the mounts
  are read.

## The gate: `shale-gate` (installed on the box, 2026-10-17, in `~/.claude/settings.json`)

**A PreToolUse hook on Bash and Monitor** holds a session to Shale
(`tools/shale_gate.zig`, run by `tools/shale-gate.sh`, which turns any
failure, a missing binary included, into a refusal). It passes exactly:

- **a launch:** `[cd DIR && ]shale [--verbose] [--budget N=V]
  [FILE] [NAME=VALUE]...`, every word plain (no quotes, `$`, backticks,
  `;|&<>()*?`), optionally ending `<<'TAG'` (TAG `[A-Z_]+`), with the
  script below and a last line `TAG` that no earlier line is;
- **the escape:** a first line `# want: <tag>: <text>` (Shale should do
  this) or `# out-of-scope: <tag>: <text>` (it never will). The command
  runs, and a line goes to `~/.local/state/shale/wants.tsv`: the date, the
  session, the kind, the tag, the text, and the command's first 160 bytes;
- **a subagent's call.** Its hook input carries an `agent_id` (the hooks
  reference, "Common input fields"), and local cold agents are exempt.
  Checked live on the box (2026-10-17, a logging hook): a subagent's Bash
  call carried `agent_id` and `agent_type`; the top-level session's calls
  carried neither.

Anything else is refused, with one line naming both forms. `shale` is on
`PATH` as `~/.local/bin/shale`, a link to `zig-out/bin/shale`, so a rebuild
here is what every launch runs. The hook, in `~/.claude/settings.json`:

```json
{"hooks": {"PreToolUse": [{"matcher": "Bash|Monitor",
  "hooks": [{"type": "command", "command": "/home/steve/showell_repos/zig-webbox/tools/shale-gate.sh"}]}]}}
```

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
  out of a `glob` unless `{hidden = true}`.
- **A program is run whole, not piped:** `run`'s `stdin` is a string or a
  `whole` result, so a pipeline is two runs with the first's output in
  memory, not a stream. Every run needs `timeout_ms` and a keep.
- **No network but a program's** (`run({"curl", ...})`), and **no
  environment**: a script cannot read a variable, only give one to a
  program (`env`, `secrets`).
- **Git is a prelude over `git`**, not a library: each call is a program
  run, about as fast as typing it, and its errors are git's first line.
- **Jobs are polled:** `job_wait` looks once a second, and nothing tells a
  script the moment a job ends.
- **Integers only, bytes only**: no floats, and a string is its bytes.
