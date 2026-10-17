# Design: Shale, dogfooded (Claude without bash or Python)

**Status: round 3 of 5, then a sixth by a metal-only adversary** (the box and
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

## One rule above the rest: Shale does text itself

**Shale runs another program only to get what that program alone can give**
(git's view of a repository, a compiler's verdict, a server's answer, a disk
image's files). **What is then done with the text is Shale's**: filtering,
slicing, matching, counting, sorting, editing. Never `run{"head", ...}`, never
`run{"sed", ...}`: `run` refuses them (below). So the text work is budgeted,
deterministic, held identical by the two engines' gate, and the same on metal.
(Steve: "the idea is to have shale do those natively and not shell out to
unix head/tail".)

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
  the store, text, regex, lists, and the text builtins below.
- **What reaches outside is a host's table, at runtime.** A few builtins
  (`run`, `real`, `start`, `alive`, `stop`, `wait_for`, `job_of`, `input`)
  join the closed builtin enum, so its completeness check stays; each forwards
  to `Options.host: ?*const Host`, function pointers the host supplies (as
  webbox's `host_facts` and `host_fetch` are supplied by each host). **Metal
  passes null**: each stops with a new class `host` ("`run`: not on this
  host"). No comptime switch.
- **The Linux host's prelude is the host's too:** the git layer, `must`,
  `http_get`, handed in as extra prelude text and indexed at runtime by the
  same lazy loader. Metal's image carries none of it.
- **The Linux table lives outside `src/script/`**, split at the 1000-line rule
  (`src/shale_spawn.zig`, the raw fork, exec and poll loop; `src/shale_keep.zig`,
  pure; `src/shale_host_linux.zig`, the table, mounts, jobs). `src/script/`
  never imports `std.process` or `std.os.linux`, and a test greps that.
- **The gate:** a test-only `FakeHost` (argv to `{code, out, err, ms}`,
  recording every call), a fresh copy for each engine; the gate compares call
  logs as it compares effects. Steps are charged on bytes, never on
  milliseconds; wall time stays out of the gate. Real processes are tested
  apart, against a small fixture program the build makes.
- **Names, an explicit runtime policy:** `.fat` (the site's data, the
  route's; metal's only, pinned, no default that could flip) or `.posix` (a
  checkout: refuse only `""`, `.`, `..`, NUL and `/` within a part; exact
  case; no path measuring; `~/` allowed), which the CLI sets.
- **Mount resolution is core** (a runtime table in `Options`, empty on
  metal); only `real()` and what reads the mounts file are the host's.
- **Budgets only a host with programs has** (`runs`, `run_ms`) appear in
  `budget()` only there.

## Mounts

One root is not enough. Claude's logs and job folders live outside every repo
(a per-session scratchpad, `~/runs`, `~/build`), its memory too, and a log
inside a repo is untracked clutter. So **a path may begin with a mount's
name**: `scratch:gates/summary`, `memory:MEMORY.md`, `repos:dog-park/README.md`.

- **Where the mounts are named:** `~/.config/shale/mounts`, a line each
  (`scratch = $SHALE_SCRATCH`, `runs = ~/runs`, `repos = ~/showell_repos`).
  Values may name an environment variable: the scratchpad is per session, so
  a Claude Code SessionStart hook sets `SHALE_SCRATCH` (from the session's id,
  by the observed `/tmp/claude-<uid>/<project>/<session>/scratchpad`, to be
  verified). No flag on a command (Steve dislikes CLI arguments); the root is
  the working directory, as now. A missing file is no mounts; a malformed line
  stops the run; an unknown mount stops, naming the known ones. Tests pin
  `SHALE_MOUNTS=<file>`, never the user's.
- **What a mount path may be:** within the mount, as a root's path is within
  the root: no `..`, no absolute paths. `scratch:` alone is the mount's top.
  A first part with `:` in it is always a mount's name, so a root file named
  `a:b` cannot be named. `~/x` is allowed under `.posix` (as it is in argv).
- **Naming, not a sandbox.** Confinement is lexical: a symlink inside a mount
  leads where it leads, and `run` reaches anywhere anyway. Mounts make paths
  short and stable, not safe.
- **In logs:** paths print as the script wrote them (`scratch:gates/summary`),
  never expanded: short, and the same across sessions.
- **Into a program:** a child takes real OS paths. `run`'s path options
  (`cwd`, `log`, `err_log`, `secrets`' files) take Shale paths and the host
  resolves them; **argv is passed verbatim** (except a leading `~/`), because
  mount-shaped strings must pass untouched (`master:src/x.zig`,
  `::gopher-metal.conf`, `boot.img@@1048576`, URLs). **`real(p)`** gives a
  Shale path's absolute OS path for argv. Logs show a `real()` path by its
  mount again.

## Running a program: `run`

    run(argv, {timeout_ms = 600000, grep = "error|FAIL", head = 20, tail = 5,
               width = 200, log = "scratch:test.log", cwd = "x", input = s,
               merge = true, env = {TRANSPORT = "pci"},
               secrets = {GOPHER_KEY = "~/.gopher_api_key"}, check = true})
      → {code, out, err, ms, timed_out, total_lines, kept_lines, cut}

- **`timeout_ms` is required.** A default is a decision nobody made.
- **Filter, then keep** (round 3: keeping first loses the middle of any
  output over 25 lines, family B's whole point). `grep`, Shale's own regex,
  runs on each line as it streams; then **`head` and `tail` keep lines from
  both ends**, each cut at `width`. `out` is those lines as one string, with a
  marker where lines were left out (`… 1,234 lines …`); `cut` says so.
- **`{all = N}` keeps everything up to N bytes and stops past it**, never
  cutting: what the git prelude uses (a diff, a show, `status -z`), which
  line bounds would destroy.
- **`log` keeps the whole output** in a file as it streams (an error writing
  it stops the run); with `merge = false`, `log` is stdout and `err_log`
  stderr. Merge is one pipe for both, byte-interleaved as `2>&1` is.
- **`env` adds to the inherited environment** (`ZIG_PROGRESS` is always
  removed). There is no `env` builtin: a script cannot read the environment.
- **`secrets` never become values.** The host reads each file (trimmed)
  straight into the child's environment; logs print `GOPHER_KEY=<secret
  ~/.gopher_api_key>`. The prelude's `http_get(url, {bearer = "~/.key"})`
  uses curl's `--variable %K --expand-header "Authorization: Bearer {{K}}"`,
  so no argv carries the key either.
- **`check = true`** makes a nonzero exit a `fail` stop, the `&&` of a shell
  chain; the prelude's `must(r)` does the same after the fact.
- **`fail(msg)`** ends a run with class `fail` and exit 1.
- **`run` refuses** shells, interpreters and rule one's text tools as
  argv[0] (`bash`, `sh`, `python3`, `node`, `head`, `tail`, `grep`, `sed`,
  `awk`, `cut`, `sort`, `uniq`, `wc`, `cat`, `tr`, `env`, `xargs`, `timeout`)
  unless the call carries `{want = "tag: text"}`, logged as a want (below).
  That catches habits, not adversaries; a repo's own script, run by path,
  stays allowed.
- **Pipelines** pass through the script: `run(b, {input = a.out})`.

**How it is built** (round 3, from zig 0.16's std): std's `process.spawn` has
no hook before exec, so no death signal and no `setsid`; its `Child.kill`
signals the PID alone and then waits without bound. So **one raw spawn**
(`linux.fork`, `prctl(PR_SET_PDEATHSIG)` and a `getppid` check, `setpgid` or
`setsid`, signals unblocked in the child, `dup2`, `chdir`, `execve` with
std's PATH loop copied), and **one poll loop** over the output pipe, a
non-blocking stdin writer (a child that writes before reading would otherwise
wedge both), a `pidfd` for the exit, a `signalfd` for TERM and HUP, and the
deadline. On a timeout or a signal: TERM to the group, a grace, KILL; after
the leader exits, drain briefly and stop reading (a grandchild may hold the
pipe). **The keep is a pure file:** the first N lines, a ring of the last M,
each cut at `width`, a count: memory bounded by `(N+M)·width`, whatever the
output's size. About 950 lines and 500 of tests.

**What it cannot promise:** a death signal reaches only the direct child, and
a child that makes its own session escapes the group kill. So "a run never
outlives its tool call" rests on `shale` relaying the signal it gets, and
**first, a one-minute experiment: how Claude Code ends a Bash call past its
timeout** (TERM or KILL, the group or the tree).

## Text, natively

For `run`'s output, a log, or any string: `lines(s)`, `head(s, n)`, `tail(s,
n)`, `grep_in(s, pattern)` → `{line, text}` (`{invert = true}`, `{after =
n, before = n}`), `unique(list)`, `concat(a, b)`. On files of any size:
`grep` and `count_in` stream past the call-bytes cap (charged in read
bytes), and `head_lines(p, n)` and `tail_lines(p, n)` seek. **Regular
expressions gain alternation** (`|`), linear in Thompson's way; still one
capture group, no backreferences.

## Edits that work

The python pattern: several exact replacements to one file in memory, each
asserted to occur exactly once, one write, every literal multi-line.

- **Long strings, Lua's, specified exactly:** `[==[ ... ]==]`; the level must
  match; the first newline right after the opener is dropped; bytes are raw
  (no escapes, no `\r\n` folding); a newline before the closer is part of the
  string. Docs and examples always use a level. A syntax error right after a
  long string hints the closer it met. Line and column advance through it.
- **`edits(p, {{old, new[, {count = N}]}, ...})`**: one file, in memory, each
  asserted (`count` defaults to 1), one diff, one write.
- **`edits_all({{p, {...}}, ...})`**: several files; **every file's edits are
  checked first, and nothing is written unless all hold**; then file by file,
  each atomic. (The set of files is not atomic: said so.)
- **`create(p, text)`**: refused if the file exists. `replace` prints a diff.
- **No staged overlay** (round 3 cut round 2's): every git call is a `run`,
  so a script that does anything but edit meets a program at once, and the
  overlay would have served only edit-only scripts at the cost of eleven read
  builtins consulting it. A chain of edits to one file is one `edits`; across
  files, one `edits_all`.
- **Diffs have their own allowance**, apart from the output budget.

## The dry run, honest

A program escapes the root and any dry run (`zig build` writes into the tree;
`git status` rewrites the index). So **a dry run never runs a program**: it
checks and prints every edit's diff against the disk as it is; the first `run`
or `start` stops it with class `dry` ("would run: zig build test; --write runs
it"). **`--write` runs everything.** The dry run is a preview, not the
everyday safety: Claude will pass `--write` on nearly every call that runs a
program, and the design says so.

## Git, in the Linux host's prelude, over `run`

No native reading of `.git`; every call uses `run`'s `{all = N}` keep, and
takes a repo (a path or `real("m:...")`), as `git -C`.

- Reading: `git_status(repo)` → `{{code, path}}` (`--porcelain=v1 -z`),
  `git_log(repo, n)` → `{{hash, subject}}`, `git_diff`, `git_show(repo,
  "HEAD:path")`, `git_ls_files(repo)` (git's view of what is in a checkout:
  no `.zig-cache`, no `zig-out`), `git_clean(repo)`.
- Changing: `git_commit(repo, msg, {add = "tracked" | "all" | {paths}})`
  (`-a`, the `-qam` habit; `add -A`; named paths; none for a merge commit),
  the message by `-F -`. **It refuses a message without a `Co-Authored-By:`
  line**, which Claude writes in each body. `git_push`, `git_fetch`,
  `git_merge_ff`, `git_worktree_add`, `git_worktree_remove`,
  `git_branch_delete`.

## Long jobs

- `start(argv, {log, cwd, env, secrets})` → `{pid, started}`: its own
  session, no terminal, no death signal (it outlives `shale` by design); it
  writes `<log>.job`, so a later call can find it.
- `job_of(pid)` or `job_of("runs:x/log.job")` adopts a job, including one a
  repo script detached itself.
- `alive(job)`: any process whose session is the job's (a `/proc` scan),
  not the leader alone (a soak's leader exits and its binary runs on).
  `/proc/<pid>/stat` is parsed from its last `)`; the start time compared
  raw.
- `stop(job)`: the group, by pidfd, after the start time matches: a reused PID
  is never signalled.
- `wait_for({job, file, contains, timeout_ms})`: `timeout_ms` required, and
  under the Bash call's own `timeout` (120 s unless raised, at most 600).

## Stdin

Steve named real stdin as a gap. **With no FILE and no `-e`, the script is
stdin** (`shale <<'SHALE' ... SHALE`, the launch convention: `EOF` lines occur
in files Claude edits). **With a FILE or `-e`, stdin is data**, read by
`input()`, whole, up to an `input_bytes` budget (past it is a stop). A stdin
script reports itself as `stdin`. Last in the order: a pipe into Shale loses
the producer's exit code, which `run` keeps.

## The CLI's defaults

`now()` is the wall clock (`SHALE_NOW` pins it for tests). Output 16 KiB,
diffs apart. Steps 5M. **Terse:** the `── used:` line only past half a budget
or on a stop; the effects list on `--verbose`.

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
    every repo, so it never dirties a gated checkout.
- **Claude curates** that log into zig-webbox's `docs/SHALE-WANTS.md`; a tag
  seen three times goes to the queue.
- **What it does not cover:** `run` with `{want=}` (logged to the same file),
  and Claude Code's own tools. **Read, Grep, Edit and Write stay allowed**:
  the ban is on bash and Python, and Edit is better than a python heredoc for
  one replacement. (A decision for Steve.)
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

## The order of work (for CC, after round 6)

0. **The experiment:** how Claude Code ends a timed-out Bash call (the box's,
   one minute).
1. Edits: long strings, `edits`, `edits_all`, `create`, counts, diffs'
   allowance, the script from stdin, `fail`.
2. The host table and `run`: the raw spawn and poll loop, the pure keep,
   `grep`, `{all}`, `log`, `env`, `secrets`, `check`, the refusals; mounts
   and `real`; the `.posix` policy; the CLI's defaults.
3. Text: `head`, `tail`, `grep_in`, `unique`, `concat`, regex `|`, streaming
   `grep` and `count_in`, `head_lines`, `tail_lines`.
4. The git prelude, from the Linux host; `must`; `http_get`.
5. Jobs: `start`, `job_of`, `alive`, `stop`, `wait_for`.
6. `shale-gate` and the hook; the SessionStart hook for `SHALE_SCRATCH`.
7. `input()`.

**Its own repo** earns its keep after (2), once the host seam exists.

## Open questions for rounds 4 and 5

- Does the language stay coherent with all this (names, argument order,
  error classes, records, what `print` of a record does)? Is any of it
  better as prelude Shale than as builtins?
- Is the whole still small enough to be "quite minimal on metal": what does
  metal's image gain, line by line?
- Written as a full day's work in v3 Shale (ten more workflows), does anything
  still send Claude to the escape on day one?

## Rounds

**Round 1** (a cold reviewer with the session's 6,609 commands): the families
and counts; the host table; `run` first; the edit gaps (long strings, the dry
run's missing overlay, no rollback); git over `run`; the fallback rule.

**Round 2** (the five commonest workflows written in proposed Shale): the
reading-verb allowlist unsound, so a dry run never runs a program; output
bounded by lines from both ends, and a `log`; mounts; alternation and
`unique`; diffs apart from the output budget; git in the Linux host's
prelude; long strings specified; verified PIDs; the CLI's clock.

**Round 3** (feasibility in zig 0.16, ten more workflows, enforcement):
filter before keep; `{all}` for git; `env` on `run` restored (additive) and
`secrets` that never become values; a raw spawn and poll loop, never std's
kill; the experiment first; `run` refuses shells and text tools; the
PreToolUse hook, fail-closed; mounts with `$VAR` for the per-session
scratchpad, `real()`, argv verbatim, "naming, not a sandbox"; jobs found
across calls; streaming file greps; `check`; the staged overlay cut for
`edits_all`.
