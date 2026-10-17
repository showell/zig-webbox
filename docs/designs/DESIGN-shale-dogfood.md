# Design: Shale, dogfooded (Claude without bash or Python)

**Status: round 4 of 5, then a sixth by a metal-only adversary** (the box and
cold reviewers, 2026-10-18). No code. Steve: five rounds, then a sixth "who
only cares about the metal use case" to attack anything on the Linux side that
seems crufty, whose pushback is mostly vetoed but heard; the final design on
the essay surface (with mounts explained in detail); then CC builds it.

## The thought experiment

Steve, 2026-10-18: ban Claude from running bash and Python, which forces us to
dogfood Shale. Fall back to bash or Python only where Shale cannot do the job
yet, and then **either queue the missing feature or justify why it is out of
Shale's scope**. A litmus test: "if we're reaching for Python, then why not do
it in zig?" **The Linux version can be a superset**, but Shale on metal stays
minimal, **without a bunch of comptime hacks**. Pipe-like behaviour is likely
the best way to make it versatile; git and real stdin are the named gaps. A
repo of its own may come later. Bootstrap: `shale` on bash's search path.

## Two rules above the rest

**1. Shale does text itself.** Shale runs another program only to get what that
program alone can give (git's view of a repository, a compiler's verdict, a
server's answer, a disk image's files). What is then done with the text is
Shale's: filtering, slicing, matching, counting, sorting, editing. Never
`run{"head", ...}`; `run` refuses it. (Steve: "the idea is to have shale do
those natively and not shell out to unix head/tail".)

**2. Zig for bytes and the world, Shale for thin policy.** (Steve leans to Zig
builtins.) A builtin when it does real work on bytes in bulk or touches the
outside (regex, the edit transaction, long strings, `run`, jobs), because a
bulk builtin costs a step per 16 bytes where a Shale loop pays per operation.
Prelude Shale only for a thin layer whose cost is in the builtins it calls,
measured (round 4): `re_lines` over 16 KiB of output spends about 164k steps in
the regex and about 3k in its loop, 2%. Prelude code is checked by the gate
for free (both engines run it; a builtin is one implementation), is charged
honestly with no charge table, is read when it stops, and the Linux host's
prelude never reaches metal.

## The evidence: what Claude actually ran

One long session on this box: **6,609 Bash calls** (median 259 characters,
p90 1,870). By family (rough):

| family | about | Shale today |
|---|---|---|
| A. file edits: python heredocs asserting a multi-line `old` occurs once, replacing, writing (1,484 of 1,680 `python3` calls), 345 `sed -i`, 208 `cat >` | 2,000 | partly |
| B. filtering a program's output: `2>&1 \| grep \| head`, `\| tail`, `${PIPESTATUS[0]}` (211); about 2,540 greps with alternation | 2,800 | no |
| C. builds and tests: `zig build` (1,391), repo scripts, `timeout`, `VAR=value` prefixes (165 `TRANSPORT=`) | 1,400 | no |
| D. git: commit 924 (`-qam` 340, `add -A` 326), log 803, push 768, status 627, diff, show, worktree, merge, fetch | 1,900 | no |
| E. reading code: `grep -rn`, `sed -n`, `cat` | 2,600 | Claude Code's Read and Grep tools |
| F. long jobs: `setsid nohup` (204), waiting on a file or a PID (`until` 371), `kill` (130), `pgrep` (97) | 1,000 | no |
| G. HTTP: `curl`, 51 with a bearer key read from a file | 160 | no |
| H. disk images: mtools | 50 | no |
| K. QEMU, sudo, ssh | 450 | out of scope |

**What Claude wanted back from a program:** by lines, from both ends, long
lines cut, **after a filter**: `head -N` mostly 3-40, `tail -N` 1-5, `cut
-c1-200` about 400 times. About 2-4 KiB.

## The architecture: one core, a host's table

- **The core is unchanged and identical on both hosts:** the lexer, the
  parser, both engines (`gate_test.zig` holds them identical), the budgets,
  the store, text, regex, lists.
- **What reaches outside is a host's table, at runtime.** Five builtins
  (`run`, `real`, `job_start`, `job_alive`, `job_stop`, `job_wait`) join the
  closed builtin enum, so its completeness check stays; each forwards its raw
  arguments to `Options.host: ?*const Host`, function pointers the host
  supplies (as webbox's `host_facts` and `host_fetch` are), **so all of
  `run`'s option parsing lives in the host, none on metal.** Metal passes
  null: each stops with class `host` ("`run`: not on this host"). No comptime
  switch.
- **Preludes, layered:** the core prelude (both hosts); the Linux host's
  prelude, handed in as text and indexed at runtime by the same lazy loader
  (`git_*`, `must`, `create`, `edits_all`, `re_lines`, `head_lines`,
  `tail_lines`, `unique`): metal's image carries none of it; and **a user's
  prelude**, `~/.config/shale/prelude.shale` if present, for one user's own
  policy (Claude's commit wrapper that insists on the `Co-Authored-By` line
  lives there, not in a general git layer).
- **The Linux table lives outside `src/script/`**, split at the 1000-line rule
  (`src/shale_spawn.zig`, the raw fork, exec and poll loop; `src/shale_keep.zig`,
  pure; `src/shale_host_linux.zig`, the table, mounts, jobs). `portable_test.zig`
  already refuses `std.process` and `std.os` in `src/script/`.
- **The gate:** a test-only `FakeHost` that fakes **only the spawn** (bytes
  in, bytes out, recorded): option parsing, the filter, the keep and the
  charging are the real code in both engines, or the gate tests the fake.
  Mounts in a gated test lie inside the root copy, remapped per engine. Not in
  the gate: real children, wall time, signals, `/proc`.
- **Names, an explicit runtime policy:** `.fat` (the site's data, the
  route's; metal's only, pinned, no default that could flip) or `.checkout`
  (refuse only `""`, `.`, `..`, NUL and `/` within a part; exact case; no path
  measuring), which the CLI sets.
- **Mount resolution is core** (a runtime table in `Options`, empty on metal,
  where FAT names already refuse `:`); only `real()` and the mounts file are
  the host's. Home is a mount, not a second syntax: no `~/` in Shale paths.
- **The new budget `runs`** appears in `budget()` only on a host that runs
  programs (on metal `room_for({runs = 1})` is an `index` stop: said so).

## Mounts

One root is not enough. Claude's logs and job folders live outside every repo
(a per-session scratchpad, `~/runs`, `~/build`), its memory too, and a log
inside a repo is untracked clutter. So **a path may begin with a mount's
name**: `runs:gates/summary`, `memory:MEMORY.md`, `repos:dog-park/README.md`,
`home:.gopher_api_key`.

- **Where they are named:** `~/.config/shale/mounts`, a line each (`home =
  ~`, `runs = ~/runs`, `repos = ~/showell_repos`, `memory = ~/.claude/...`).
  No flag on a command (Steve dislikes CLI arguments); the root is the working
  directory, as now. A missing file is no mounts; a malformed line stops the
  run; an unknown mount stops, naming the known ones. Tests pin
  `SHALE_MOUNTS=<file>`. (Values naming a variable, for the per-session
  scratchpad, wait for a need: v1 uses `runs`.)
- **What a mount path may be:** within the mount, as a root's path is within
  the root: no `..`, no absolute paths. `runs:` alone is the mount's top. A
  first part with `:` in it is always a mount's name.
- **Naming, not a sandbox.** Confinement is lexical: a symlink inside a mount
  leads where it leads, and `run` reaches anywhere anyway. Mounts make paths
  short and stable, not safe.
- **In logs:** paths print as the script wrote them, never expanded.
- **Into a program:** a child takes real OS paths. `run`'s path options
  (`cwd`, `log`, `secrets`' files) take Shale paths and the host resolves
  them; **argv is passed verbatim**, because mount-shaped strings must pass
  untouched (`master:src/x.zig`, `::gopher-metal.conf`, `boot.img@@1048576`,
  URLs). **`real(p)`** gives a Shale path's absolute OS path for argv; logs
  show it by its mount again.

## Running a program: `run`

    run(argv, {timeout_ms = 600000, re = "error|FAIL", invert = false,
               head = 20, tail = 5, width = 200, whole = N,
               log = "runs:x/test.log", cwd = "x", stdin = s,
               env = {TRANSPORT = "pci"}, secrets = {K = "home:.gopher_api_key"},
               want = "tag: text"})
      → {code, ended, out, ms, total_lines, kept_lines}

- **`timeout_ms` is required.** A default is a decision nobody made.
- **`ended`** is `"exit"`, `"timeout"` or `"signal"`: one field, no
  booleans.
- **Filter, then keep.** `re`, Shale's own regex, runs on each line as it
  streams (`invert` keeps the lines that do not match); then **`head` and
  `tail` keep lines from both ends**, each cut at `width`. `out` is those
  lines, with a marker where lines were left out (`… 1,234 lines …`).
- **`whole = N`** keeps everything up to N bytes, never cut, an `argument`
  stop past it: what the git prelude uses. **Output piped onward**
  (`stdin = a.out`) must come from `whole`, never a kept `out` with its
  marker: refused otherwise.
- **stdout and stderr are one stream**, as `2>&1` (separate streams wait for
  a need). `log` keeps it whole as it streams, written through the store's
  `append`, so it is an effect like any write.
- **`env` adds to the inherited environment** (`ZIG_PROGRESS` removed). There
  is no `env` builtin: a script cannot read the environment.
- **`secrets` never become values, and never come back:** the host reads each
  file (trimmed) into the child's environment, logs print `K=<secret
  home:.gopher_api_key>`, and **the host scrubs the secret's bytes from
  everything the child prints** (`out`, `log`), since a child may echo its
  environment or `curl -v` its headers.
- **`must(r)`** (prelude) prints `r.out` and fails when `r.code` is not 0:
  the `&&` of a shell chain.
- **`fail(msg)`** ends a run with class `fail`; `attempt` catches it.
- **`run` refuses**, class `refused`, shells, interpreters and rule one's
  text tools as argv[0] (`bash`, `sh`, `python3`, `node`, `head`, `tail`,
  `grep`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `cat`, `tr`, `env`,
  `xargs`, `timeout`), naming `want`: with `{want = "tag: text"}` it runs and
  is logged as a want. Habits, not adversaries; a repo's script, run by path,
  is allowed.

**How it is built** (round 3, from zig 0.16's std): std's `process.spawn` has
no hook before exec, so no death signal and no `setsid`; its `Child.kill`
signals the PID alone and then waits without bound. So **one raw spawn**
(`linux.fork`, `prctl(PR_SET_PDEATHSIG)` and a `getppid` check, `setpgid` or
`setsid`, signals unblocked in the child, `dup2`, `chdir`, `execve` with
std's PATH loop copied), and **one poll loop** over the output pipe, a
non-blocking stdin writer, a `pidfd` for the exit, a `signalfd` for TERM and
HUP, and the deadline. On a timeout or a signal: TERM to the group, a grace,
KILL; after the leader exits, drain briefly and stop reading. **The keep is a
pure file:** the first N lines, a ring of the last M, each cut at `width`, a
count: memory bounded by `(N+M)·width`. About 900 lines and 500 of tests.

**What it cannot promise:** a death signal reaches only the direct child; a
child that makes its own session escapes the group kill. So "a run never
outlives its tool call" rests on `shale` relaying the signal it gets, and
**first, a one-minute experiment: how Claude Code ends a Bash call past its
timeout.**

## Text

- **Core builtins:** `take(l, n)` gains a negative `n`, the last `|n|` (as
  `sub` counts negatives; an `argument` error today, so nothing breaks).
  **Regular expressions gain alternation** (`|`), linear in Thompson's way;
  still one capture group, no backreferences.
- **The Linux prelude:** `re_lines(s, pattern[, {invert}])` → `{{line,
  text}}`; `head_lines(p, n)` and `tail_lines(p, n)` → lists, over
  `read_lines` and `read(p, size - k, k)` (a tail of a log costs a few hundred
  steps); `unique(list)` (strings); `grep_all(p, lit)` in parts, beside
  `count_all`.
- **Naming, kept coherent** (round 4): a literal by default, `re_` where the
  pattern is a regex; `_lines` and `_in` keep meaning "of a file"; the subject
  first, the options map last.
- **No streaming past the call-bytes cap:** a builtin is bounded, never cut
  (on metal, one call over a 190 MB site holds the turn for most of a second).
  The CLI raises `call_bytes` instead (64 MiB).

## Edits that work

The python pattern: several exact replacements to one file in memory, each
asserted, one write, every literal multi-line.

- **Long strings, Lua's, specified exactly:** `[==[ ... ]==]`; **a level is
  required** (level 0, `[[`, is refused: code being edited is full of `]]`);
  the level must match; the first newline right after the opener is dropped;
  bytes are raw (no escapes, no `\r\n` folding); a newline before the closer
  is part of the string. A syntax error right after a long string hints the
  closer it met. Line and column advance through it.
- **`edit(p, {{old = ..., new = ...[, all = true][, word = true]}, ...})`**:
  `edit`'s second form (arity overloading, as `read` and `sort` have), its own
  option names. **The edits apply in sequence**, each to the result of the
  one before; each asserted (once, unless `all`); one diff; one write; a
  failing edit writes nothing and prints no partial diff. (builtins_store.zig
  is split first: it is at 931 lines.)
- **`edits_all({{p, {...}}, ...})`** (Linux prelude): checks every file's
  edits first, writes nothing unless all hold, then file by file, each atomic;
  the set is not (said so).
- **`create(p, text)`** (Linux prelude): refused if the file exists.
- `replace` keeps its behaviour (printing a diff would spend site scripts'
  output budget on metal). The CLI's output default is 64 KiB, which covers
  an edit's diff.

## The dry run, honest

A program escapes the root and any dry run (`zig build` writes into the tree;
`git status` rewrites the index). So **a dry run is a run whose `runs` budget
is 0**: it checks and prints every edit's diff against the disk as it is, and
the first `run` or `job_start` stops it as `budget runs` ("a dry run runs no
program; --write runs it"). A budget stop is one `attempt` cannot catch, which
is exactly what a dry run needs. **`--write` runs everything.** The dry run is
a preview, not the everyday safety: Claude will pass `--write` on nearly every
call that runs a program, and the design says so.

## Git, in the Linux host's prelude, over `run`

No native reading of `.git`; every call uses `run`'s `whole`, and takes a
repo (a path, or `real("repos:x")`), as `git -C`.

- Reading: `git_status(repo)` → `{{code, path}}` (`--porcelain=v1 -z`),
  `git_log(repo, n)` → `{{hash, subject}}`, `git_diff`, `git_show(repo,
  "HEAD:path")`, `git_ls_files(repo)`, `git_is_clean(repo)`.
- Changing: `git_commit(repo, msg, {add = "tracked" | "all" | {paths}})`
  (`-a`, the `-qam` habit; `add -A`; named paths; none for a merge commit),
  the message by `-F -`. `git_push`, `git_fetch`, `git_merge_ff`,
  `git_worktree_add`, `git_worktree_remove`, `git_branch_delete`.
- **Claude's commit** is the user prelude's `commit(repo, msg, opts)`, which
  refuses a message without a `Co-Authored-By:` line and calls `git_commit`.

## Long jobs

- `job_start(argv, {log, cwd, env, secrets})` → `{pid, pgid, started}`: its
  own session, no terminal, no death signal (it outlives `shale` by design);
  it writes `<log>.job`, so a later call finds it by that path.
- `job_alive(job)`: `kill(-pgid, 0)`, after `/proc/<pid>/stat`'s start time
  (parsed from its last `)`, compared raw) matches. A job whose leader exited
  but whose group lives is alive.
- `job_stop(job)`: TERM to the group, a grace, KILL, after the start time
  matches. (A group signal is `kill(-pgid)`; a pidfd signals one process, so
  the check narrows the reuse race, it does not close it: said so.)
- `job_wait(job, {timeout_ms, file, contains})` → `{ended = "found" |
  "exited" | "timeout"}`; `timeout_ms` required, and under the Bash call's own
  `timeout` (120 s unless raised, at most 600).
- `job_of(pid)`, adopting a job a repo script detached itself, waits for a
  need.

## Stdin

Steve named real stdin as a gap. **With no FILE and no `-e`, the script is
stdin** (`shale <<'SHALE' ... SHALE`, the launch convention: `EOF` lines occur
in files Claude edits); a stdin script reports itself as `stdin`. **Data on
stdin** (`input()`, with a FILE or `-e`) is last in the order: a pipe into
Shale loses the producer's exit code, which `run` keeps.

## Error classes

Two new: **`host`** (a call not on this host; a spawn that fails: its
program not found) and **`fail`** (`fail(msg)`, `must`; catchable). A dry run
is a `budget runs` stop, a refused program is `refused`, a `whole` past its
bound is `argument`, a timeout is a result (`ended`). Every stop stays one
line and its trail: `fail: \`zig build test\` exited 1`, `host: \`run\`: not
on this host`, `budget runs: a dry run runs no program; --write runs it`,
`refused: \`run\` of \`sed\`: Shale edits text itself; {want = ...} to run it
anyway`.

## The CLI's defaults

`now()` is the wall clock (`SHALE_NOW` pins it for tests). Output 64 KiB.
`call_bytes` 64 MiB. Steps 5M. **Terse:** the `── used:` line only past half
a budget or on a stop; the effects list on `--verbose`.

## Making the ban real

Remembered rules fail; this one is enforced.

- **A PreToolUse hook on Bash and Monitor** runs `shale-gate`, a zig tool in
  zig-webbox's `tools/` (a pure classifier, tested), behind a wrapper that
  turns every failure into a refusal (exit 2), so a missing binary refuses
  rather than passes. It passes exactly:
  - **the launch:** optionally `cd WORD && `, then `shale` and its words
    (`--write`, `--verbose`, `--budget N=V`, a FILE, `NAME=VALUE`), each word
    plain (no quotes, `$`, backticks, `;|&<>()*?`), and optionally `<<'TAG'`
    ending line 1, a body, and a last line exactly `TAG`, which occurs once;
  - **the escape:** a first line `# want: <tag>: <text>` or `# out-of-scope:
    <tag>: <text>`, which it lets run and logs (date, session, kind, tag,
    text, the command's start) to `~/.local/state/shale/wants.tsv`, outside
    every repo.
- **Claude curates** that log into zig-webbox's `docs/SHALE-WANTS.md`; a tag
  seen three times goes to the queue.
- **Read, Grep, Edit and Write stay allowed**: the ban is on bash and Python,
  and Edit is better than a python heredoc for one replacement. (Steve's to
  confirm.)
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
> by being run more than once; Python only as a throwaway oracle.

**What stays bash, through the escape:** QEMU and KVM gates (detachment,
sudo, mounts), `sudo`, interactive programs, ssh to prod. Copying and moving
binary files is `run` (`cp`, `mv`), not new store builtins.

## What metal's image gains (round 4's estimates)

| item | Zig lines | on metal |
|---|---|---|
| the host enum entries and stubs, `Options.host` | about 60 | a stub a name; all option parsing is the host's |
| 2 error classes, the `runs` budget | about 30 | nil |
| long strings | about 40 (the lexer already detects them to refuse them) | marginal |
| `edit`'s list form | about 80 | low: Dog Park's runs are background, which refuses edits |
| regex `\|` | about 80 | **useful** (`error\|panic` in a scan) |
| `take`'s negative count | about 10 | useful |
| mounts and the names policy | about 40 | none: an empty table, `.fat` byte-identical |
| everything else (git, text helpers, `create`, `edits_all`, `must`) | 0: the Linux prelude | none |

**About 340 lines, a few KiB, measured as a number in a test** (the
freestanding script module's size before and after).

## The order of work (for CC, after round 6)

0. **The experiment:** how Claude Code ends a timed-out Bash call (the box's,
   one minute). Verify the box's curl is 8.3 or later for `--variable`.
1. Edits: long strings, `edit`'s list form (after splitting
   builtins_store.zig), `take`'s negative count, `fail`, the script from
   stdin.
2. The host table and `run`: the raw spawn and poll loop, the pure keep,
   `re`/`invert`, `whole`, `log`, `env`, `secrets` and their scrubbing, the
   refusals; mounts and `real`; the `.checkout` policy; the CLI's defaults; the
   dry run as `runs = 0`.
3. Regex `|`; the Linux prelude's text helpers.
4. The git prelude; `must`; `create`; `edits_all`; the user prelude and
   Claude's `commit`.
5. Jobs: `job_start`, `job_alive`, `job_stop`, `job_wait`.
6. `shale-gate` and the hook.
7. Later, on a need: `input()`, `http_get`, `job_of`, separate stderr, a
   per-session scratch mount.

**The tests the design names** (round 4): the keep against the prelude's
`take(re_lines(...), ±n)` as an oracle (empty, no final newline, CRLF, NUL,
long lines, fewer lines than `head + tail`); the dry run (edit then run: no
file changed, no call, `budget runs`, not caught by `attempt`); secrets never
in `out`, `log`, effects or a stop, against a child that echoes them and `curl
-v`; `edit`'s list form (in sequence, a failing third edit leaves the file
byte-identical); metal with a null host (every host builtin stops with `host`
on both engines; mounts refused under `.fat`; the size difference recorded);
long strings at levels 1-3 with `]]` inside; a `shale` killed with TERM
leaving no child.

**Its own repo** earns its keep after (2), once the host seam exists.

## Rounds

**Round 1** (a cold reviewer with the session's 6,609 commands): the families
and counts; the host table; `run` first; the edit gaps; git over `run`; the
fallback rule.

**Round 2** (the five commonest workflows written in proposed Shale): the
reading-verb allowlist unsound, so a dry run never runs a program; output
bounded by lines from both ends, and a `log`; mounts; alternation; git in the
Linux host's prelude; long strings specified; verified PIDs; the CLI's clock.

**Round 3** (feasibility in zig 0.16, ten more workflows, enforcement):
filter before keep; `whole` for git; `env` on `run` (additive) and `secrets`
that never become values; a raw spawn and poll loop; the experiment first;
`run` refuses shells and text tools; the PreToolUse hook, fail-closed; mounts
specified, argv verbatim, `real()`, "naming, not a sandbox"; the staged
overlay cut.

**Round 4** (coherence and size): the names made coherent (`re_` for regex,
`_lines`/`_in` for files, `job_*`, `stdin`, `whole`, `git_is_clean`); thin
text helpers to the Linux prelude, measured; `take` with a negative count in
place of `head`/`tail`; `edit`'s list form in place of `edits`; the dry run as
a `runs` budget of 0, so `attempt` cannot catch it; `ended` in place of
booleans; `must` in place of `check`; secrets scrubbed from a child's output;
home as a mount, `.checkout` for `.posix`; `kill(-pgid, 0)` for the `/proc`
scan; no streaming past the call cap; `replace` unchanged on metal; Claude's
commit policy to a user prelude; metal's cost measured, about 340 lines.
