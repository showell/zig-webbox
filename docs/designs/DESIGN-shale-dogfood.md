# Design: Shale, dogfooded (Claude without bash or Python)

**Status: round 2 of 5, then a sixth by a metal-only adversary** (the box and
cold reviewers, 2026-10-18). No code. Steve: five rounds, then a sixth "who
only cares about the metal use case" to attack anything on the Linux side that
seems crufty, whose pushback is mostly vetoed but heard; the final design on
the essay surface; then CC builds it.

## The thought experiment

Steve, 2026-10-18: ban Claude from running bash and Python, which forces us to
dogfood Shale. Fall back to bash or Python only where Shale cannot do the job
yet, and then **either queue the missing feature or justify why it is out of
Shale's scope**. A litmus test: "if we're reaching for Python, then why not do
it in zig?" Shale has behaved identically on bare metal and Linux; that may
relax: **the Linux version can be a superset**, but Shale on metal stays
minimal, **without a bunch of comptime hacks**. Pipe-like behaviour is likely
the best way to make it versatile; git and real stdin are the named gaps. A
repo of its own may come later. Bootstrap: `shale` on bash's search path.

## One rule above the rest: Shale does text itself

**Shale runs another program only to get what that program alone can give**
(git's view of a repository, a compiler's verdict, a server's answer, a disk
image's files): `git`, `zig`, `curl`, the mtools, the repo's own scripts.
**What is then done with the text is Shale's**: filtering, slicing (`head`,
`tail`), matching, counting, sorting, editing. Never `run{"head", ...}`, never
`run{"sed", ...}`. So the text work is budgeted, deterministic, held identical
by the two engines' gate, and the same on metal. (Steve, 2026-10-18: "the idea
is to have shale do those natively and not shell out to unix head/tail".)

## The evidence: what Claude actually ran

One long session on this box: **6,609 Bash calls** (median 259 characters,
p90 1,870). By family (rough):

| family | about | Shale today |
|---|---|---|
| A. file edits: python heredocs asserting a multi-line `old` occurs once, replacing, writing (1,484 of 1,680 `python3` calls), 345 `sed -i`, 208 `cat >` | 2,000 | partly |
| B. filtering a program's output: `2>&1 \| grep \| head`, `\| tail`, `${PIPESTATUS[0]}` (211); about 2,540 greps with alternation | 2,800 | no |
| C. builds and tests: `zig build` (1,391), repo scripts, `timeout` | 1,400 | no |
| D. git: commit 924 (`-qam` 340, `add -A` 326), log 803, push 768, status 627, diff, show, worktree, merge, fetch | 1,900 | no |
| E. reading code: `grep -rn`, `sed -n`, `cat` | 2,600 | Claude Code's Read and Grep tools, not Shale |
| F. long jobs: `setsid nohup` (204), waiting on a file or a PID (`until` 371, `sleep` 243), `kill` (130), `pgrep` (97) | 1,000 | no |
| G. HTTP: `curl` | 160 | no |
| H. disk images: mtools | 50 | no |
| K. QEMU, sudo, ssh | 450 | out of scope |

**What Claude wanted back from a program:** by lines, from both ends, long
lines cut. `head -N`: 3, 20, 5, 30, 40 (only 40 uses past 100 lines); `tail
-N`: 1, 3, 2, 5; `cut -c1-200` about 400 times. About 2-4 KiB.

**Five workflows written both ways (round 2):** Shale is about as long as bash
for edits, commits and jobs, and about half again as long for filtering, which
round 2's additions (alternation, `unique`, the line bounds) close. What it
gains everywhere: the exit code kept with no `PIPESTATUS`, raw multi-line text
with no escaping, every edit asserted, a PID that cannot be lost.

## The architecture: one core, a host's table

- **The core is unchanged and identical on both hosts:** the lexer, the
  parser, both engines (`gate_test.zig` holds them identical), the budgets,
  the store, text, regex, lists, and the text builtins below. Long strings and
  edit transactions are core: they touch nothing outside.
- **What reaches outside is a host's table, at runtime.** A few builtins
  (`run`, `start`, `alive`, `stop`, `wait_for`, `input`) join the closed
  builtin enum, so its completeness check stays; each forwards to
  `Options.host: ?*const Host`, function pointers the host supplies (as
  webbox's `host_facts` and `host_fetch` are supplied by each host). **Metal
  passes null**: every such call stops with a new class `host` ("`run`: not on
  this host"). Its cost on metal is a stub a name. No comptime switch.
- **The Linux host's prelude is the host's too.** The git layer and
  `http_get` are Shale functions the Linux host hands in as extra prelude text,
  indexed at runtime by the same lazy loader the embedded prelude uses. Metal's
  image carries none of it.
- **The Linux table lives outside `src/script/`** (`src/shale_host_linux.zig`,
  beside `script_runner.zig`); `src/script/` never imports `std.process`, and
  a test greps that it does not.
- **The gate:** a test-only `FakeHost` (argv to `{code, out, err, ms}`,
  recording every call), a fresh copy for each engine; the gate compares call
  logs as it compares effects. Steps are charged on bytes, never on
  milliseconds; wall time stays out of the gate. Real processes are tested
  apart, against a small fixture program the build makes.
- **Names, an explicit runtime policy:** `.fat` (the site's data, the
  route's; the only policy metal ever gets, pinned, no default that could
  flip) or `.posix` (a checkout: refuse only `""`, `.`, `..`, NUL, `/` within
  a part; exact case; no path measuring), which the CLI sets.
- **Budgets that only a host with programs has** (`runs`, `run_ms`) appear
  in `budget()` only on such a host, so metal's outputs do not change.

## Roots and mounts

One root is not enough: Claude's logs and job folders live outside every repo
(the scratchpad, `~/runs`), its memory too, and a log inside a repo is
untracked clutter. So **named mounts, each confined like the root**:
`mount:path` in any path builtin (`scratch:gates/summary`). No `..`, no
absolute paths, still. Standing mounts are named once in the user's
`~/.config/shale/mounts` (`scratch = /tmp/...`, `runs = ~/runs`), so a
command carries no flags for them (Steve dislikes CLI arguments); the root is
the working directory, as now.

## Running a program: `run`

    run(argv, {timeout_ms = 600000, head = 20, tail = 5, width = 200,
               log = "scratch:test.log", cwd = "x", input = s, merge = true})
      → {code, out, err, ms, timed_out, lines, cut}

- **`timeout_ms` is required.** A default is a decision nobody made.
- **What comes back is bounded by lines, from both ends**, as Claude used
  `head` and `tail`: the first `head` and last `tail` lines, each cut at
  `width`, `cut = true` when anything was left out, `lines` the real count.
  (Round 2: a byte bound from the tail alone loses a compile error at the top
  of a long log.)
- **`log` keeps the whole output** in a file, for filtering more than once:
  the commonest habit in the evidence (1,341 `/tmp`, 1,074 scratchpad uses).
- **The child's whole process group is killed** on a timeout, and the child
  dies with `shale` (PR_SET_PDEATHSIG, and `shale` kills its groups on
  SIGTERM and SIGHUP), so a run never outlives the tool call that made it.
- `argv` expands a leading `~` and takes lists spliced with `concat`.
- **Budgets:** `runs` (how many) and `run_ms` (wall time in all).
- **Pipelines** pass through the script: `run(b, {input = a.out})`, or Shale
  filtering `a.out` or the log. No OS pipes between children.
- **`fail(msg)`** ends a run with class `fail` and exit 1, so `shale ... &&
  ...` composes.

## Text, natively

For `run`'s output, a log, or any string: `lines(s)`, `head(s, n)`, `tail(s,
n)`, `grep_in(s, pattern)` → `{line, text}` (and `{invert = true}`, `{after =
n, before = n}`), `unique(list)`, `concat(a, b)`. **Regular expressions gain
alternation (`|`)**: Thompson matching takes it in linear time, as it takes
the rest; still one capture group, no backreferences.

## Edits that work

The python pattern: several exact replacements to one file in memory, each
asserted to occur exactly once, one write, every literal multi-line.

- **Long strings, Lua's, specified exactly:** `[==[ ... ]==]`, the level must
  match; the first newline right after the opener is dropped; bytes are raw
  (no escapes, no `\r\n` folding, so a CRLF file can be matched); a newline
  before the closer is part of the string. **Docs and examples always use a
  level** (`[==[`): `]]` is common in Zig. A syntax error right after a long
  string hints the closer it met ("closed at L:C; use `[===[`"). Line and
  column advance through the string, so stops after it are right.
- **`edits(p, {{old, new[, {count = N}]}, ...})`**: applied in memory, each
  asserted (`count` defaults to 1), one diff, one write. **`create(p, text)`**:
  refused if the file exists. `replace` prints a diff too.
- **The staged overlay, CLI only (an explicit `Options` field):** changes go
  to a per-run overlay of file contents; `read`, `read_or`, `read_lines`,
  `line_at`, `grep`, `count_*`, `find_in`, `exists`, `stat` and `edit` look
  there first; `ls`, `walk` and `is_dir` over a folder with a staged create or
  remove stop ("staged in this run"); `remove_tree` is refused in a staged
  run.
- **Commit points:** under `--write`, **every `run` and `start` writes the
  overlay to disk first**, so the build sees the edits (round 2: staging past
  a build would compile the old file). A run that ends early leaves on disk
  what was written at its commit points, and nothing after the last one: said
  so. A commit checks everything first, then writes file by file, each file
  atomic; the set of files is not.
- **Diffs have their own allowance**, apart from the output budget, so a big
  edit cannot stop and roll itself back.

## The dry run, honest

A program escapes the root and any dry run: `zig build` writes into the tree,
`git status` rewrites the index, a build.zig is arbitrary code. And a dry run
that answers `{dry = true}` for a program takes a different branch than the
real run. So: **a dry run never runs a program.** It stages and prints every
diff; the first `run` or `start` stops it with class `dry` ("would run: zig
build test; --write runs it"). **`--write` runs everything.** The dry run is a
preview, not the everyday safety: Claude will pass `--write` on nearly every
call that runs a program, and the design says so.

## Git, in the Linux host's prelude, over `run`

No native reading of `.git`. Reading: `git_status(repo)` → `{{code, path}}`
(`--porcelain=v1 -z`), `git_log(repo, n)` → `{{hash, subject}}`, `git_diff`,
`git_show`, `git_clean(repo)`. Changing: `git_add(repo, paths)`,
`git_commit(repo, msg, {paths = ..., tracked = true})` (`tracked`: `-a`, the
`-qam` habit; neither, for a merge commit), the message by `-F -`;
**`git_commit` refuses a message without a `Co-Authored-By:` line**, which
Claude writes in each body (the model's name is the session's, never stored).
`git_push`, `git_fetch`, `git_merge_ff`, `git_worktree_add`; each takes a
repo, as `git -C`.

## Long jobs

`start(argv, {log, cwd})` → `{pid, started}` (its own session, no terminal,
no death signal: it outlives `shale` by design). `alive(job)` and `stop(job)`
take that record and check `/proc/<pid>/stat`'s start time before acting, so
a reused PID is never signalled. `wait_for({job, file, contains, timeout_ms})`,
`timeout_ms` required and under the Bash tool's ten-minute ceiling. The box's
detach recipe in one tested place, ending two of its bug classes ("`a && b &`
hides the PID", "wait on a PID, never a pattern").

## Stdin

Steve named real stdin as a gap. **With no FILE and no `-e`, the script is
stdin** (`shale <<'SHALE' ... SHALE`, the launch convention: `EOF` lines occur
in files Claude edits). **With a FILE or `-e`, stdin is data**, read by
`input()`, whole, up to an `input_bytes` budget (past it is a stop, never a
silent cut). A stdin script reports itself as `stdin`. Last in the order: the
heredoc launch is the common case, and a pipe into Shale loses the producer's
exit code, which `run` keeps.

## The CLI's defaults

- `now()` is the wall clock (`SHALE_NOW` pins it for tests); today it is 0.
- Output: 16 KiB for the script, diffs apart.
- Steps: the default 5M (bulk work is a step per 16 bytes; a 10 MB log scan
  fits).
- **Terse by default:** the `── used:` line only when a budget passed half,
  or on a stop; the effects list on `--verbose`.

## The fallback rule (for Steve to adopt)

> Claude uses `shale` for every file edit, every program run whose output it
> reads, every git operation, and every wait on a job. When Shale cannot do a
> job yet, Claude may use bash or Python for that call, and in the same turn
> either appends one line to `docs/SHALE-WANTS.md` (the date, the command, the
> Shale feature that would replace it), or writes a one-line reason under its
> `## Out of scope`. A want seen three times goes to the queue. Before Python:
> a job too big for Shale (a binary format, statistics over a big log, a
> simulator) is a zig tool in the repo's `tools/`, its compile time earned by
> being run more than once; Python only as a throwaway oracle.

**What stays bash:** QEMU and KVM gates (detachment, sudo, mounts), `sudo`,
interactive programs, ssh to prod, and the `shale` launch itself. Reading code
is Claude Code's own Read and Grep tools. Copying, moving and removing binary
files is `run` (`cp`, `mv`), not new store builtins.

## The order of work (for CC, after round 6)

1. Edits that work: long strings, `edits`, `create`, counts, the staged
   overlay with commit points, diffs' own allowance, the script from stdin.
2. The host table, `run` (line bounds, `log`, group kill, death signal),
   `fail`, mounts, the `.posix` policy, the CLI's defaults.
3. Text: `head`, `tail`, `grep_in`, `unique`, `concat`, regex `|`.
4. The git prelude, from the Linux host.
5. `start`, `alive`, `stop`, `wait_for`.
6. `input()`, `http_get`.

**Its own repo** earns its keep after (2), once the host seam exists.

## Open questions for the next rounds

- Is the ban enforceable rather than remembered? (A Claude Code hook that
  refuses a Bash call not launching `shale` unless it names its want or its
  reason?)
- Are mounts the right shape, or a second `--root`?
- Feasibility in Zig 0.16: spawning, process groups, the death signal,
  reading two pipes without blocking, killing on a timeout.
- Does the language stay coherent with these additions (names, error classes,
  what `print` of a record does)?

## Rounds

**Round 1** (a cold reviewer with the session's 6,609 commands): the families
and counts; the host table; `run` first; the edit gaps (long strings, the dry
run's missing overlay, no rollback); git over `run`; the fallback rule.

**Round 2** (a cold reviewer writing the five commonest workflows in the
proposed Shale): the reading-verb allowlist unsound (builds write, git status
writes, a dry branch differs), so a dry run never runs a program; the overlay
and `run` (commit points); output bounded by lines from both ends, and a
`log`; mounts; alternation and `unique`; diffs apart from the output budget;
`env` dropped and the trailer required in the message; git in the Linux host's
prelude, not metal's image; long strings specified; the child's death signal
and verified PIDs; the CLI's clock and terse defaults.
