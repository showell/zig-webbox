# Design: Shale, dogfooded (Claude without bash or Python)

**Status: final, after six rounds** (five, and a sixth by a metal-only adversary) (the box
and cold reviewers, 2026-10-17). No code yet for the host; the core pieces that
have not moved since round 1 are CC's now (metal-vmm QUEUE 232). Steve: five
rounds, then a sixth "who only cares about the metal use case" to attack
anything on the Linux side that seems crufty, whose pushback is mostly vetoed
but heard; the final design on the essay surface (mounts explained in
detail); then CC builds the rest.

## The thought experiment

Steve, 2026-10-17: ban Claude from running bash and Python, which forces us to
dogfood Shale. Fall back to bash or Python only where Shale cannot do the job
yet, and then **either queue the missing feature or justify why it is out of
Shale's scope**. A litmus test: "if we're reaching for Python, then why not do
it in zig?" **The Linux version can be a superset**, but Shale on metal stays
minimal, **without a bunch of comptime hacks**. Pipe-like behaviour is likely
the best way to make it versatile; git and real stdin are the named gaps. A
repo of its own may come later. Bootstrap: `shale` on bash's search path.

## Who writes Shale

**A well-meaning agent, who makes mistakes** (Steve, 2026-10-17). So the
design is not paranoid about hostile scripts (no defences against a lexer
denial of service), but careful about slips: a mistake must end in a clear
stop, never a wrong answer, a panic, or damage. That is the test for every
refusal and every guard below (`run`'s refusals catch habits, not
adversaries; mounts are naming, not a sandbox).

## Two rules above the rest

**1. Shale does text itself.** Shale runs another program only to get what that
program alone can give (git's view of a repository, a compiler's verdict, a
server's answer, a disk image's files). What is then done with the text is
Shale's: filtering, slicing, matching, counting, sorting, editing. Never
`run{"head", ...}`; `run` refuses it. (Steve: "the idea is to have shale do
those natively and not shell out to unix head/tail".)

**2. Zig for bytes and the world, Shale for thin policy.** (Steve leans to Zig
builtins.) A builtin when it does real work on bytes in bulk or touches the
outside (regex, the edit transaction, long strings, `run`, jobs): a bulk
builtin costs a step per 16 bytes where a Shale loop pays per operation.
Prelude Shale only for a thin layer whose cost is in the builtins it calls,
measured (round 4): `re_lines` over 16 KiB spends about 164k steps in the
regex and about 3k in its loop. Prelude code is checked by the gate for free,
charged honestly with no charge table, read when it stops, and the Linux
host's prelude never reaches metal.

## The evidence: what Claude actually ran

One long session on this box: **6,609 Bash calls** (median 259 characters,
p90 1,870). By family (rough):

| family | about | Shale today |
|---|---|---|
| A. file edits: python heredocs asserting a multi-line `old` occurs once, replacing, writing (1,484 of 1,680 `python3` calls), 345 `sed -i`, 208 `cat >` | 2,000 | partly |
| B. filtering a program's output: `2>&1 \| grep \| head`, `\| tail`, `${PIPESTATUS[0]}` (211); alternation about 2,540, `grep -v` 540, `-i` 219, `\b` 263, `grep \| grep` 178, context 141, counts 227 | 2,800 | no |
| C. builds and tests: `zig build` (1,391), repo scripts, `timeout`, `VAR=value` prefixes (165 `TRANSPORT=`) | 1,400 | no |
| D. git: commit 924 (`-qam` 340, `add -A` 326), log 803 (a range about 111, `--format` 139), push 768, status 627, pull 173, diff, show, worktree, merge, fetch | 1,900 | no |
| E. reading code: `grep -rn`, `sed -n`, `cat` | 2,600 | Claude Code's Read and Grep tools |
| F. long jobs: `setsid nohup` (204), waiting on a file or a PID (`until` 371), `kill` (130), `pgrep` (97) | 1,000 | no |
| G. HTTP: `curl`, 51 with a bearer key read from a file | 160 | no |
| H. disk images: mtools | 50 | no |
| K. QEMU, sudo, ssh | 450 | out of scope |

**What Claude wanted back from a program:** by lines, from both ends, long
lines cut, **after a filter**: `head -N` mostly 3-40, `tail -N` 1-5, `cut
-c1-200` about 400 times. About 2-4 KiB.

**Round 5 replayed 80 real consecutive calls** (### 4118-4157, a gate run and
its commits; ### 5180-5219, a Dog Park tidy-up) in this design: **1 escape**
(a Python FAT reader), 11 awkward, the rest clean (30 of them Claude Code's
Read, Grep, Edit or Write tools). Two real bash bugs in those stretches go
away: `cmd | tail -3 && next` testing tail's exit code, and `setsid ... & P=$!`
taking the wrong PID. What round 5 found missing is in this version.

## The architecture: one core, a narrow seam

(Round 6, the metal adversary, narrowed this seam; its record is under
"Rounds".)

- **The core is unchanged and identical on both hosts:** the lexer, the
  parser, both engines (`gate_test.zig` holds them identical), the budgets,
  the store and its FAT names, text, regex, lists. **`script.report` is
  frozen** by a golden test of a whole route reply: the route's four readers
  (dog-park `test_shale.mjs`, metal-vmm `script-refused.shape`,
  `judge_gopher.py`, angry-gopher's tests) see nothing change.
- **One builtin reaches outside: `host(name, ...)`.** It forwards to
  `Options.host: ?*const fn`, one function pointer the Linux CLI supplies (as
  webbox's `host_facts` and `host_fetch` are supplied by each host). **The
  names Claude types (`run`, `real`, `job_start`, `job_alive`, `job_stop`,
  `job_wait`) are Linux-prelude wrappers** (`function run(argv, opts) return
  host("run", argv, opts) end`); the host checks their arguments and stops
  `argument`. Metal passes null: `host` stops with class `host` ("`run`: not
  on this host"), one enum entry and one stub in its image.
- **One hook for paths:** `Options.path_hook`, called at the top of
  `pathArg` only when it is set. **Mounts, `real()` and the mounts file live
  in the Linux host, behind it.** With no hook, metal's `pathArg` is
  byte-identical to today's, and cannot produce a path outside its root. FAT
  names stay the rule on Linux too: all 1,140 tracked files in the five repos
  pass them, so a looser policy would buy nothing.
- **Preludes, a list in `Options`:** core's (comptime-indexed, as now) and,
  on Linux only, the Linux host's (`@embedFile`d in the host), **a repo's own**
  (`.shale/prelude.shale` at the root, tracked) and **a user's**
  (`~/.config/shale/prelude.shale`; `SHALE_PRELUDE` pins it in tests). The
  indexer becomes one function, run at comptime for core and at runtime for
  the others; a later prelude may not redefine an earlier one's name (a stop,
  naming both). Metal's list is core alone. Stop frames name which prelude a
  line is in, in the CLI's printer only.
- **The dry run is `Mode.dry_run`**, which exists and means "no effects": the
  CLI's host refuses `run` and `job_start` in it with a stop `attempt` cannot
  catch (class `budget`, `runs`, one line in diag.zig), and counts its own cap
  on programs (64 a run). No `runs` field in the core's budgets, nothing new
  in `budget()`.
- **The Linux host lives outside `src/script/`**, split at the 1000-line rule
  (`src/shale_spawn.zig`, the raw fork, exec and poll loop; `src/shale_keep.zig`,
  pure; `src/shale_host_linux.zig`, the host function, the path hook, mounts,
  jobs). `portable_test.zig` already refuses `std.process` and `std.os` in
  `src/script/`.
- **The gate:** a test-only fake host that fakes **only the spawn** (bytes
  in, bytes out, recorded): option parsing, the filter, the keep and the
  charging are the real code in both engines. Mounts in a gated test lie
  inside the root copy, remapped per engine. Not in the gate: real children,
  wall time, signals, `/proc`.

## Mounts

One root is not enough. Claude's logs and job folders live outside every repo
(a per-session scratchpad, `~/runs`, `~/build`), its memory too, and a log
inside a repo is untracked clutter. So **a path may begin with a mount's
name**: `runs:gates/summary`, `memory:MEMORY.md`, `repos:dog-park/README.md`,
`home:.gopher_api_key`.

- **Where they are named:** `~/.config/shale/mounts`: `name = value` a line,
  `#` comments, blank lines; a value is an absolute path or begins with `~/`;
  a relative value, a duplicate name or a malformed line stops the run, naming
  the line. No flag on a command (Steve dislikes CLI arguments); the root is
  the working directory, as now. A missing file is no mounts; a mount whose
  folder is missing stops when it is used; an unknown mount stops, naming the
  known ones. Tests pin `SHALE_MOUNTS=<file>`. (A value naming a variable, for
  the per-session scratchpad, waits for a need: v1 uses `runs`.)
- **What a mount path may be:** within the mount, as a root's path is within
  the root: no `..`, no absolute paths. `runs:` alone is the mount's top. A
  first part with `:` in it is always a mount's name. **`""` is the root
  itself**, wherever a folder is wanted (a repo, a `cwd`).
- **Naming, not a sandbox.** Confinement is lexical: a symlink inside a mount
  leads where it leads, and `run` reaches anywhere anyway. Mounts make paths
  short and stable, not safe.
- **In logs:** paths print as the script wrote them, never expanded.
- **Into a program:** a child takes real OS paths. `run`'s path options
  (`cwd`, `log`, `secrets`' files) take Shale paths and the host resolves
  them; **argv is passed verbatim**, because mount-shaped strings must pass
  untouched (`master:src/x.zig`, `::gopher-metal.conf`, `boot.img@@1048576`,
  URLs). **`real(p)`** gives a Shale path's absolute OS path for argv; logs
  show it by its mount again. A relative argv[0] (`./gates.sh`) resolves
  against `cwd`.

## Running a program: `run`

    run(argv, {timeout_ms = 600000, re = "error|fail", not_re = "cached",
               nocase = true, before = 2, after = 2,
               head = 20, tail = 5, width = 200, whole = N,
               log = "runs:x/test.log", cwd = "repos:x", stdin = r,
               env = {TRANSPORT = "pci"}, secrets = {K = "home:.gopher_api_key"},
               want = "tag: text"})
      → {argv, code, ended, out, ms, total_lines, matched_lines, kept_lines}

- **`timeout_ms` is required, and so is a keep** (`head`, `tail`, or
  `whole`): a default is a decision nobody made. Claude's defaults live in
  its user prelude (`sh(argv, opts)` fills `head = 20, tail = 5, width = 200`).
- **`ended`** is `"exit"`, `"timeout"` or `"signal"`; `code` is the exit code,
  nil unless `ended` is `"exit"`.
- **Filter, then keep.** On each line as it streams: `re` keeps the lines
  that match, `not_re` drops those that do, both Shale's regex, `nocase`
  folds ASCII case, `before` and `after` keep context; then **`head` and
  `tail` keep lines from both ends**, each cut at `width` (200 unless said).
  `out` is those lines, with a line `… N lines left out …` where lines were
  dropped between head and tail. `total_lines` counts the output,
  `matched_lines` what passed the filter (`grep -c`), `kept_lines` what is in
  `out`.
- **`whole = N`** keeps everything up to N bytes, never cut, an `argument`
  stop past it, and cannot be combined with a filter or a keep: what the git
  prelude uses.
- **`stdin` takes a result `r` from a `whole` run, or a string** a script
  built itself; a kept result (with its marker) is refused, by its record, not
  by guessing at text.
- **stdout and stderr are one stream**, as `2>&1`. `log` keeps it whole, as
  it streams, truncating a file already there; **the host writes it itself**
  (no new path into the core's effects), and the CLI lists it among what the
  run wrote.
- **`env` adds to the inherited environment** (`ZIG_PROGRESS` removed). There
  is no `env` builtin: a script cannot read the environment.
- **`secrets` never become values, and never come back** (a script may
  still `read("home:.key")` into a value: that is its own choice, and
  SHALE-AGENTS.md says to use `secrets`): the host reads each
  file (trimmed) into the child's environment; logs print `K=<secret
  home:.gopher_api_key>`; **the host replaces the secret's bytes with
  `<secret K>` in everything the child prints** (`out`, `log`), before the
  filter, since a child may echo its environment or `curl -v` its headers.
- **`must(r)`** (Linux prelude): when `r.ended ~= "exit"` or `r.code ~= 0`,
  prints `r.out` and fails with `` `<argv>` exited <code> `` (or "timed
  out"); else gives `r`. The `&&` of a shell chain.
- **`fail(msg)`** ends a run with class `fail`; `attempt` catches it; the
  parser's refusal of `error` names it.
- **What `run` refuses** (class `refused`, naming `want`), matched on argv[0]'s
  basename with any version suffix dropped (`python3.12` is `python3`):
  - shells and interpreters: `bash`, `sh`, `dash`, `zsh`, `busybox`,
    `python`, `python3`, `perl`, `node`;
  - rule one's text tools: `head`, `tail`, `grep`, `sed`, `awk`, `gawk`,
    `cut`, `sort`, `uniq`, `wc`, `cat`, `tr`;
  - wrappers that would run either: `env`, `xargs`, `timeout`, `nice`,
    `nohup`, `setsid`, `stdbuf`, `time`;
  - **a program by path that git does not track** (a script Claude just
    wrote is the commonest hole: round 5's ### 4152); a repo's own tracked
    script is allowed.
  With `{want = "tag: text"}` any of them runs and is logged as a want.
  Habits, not adversaries.
- **Pipelines** pass through the script: `run(b, {stdin = a, ...})`.
- **Charged:** a step per 16 bytes of output read (as bulk work), in
  `read_bytes`.

**How it is built** (round 3, from zig 0.16's std): std's `process.spawn` has
no hook before exec, so no death signal and no `setsid`; its `Child.kill`
signals the PID alone and then waits without bound. So **one raw spawn**
(`linux.fork`, `prctl(PR_SET_PDEATHSIG)` and a `getppid` check, `setpgid` or
`setsid`, signals unblocked in the child, stdin `/dev/null` unless given,
`dup2`, `chdir`, `execve` with std's PATH loop copied), and **one poll loop**
over the output pipe, a non-blocking stdin writer, a `pidfd` for the exit, a
`signalfd` for TERM and HUP, and the deadline. On a timeout or a signal: TERM
to the group, 2 seconds' grace, KILL; after the leader exits, drain for at
most 200 ms and stop reading. **The keep is a pure file:** the first N lines,
a ring of the last M, each cut at `width`, the counts: memory bounded by
`(N+M)·width`. About 900 lines and 500 of tests.

**Chunk 0's experiment, done (the box, 2026-10-17):** a script that traps and
logs every signal, with one child in its process group and one in a session
of its own, run under a 4-second Bash timeout.
- **Claude Code does not kill a Bash call past its timeout: it moves it to
  the background, still running.** So a `shale` past the call's timeout keeps
  going, and **`run`'s own `timeout_ms` is what ends a program**, always:
  Claude sets it, the tool's timeout does not.
- **Stopping a task (TaskStop, or the session ending) sends TERM to the whole
  process tree**, the child that made its own session included, **then KILL**
  to what survives (the script trapped TERM and was still gone).
- So a death signal and `shale`'s relaying of TERM are a second line, for a
  `shale` ended some other way; Claude Code's own stop already reaches every
  descendant. And a job must not be a descendant of any task when its starter
  is stopped: **`job_start`'s reaper detaches by a double fork** (re-parented to
  init), or stopping the `shale` that waits on a job would kill the job.
- The box's curl is 8.5.0: `--variable` and `--expand-header` are there.

## Text

- **Core builtins:** **`last(l, n)`**, the last n of a list (round 6: `take`
  with a negative count stays the loud stop it is, so a count gone negative on
  the live site never silently becomes the tail).
  **Regular expressions gain alternation** (`|`, lowest precedence, leftmost
  alternative first; a group around it is the one capture group, `(?:` stays
  refused) **and `\b`** (a word boundary, ASCII), linear in Thompson's way;
  still one capture group, no backreferences. **`{nocase = true}`** on
  `re_find`, `re_match` and the Linux prelude's `re_lines`; the regex cache is
  keyed by the pattern and `nocase` both, and the folding is charged.
- **The Linux prelude:** `re_lines(s, pattern[, {invert, nocase}])` →
  `{{line, text}}`; `head_lines(p, n)` and `tail_lines(p, n)` → lists (a tail
  reads back from the end in doubling parts until n lines fit; a missing file
  is nil, not a stop); `unique(list)` (strings, first seen first);
  `grep_all(p, lit)` in parts, beside `count_all`, numbering lines across the
  parts; `newest(p, n)` → the n entries of a folder by modified time, newest
  first (`ls -t | head`).
- **`glob(pattern, {hidden = true})`** takes dot-names too.
- **Naming, kept coherent** (round 4): a literal by default, `re_` where the
  pattern is a regex; `_lines` and `_in` keep meaning "of a file"; the subject
  first, the options map last.
- **No streaming past the call-bytes cap:** a builtin is bounded, never cut.
  The CLI is to raise `call_bytes` instead (proposed: 64 MiB, "The CLI's
  defaults"; the code's default is `interp.Budgets.call_bytes`).

## Edits that work (core: metal-vmm QUEUE 232)

The python pattern: several exact replacements to one file in memory, each
asserted, one write, every literal multi-line.

- **Long strings, Lua's, specified exactly:** `[=[ ... ]=]`, `[==[ ... ]==]`;
  **a level is required** (`[[` refused: code being edited is full of `]]`);
  the level must match; the first newline right after the opener is dropped;
  bytes are raw (no escapes, no `\r\n` folding); a newline before the closer
  is part of the string. **`--[==[ ... ]==]` is a block comment**, as Lua's;
  `--[[` is refused as `[[` is, and `--[=x` is a line comment. **The fuzz
  corpus covers it before it lands.** Not against an attacker: Shale's authors
  are well-meaning agents (Steve, 2026-10-17: "we don't have to be paranoid
  about lexer denial-of-service attacks"), but they make mistakes (an unclosed
  long string, a wrong level, end of file inside a closer), and on metal a
  lexer bug is a kernel panic where a clean stop was owed.
  A syntax error right after a long string hints the closer it met. Line and
  column advance through it.
- **`edit(p, {{old = ..., new = ...[, all = true][, word = true]}, ...})`**:
  `edit`'s second form, its own option names; at most 64 edits a call, every
  pass's bytes charged, refused in a background run before an argument is
  read. **The edits apply in sequence**,
  each to the result of the one before; each asserted (once, unless `all`);
  one diff; one write; it gives the number of replacements made in all. A
  failing edit writes nothing, prints no partial diff, and its stop names
  which edit failed (its index) and why.
- **`edits_all({{p, {...}}, ...})`** (Linux prelude): checks every file's
  edits first, writes nothing unless all hold, then file by file, each atomic;
  the set is not (said so).
- **`create(p, text)`** (Linux prelude): refused if the file exists.
- `replace` keeps its behaviour on metal. The CLI's proposed output default
  ("The CLI's defaults"; the code's is `interp.Budgets.default_output_bytes`)
  covers an edit's diff.

## The dry run, honest

**Superseded (2026-10-17):** Steve deleted the dry run; every run writes, and on Linux git is the undo (SHALE.md, "What was decided"). This section and the dry run's mentions below are the design as it was.

A program escapes the root and any dry run (`zig build` writes into the tree;
`git status` rewrites the index). So **a dry run runs no program**
(`Mode.dry_run`, above). It checks and
prints every edit's diff against the disk as it is (a chain of edits to one
file is one `edit` list, so a dry run sees what `--write` would), and the
first `run` or `job_start` stops it as `budget runs` ("a dry run runs no
program; --write runs it"), which `attempt` cannot catch. **`--write` runs
everything.** The dry run is a preview, not the everyday safety: Claude will
pass `--write` on nearly every call that runs a program, and the design says
so.

## Git, in the Linux host's prelude, over `run`

No native reading of `.git`. **`repo` is a Shale path** (`""` the root,
`repos:dog-park`), resolved through `real` inside the prelude, as `git -C`.
Reading calls give data and stop (`fail`) on a git error; changing calls are
`must`ed.

- Reading: `git_status(repo)` → `{{code, path[, from]}}` (`--porcelain=v1
  -z`; untracked files are `"??"`; a rename has `from`); `git_log(repo, {n,
  range = "a..b", ref, fields = {"hash", "subject", "date", "author"}})` →
  records; `git_diff(repo, {range, paths, stat = true})` → text;
  `git_show(repo, "rev:path")` → text; `git_ls_files(repo)` → paths;
  `git_is_clean(repo)` → boolean; `git_head(repo)` → the short hash.
- Changing: `git_commit(repo, msg, {add = "tracked" | "all" | {paths}})` (`-a`,
  the `-qam` habit; `add -A`; named paths; none for a merge commit), the
  message by `-F -`; `git_push(repo[, {remote, branch}])`, `git_fetch(repo[,
  {all = true}])`, `git_pull_ff(repo)`, `git_merge_ff(repo, ref)`,
  `git_worktree_add(repo, dir, {branch, new = true})`,
  `git_worktree_remove(repo, dir, {force})`, `git_branch_delete(repo, name,
  {force})`. Each a 60-second timeout unless given.
- **Claude's commit** is the user prelude's `commit(repo, msg, opts)`, which
  refuses a message without a line beginning `Co-Authored-By:` and calls
  `git_commit`.

## Long jobs

- `job_start(argv, {log, cwd, env})` → a job: **`log` required**; its own
  session, no terminal, stdin `/dev/null`, no death signal (it outlives
  `shale` by design). **A detached `shale` reaps it** (a small supervisor in
  the same binary, detached by a double fork so it is no task's descendant:
  stopping the `shale` that waits on a job must not kill the job), writing the job's record to `<log>.job` (pid, pgid,
  start time, and, once it ends, its exit code and when). No `secrets`: a
  detached job's log has nobody to scrub it.
- **A job is found again by that path:** `job_alive`, `job_stop` and
  `job_wait` take a job or `"runs:x/gates.log.job"`, so a later Bash call
  carries on where an earlier one started.
- `job_alive(job)`: `kill(-pgid, 0)`, after `/proc/<pid>/stat`'s start time
  (parsed from its last `)`, compared raw) matches. A job whose leader exited
  but whose group lives is alive.
- `job_stop(job)`: TERM to the group, 2 seconds' grace, KILL, after the start
  time matches. (A group signal is `kill(-pgid)`; the check narrows the reuse
  race, it does not close it: said so.)
- `job_wait(job, {timeout_ms, file, contains})` → `{ended = "found" |
  "exited" | "timeout", code}`; `timeout_ms` required; it looks every second.
  Shale cannot know the Bash call's own `timeout`: Claude keeps
  `timeout_ms` under it (120 s unless raised, at most 600), and SHALE-AGENTS.md
  says so.
- Jobs count against the host's cap on programs; `job_alive` and `job_wait`
  do not. `job_start`
  and `job_stop` need `--write`.
- `job_of(pid)`, adopting a job a repo script detached itself, waits for a
  need.

## Stdin

Steve named real stdin as a gap. **With no FILE and no `-e`, the script is
stdin** (`shale <<'SHALE' ... SHALE`, the launch convention: `EOF` lines occur
in files Claude edits); a stdin script reports itself as `stdin` (`stdin:L:C`
in a stop); a terminal on stdin with no script is refused with a usage line.
**Data on stdin** (`input()`, with a FILE or `-e`) is last in the order: a pipe
into Shale loses the producer's exit code, which `run` keeps.

## Error classes

Two new: **`host`** (a call not on this host; a spawn that fails: its
program not found) and **`fail`** (`fail(msg)`, `must`; catchable). A dry run
is a `budget runs` stop, a refused program is `refused`, a `whole` past its
bound is `argument`, a timeout is a result (`ended`). Every stop stays one
line and its trail: `fail: \`zig build test\` exited 1`, `host: \`run\`: not
on this host`, `budget runs: a dry run runs no program; --write runs it`,
`refused: \`run\` of \`sed\`: Shale edits text itself; {want = ...} to run it
anyway`.

## The CLI's defaults (proposed)

None of this is built; the code's defaults are `interp.Budgets`.

`now()` is the wall clock, in seconds (`SHALE_NOW` pins it for tests).
Output 64 KiB. `call_bytes` 64 MiB. Steps 5M. 64 programs a run under
`--write`, counted by the host. **Terse, in `script_runner.zig` only** (the
route's `report` is frozen): the `── used:` line only past half a budget or
on a stop; the effects list on `--verbose`. Existing tests that pin the old output or a 0
clock are re-pinned, saying so.

## Making the ban real

Remembered rules fail; this one is enforced.

- **Who is held to it: top-level Claude and CC; local cold agents are
  exempt** (Steve, 2026-10-17: "We will probably exempt local cold agents from
  needing to learn shale. Top-level Claude and CC should be able to amortize
  the learning curve"). So the hook should tell a subagent's call from the
  top-level one's: **unverified whether PreToolUse's input says so** (an
  agent id, a transcript path); the first step of chunk 6 is to look. **If it
  cannot tell, subagents are held too** and the hook goes in user-wide (Steve:
  "If it's not easy to exempt the subs, then we can just have subs do shale
  as well. My experience is that Claude masters languages very quickly"); a
  cold-agent brief then names SHALE-AGENTS.md.
- **A PreToolUse hook on Bash and Monitor** (`~/.claude/settings.json`) runs
  `shale-gate`, a zig tool in
  zig-webbox's `tools/` (a pure classifier, tested), behind a wrapper that
  turns every failure into a refusal (exit 2), so a missing binary refuses
  rather than passes. It reads the hook's JSON (`tool_input.command`) and
  passes exactly:
  - **the launch:** optionally `cd WORD && `, then `shale` (or an absolute
    path ending `/shale`) and its words (`--write`, `--verbose`, `--budget`
    and its `N=V` as two words, a FILE, `NAME=VALUE`), each word plain (no
    quotes, `$`, backticks, `;|&<>()*?`), and optionally `<<'TAG'` ending line
    1 (TAG `[A-Z_]+`), a body, and a last line exactly `TAG` (trailing spaces
    allowed), which occurs nowhere else in the body;
  - **the escape:** a first line `# want: <tag>: <text>` or `# out-of-scope:
    <tag>: <text>` (tag `[a-z0-9-]+`), which it lets run and logs (date,
    session, kind, tag, text, the command's first 160 bytes) to
    `~/.local/state/shale/wants.tsv` with one append (`O_APPEND`, a line under
    4 KiB, so concurrent hooks never interleave), outside every repo.
  - Anything else is refused with one line naming both forms.
- **Claude curates** that log into zig-webbox's `docs/SHALE-WANTS.md`; a tag
  seen three times goes to the queue.
- **Read, Grep, Edit and Write stay allowed**: the ban is on bash and Python,
  and Edit is better than a python heredoc for one replacement.
- **Bootstrap:** a broken `shale` is fixed through the escape
  (`# out-of-scope: bootstrap: ...`).

## The fallback rule (for Steve to adopt)

> Claude uses `shale` for every program run whose output it reads, every git
> operation, every multi-edit and every wait on a job; Claude Code's own Read,
> Grep, Edit and Write tools for the rest. When Shale cannot do a job yet,
> Claude uses the hook's escape for that call (`# want:` with the feature that
> would replace it, or `# out-of-scope:` with why it is not Shale's). Before
> Python: a job too big for Shale (a binary format, statistics over a big log,
> a simulator) is a zig tool in the repo's `tools/`, its compile time earned
> by being run more than once; Python only as a throwaway oracle, through the
> escape (`python3` on a tracked file, logged).

**What stays bash, through the escape:** QEMU and KVM gates (detachment,
sudo, mounts), `sudo`, interactive programs, ssh to prod. Copying and moving
binary files is `run` (`cp`, `mv`), not new store builtins.

## What metal's image gains (round 6's count)

Round 4 estimated about 390 lines; round 6, counting what that table left out
(the prelude loader's list, the regex cache key, the report's freeze, the
names policy in `store.zig`), put the round-5 design at 600-800 core lines
plus a policy in the store every lynrummy.com route writes through. Round 6's
accepted changes take that back down:

| item | core lines | on metal |
|---|---|---|
| `host` (one enum entry, one stub), `Options.host` | about 15 | a stub |
| `Options.path_hook` | about 10 | none: `pathArg` byte-identical without it |
| the prelude list in `Options`; the indexer as one function | about 60 | none: core alone, comptime as now |
| the dry run's stop class (one line in diag.zig) | about 5 | none |
| `fail` and its class | about 25 | useful: an assertion |
| long strings and block comments, fuzzed | about 50 | marginal |
| `edit`'s list form, capped | about 90 | low: Dog Park's runs are background, which refuses edits |
| regex `\|`, `\b`, `nocase`, the cache key | about 130 | **useful** (`error\|panic` in a scan) |
| `last` | about 10 | useful |
| everything else (the host, mounts, git, jobs, the text helpers, `create`, `edits_all`, `must`) | 0: the Linux host and its preludes | none |

**About 400 lines, no change to `store.zig`, measured as the whole gopher.elf
image's size before and after** (round 6: the script module alone would miss
what the store and the route carry).

## The queue, in Shale (Steve, 2026-10-17)

The queue Claude and CC share (metal-vmm's `QUEUE.md`, `QUEUE-ARCHIVE.md`,
`FEEDBACK.md`) is edited by hand today, through anchored python edits, and its
numbering drifts: the live file's items run 232, 231, 230, 229, 228, 227,
**223, 224, 225, 226**, 222, an increasing run inside a decreasing one, each
the trace of an insert anchored to the wrong neighbour. FEEDBACK.md is 1,322
lines with nothing to archive it but care. Steve: "you should be able to
manipulate that easily with shale as well as archiving the old items. A very
common pitfall for Claude is that numbering gets out of whack."

- **Its grammar, written down** (in metal-vmm's README and checked by the
  tool): sections are `## ` lines; an item is the text from a line beginning
  `**N. ` to the next item or section; **numbers are unique across QUEUE.md and
  QUEUE-ARCHIVE.md together** (an archived number is never reused); **within a
  section, items are newest first**; an item's status (`DONE`, `CC'S`, `THE
  BOX'S`) is in its head. FEEDBACK.md: entries are `## ` lines, newest first,
  each `<who> → <who>, <date>: <title>`.
- **The tool is metal-vmm's own prelude** (`.shale/prelude.shale`, tracked),
  so any Shale run in that checkout has it:
  - `queue_check()` → each violation with its line (a number used twice, a
    number in both files, a section out of order);
  - `queue_next()` → one more than the highest number in either file;
  - `queue_add(section, title, body)` → the number it gave, the item inserted
    at the top of its section;
  - `queue_done(n, outcome)`, `queue_archive({n, ...})` (each to one line in
    the archive: number, title, outcome, the commits its text names; both
    files or neither, by `edits_all`);
  - `feedback_add(from, to, title, body)`, newest first;
    `feedback_archive({before = date})`.
- **Every changing call checks first, and refuses a file that is out of
  order** rather than guess where to insert; `queue_reorder()` puts it in
  order, its own call, its diff shown. The live file's 223-226 run is the
  first thing it fixes.
- **Its tests are Shale too** (`.shale/queue_test.shale`, on fixtures in
  `tests/queue/`, run by `shale --write`): `queue_check` names exactly a
  planted misorder; `queue_add` puts the next number at the top of "CC: open";
  a number in the archive is never given again; an archive moves both files or
  neither. Shale testing Shale, with nothing else.

## The order of work

0. **The experiment: done** (see "Running a program": a timed-out call is
   backgrounded, not killed; a stop is TERM then KILL to the whole tree; curl
   8.5.0).
1. **The core** (CC's, metal-vmm QUEUE 232, under way): split
   builtins_store.zig; long strings and block comments, fuzzed first; `edit`'s
   list form, capped; `last`; `fail`; regex `|`, `\b`, `nocase` and the cache
   key; `report` frozen; SHALE.md's contradictions; the whole image measured.
2. **The seam and `run`:** `host` and `Options.host`, `Options.path_hook`,
   the prelude list; the raw spawn and poll loop, the pure keep, the filters,
   `whole`, `log`, `env`, `secrets` and their scrubbing, the refusals; mounts
   and `real` behind the hook; the CLI's defaults; the dry run's stop; the
   script from stdin.
3. **The Linux prelude:** the wrappers (`run`, `real`, `job_*`), the text
   helpers, `must`, `create`, `edits_all`, `newest`, `glob`'s `hidden`; the
   repo prelude and the user prelude, and their pins.
4. **The git prelude.**
5. **Jobs:** `job_start` with its reaper, the `.job` record, `job_alive`,
   `job_stop`, `job_wait`.
6. **`shale-gate` and the hook.**
7. **The queue tool** (metal-vmm's `.shale/prelude.shale`) and its Shale tests;
   then the live queue reordered by it.
8. **The docs:** SHALE.md (the seam, mounts, `run`, jobs, git, the CLI's
   defaults) and SHALE-AGENTS.md (its first page and its "where Shale is
   worse"), rewritten for what was built.
9. Later, on a need: `input()`, `http_get`, `job_of`, separate stderr, a
   per-session scratch mount.

**The tests the design names:** the keep against the prelude's
`take` and `last` over `re_lines(...)` as an oracle (empty, no final newline, CRLF, NUL,
long lines, fewer lines than `head + tail`); the dry run (edit then run: no
file changed, no call, `budget runs`, not caught by `attempt`); secrets never
in `out`, `log`, effects or a stop, against a child that echoes them and `curl
-v`; `edit`'s list form (in sequence, a failing third edit leaves the file
byte-identical); metal with a null host (every host builtin stops with `host`
on both engines; mounts refused under `.fat`; the size difference recorded);
long strings at levels 1-3 with `]]` inside; a `shale` killed with TERM
leaving no child; a job found again by its `.job` path from a second `shale`,
its exit code read after it ended; an untracked script refused by path.

**Its own repo** earns its keep after (2), once the seam exists.

## Rounds

**Round 1** (a cold reviewer with the session's 6,609 commands): the families
and counts; the host table; `run` first; the edit gaps; git over `run`; the
fallback rule.

**Round 2** (the five commonest workflows written in proposed Shale): a dry
run never runs a program; output bounded by lines from both ends, and a
`log`; mounts; alternation; git in the Linux host's prelude; long strings
specified; verified PIDs; the CLI's clock.

**Round 3** (feasibility in zig 0.16, ten more workflows, enforcement):
filter before keep; `whole` for git; `env` on `run` and `secrets` that never
become values; a raw spawn and poll loop; the experiment first; `run` refuses
shells and text tools; the PreToolUse hook, fail-closed; mounts specified; the
staged overlay cut.

**Round 4** (coherence and size): coherent names (`re_`, `_lines`, `job_*`,
`stdin`, `whole`); thin helpers to the Linux prelude, measured; `take` with a
negative count; `edit`'s list form; the dry run as `runs = 0`; `ended`;
`must`; secrets scrubbed; home as a mount; `.checkout`; no streaming past the
call cap; Claude's commit policy to a user prelude; metal's cost estimated.

**Round 5** (80 real consecutive calls replayed under the ban: 1 escape, 11
awkward; and what a builder would have to guess): a job found again by its
`.job` path, and a reaper for its exit code (no `secrets` on jobs); the git
prelude with ranges, fields, `stat`, `pull`, `--all`, and `repo` as a Shale
path (`""` the root); `nocase`, `\b`, `not_re`, context and a matched count;
`newest` and `glob`'s `hidden`; an untracked script refused by path, and
wrappers and versioned names refused; `stdin` takes a whole result, not a
guess at text; `argv` in the result; a keep required, Claude's defaults in
its user prelude; the hook user-wide; a docs chunk; and about sixty details
settled (the marker, `code` on a timeout, the grace and the drain, the mounts
file's grammar, a log's truncation, the prelude's shadowing, `now()`'s unit,
block comments).

**Round 6** (an adversary loyal to metal alone; Steve: "You will mostly veto
their pushback (because I want the extra linux features) but listen to their
pushback"). Its count: the round-5 design was 600-800 core lines and a policy
in `store.zig`, not the 390 claimed. **Accepted, because they cost Linux no
feature:** one `host(name, ...)` builtin and Linux-prelude wrappers in place
of six builtins; mounts, `real` and the names policy behind a path hook, with
`.checkout` cut (no tracked file needs it), so metal's `pathArg` is
byte-identical and no root escape enters the serving kernel; the dry run as
the existing `Mode.dry_run`, no `runs` budget in the core; `last` in place of
a negative `take`; the regex cache keyed by `nocase`; `edit`'s list form
capped and charged; the lexer fuzzed before long strings land, and its old
cases pinned; `fail` named by the parser's refusal of `error`, and the route's
readers listed; `report` frozen, the CLI's terseness in `script_runner.zig`;
`log` the host's file, not a new path into the core's effects; the whole
image measured. **Vetoed, with reasons:** dropping the runtime preludes (the
queue tool needs a repo's prelude; metal's list is core alone, so metal pays
nothing); cutting the long string's "closer it met" hint (the likeliest
mistake in editing Zig, about 15 lines); moving `glob` out of the core prelude
(harmless lazy text); the gate's added burden for a fake host (the price of
testing the host at all).
