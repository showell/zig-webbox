# Design: Shale, dogfooded (Claude without bash or Python)

**Status: round 1 of 5** (the box and cold reviewers, 2026-10-18). No code.
Steve: five rounds, then CC builds it; the final design on the essay surface.

## The thought experiment

Steve, 2026-10-18: ban Claude from running bash and Python, which forces us to
dogfood Shale. Fall back to bash or Python only where Shale cannot do the job
yet, and then **either queue the missing feature or justify why it is out of
Shale's scope**. A litmus test: "if we're reaching for Python, then why not do
it in zig?" Shale has behaved identically on bare metal and Linux; that may
relax: **the Linux version could be a superset**, but Shale on metal stays
minimal, **without a bunch of comptime hacks**. Pipe-like behaviour is likely
the best way to make it versatile. Git support and real stdin are the named
gaps. A repo of its own may come later; no hurry. Bootstrap: `shale` on bash's
search path.

## The evidence: what Claude actually ran

One long session on this box (several days of engineering): **6,609 Bash
calls**. By family (rough; heredoc bodies inflate a few):

| family | about | Shale today |
|---|---|---|
| A. file edits: python heredocs reading a file, asserting a multi-line `old` occurs once, replacing, writing (1,484 of 1,680 `python3` calls), plus 345 `sed -i`, 208 `cat >` | 2,000 | partly: `edit` is one literal a call, and refuses multi-line strings |
| B. filtering another program's output: `2>&1 \| grep \| head`, `\| tail`, `${PIPESTATUS[0]}` (211), timing with `date +%s` | 2,800 | no: no stdin, no programs |
| C. builds and tests: `zig build` (1,391), repo scripts, `timeout` | 1,400 | no |
| D. git: commit 924, log 803, push 768, add 584, status 627, diff, show, worktree, merge, fetch | 1,900 | no |
| E. reading code: `grep -rn`, `sed -n`, `cat`, `ls`, `wc` | 2,600 | mostly; and Claude Code's own Read and Grep tools do it better |
| F. long jobs: `setsid nohup`, waiting on a file or a PID, `kill` | 1,000 | no |
| G. HTTP: `curl` | 160 | no |
| H. disk images: mtools | 50 | no |
| K. QEMU, sudo, ssh | 450 | out of scope |

What it says: **the edits are the single biggest use of Python**; **most of the
rest is running a program and reading a bounded piece of what it said**.

## The architecture: one core, a host's table

- **The core is unchanged and identical on both hosts:** the lexer, the
  parser, both engines (the tree-walker and the VM, which `gate_test.zig`
  holds identical), the budgets, the store, text, regex and lists. The new
  long strings and edit transactions (below) are core: they touch nothing
  outside.
- **What reaches outside is a host's table, at runtime.** A handful of
  builtins (`run`, `input`, `env`, `start`, `alive`, `stop`, `wait_for`) join
  the closed builtin enum, so its completeness check stays; each forwards to
  `Options.host: ?*const Host`, function pointers the host supplies, as
  webbox's `host_facts` and `host_fetch` are supplied by each host. **Metal
  passes null**: every such call stops with a new class `host` ("`run`: not on
  this host"). Its cost on metal is a stub a name. No comptime switch anywhere.
- **The Linux table lives outside `src/script/`** (`src/shale_host_linux.zig`,
  beside `script_runner.zig`); `src/script/` never imports `std.process`, and
  a test greps that it does not.
- **The gate:** a test-only `FakeHost` (argv to `{code, out, err, ms}`,
  recording every call), a fresh copy for each engine; the gate compares the
  call logs as it compares effects. Steps are charged on bytes, never on
  milliseconds, so runs stay deterministic. Real processes are tested apart,
  against a small fixture program the build makes, never `/bin/sh`.
- **Names, a runtime policy:** `.fat` (the site's data, the route's) or
  `.posix` (a code checkout: refuse only `""`, `.`, `..`, NUL, `/` within a
  part; exact case; no path measuring). The CLI defaults to `.posix`.
- **Modes:** `run` and `start` end a slice, and are refused in a background
  run, as changes are.

## Running a program: `run`

    run(argv, {timeout_ms = 120000, keep = "tail", out_most = 16384, merge = true, cwd = "x", input = s, env = {...}})
      → {code, out, err, ms, timed_out, cut, out_total}

- **`timeout_ms` is required.** A default is a decision nobody made.
- **Output is bounded, and the bound is the token-saving feature.** A 10 MB
  build log comes back as its last `out_most` bytes, `cut = true`, and the
  real total; the rest is read and dropped, so the child never blocks. `keep`
  is `"tail"` or `"head"`.
- **On a timeout the child's whole process group is killed.**
- **New budgets:** `runs` (how many) and `run_ms` (wall time in all).
- **Pipelines** pass through the script: `run(b, {input = a.out})`, or Shale
  filtering `a.out`. No OS pipes between children; every byte is budgeted.
- **`fail(msg)`** ends a run with class `fail` and the CLI's exit 1, so
  `shale ... && git push` composes.

## Shale as a filter: stdin

- **With no FILE and no `-e`, the script is stdin**: `shale <<'EOF' ... EOF`,
  the python heredoc's own shape. **With a FILE or `-e`, stdin is data**,
  read by `input()`. No flag decides which.
- Read whole before the run, up to an `input_bytes` budget (16 MiB); past it
  is a budget stop, never a silent cut. No streaming until a case needs it.
- New string builtins for both `input()` and `run`'s output: `grep_in(s,
  lit)` → `{line, text}`, `head(s, n)` and `tail(s, n)` in lines.

## Edits that work

The python pattern applies several exact replacements to one file in memory,
each asserted to occur exactly once, and writes once: all or nothing, every
literal multi-line. Shale's `edit` re-reads the disk each call and refuses an
absent or doubled literal (good), but:

- **multi-line strings are refused** (SHALE.md: "a string ends on its
  line"): the blocker. **Long strings, Lua's `[[...]]` and `[==[...]==]`.**
- **a dry run has no overlay**: a change is logged and not made, so a second
  `edit` of the same file reads the old disk. **The dry run does not predict
  the write.**
- **no rollback**: with `--write`, the third edit failing leaves the first two.
- no count assertion; no create-only (`replace` overwrites silently).

**So:** `edits(p, {{old, new[, {count = N}]}, ...})` (in memory, one diff, one
write); `create(p, text)` (refused if it exists; its diff); `replace` prints a
diff; and a **staged mode** for the CLI: every change goes to a per-run
overlay, every read looks there first; a dry run is staged and never
committed, `--write` is staged and committed only if the run finished. One
mechanism for both the prediction and the rollback. Metal keeps "just runs".

## Git, over `run`

No native reading of `.git`. A git layer in the shared prelude (parsed only
when called, so free on metal until it stops there with "not on this host"):

- reading (run in a dry run): `git_status(repo)` → `{{code, path}}` from
  `--porcelain=v1 -z`; `git_log(repo, n)` → `{{hash, subject}}`;
  `git_diff`; `git_show`; `git_clean(repo)`;
- changing (effects, printed in a dry run): `git_add(repo, paths)` (named
  paths only, never `-A`), `git_commit(repo, paths, subject, body)` (the
  message by `-F -` through `input`; the trailer from `SHALE_COAUTHOR`, and a
  commit without it refused), `git_push`, `git_fetch`, `git_merge_ff`,
  `git_worktree_add`.

## A dry run and programs

A program escapes the root and the dry run: Shale's guarantees cover only its
own effects. So **a `run` is an effect**: a dry run executes only argv on a
short, named list of reading verbs (git status/log/diff/show/rev-parse/
ls-files, `zig build check|test`, `zig version`); anything else is printed
(`would run: ...`), logged, and answers `{dry = true}`. `--write` runs all.

## Long jobs

`start(argv, {log, cwd})` → `{pid}` (its own session, no terminal, output to a
log under the root); `alive(pid)`; `stop(pid)` (its group); `wait_for({pid,
file, timeout_ms})`. The box's detach recipe in one tested place, which ends
two of its bug classes ("`a && b &` hides the PID", "wait on a PID, never a
pattern").

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
is Claude Code's own Read and Grep tools, not Shale's.

## The order of work (for CC, after round 5)

1. Edits that work: long strings, `edits`, `create`, counts, the staged
   overlay, the script from stdin.
2. The host table, `run`, `fail`.
3. The git prelude.
4. The `.posix` names policy and the CLI's defaults (output 16 KiB, steps
   50M).
5. `start`, `alive`, `stop`, `wait_for`.
6. `input()`, `grep_in`, `head`, `tail`.
7. `http_get` over curl.

**Its own repo** earns its keep after (2), once the host seam exists: the Linux
layer will change far more often than the core, and every Shale-only change
re-gates webbox today.

## Open questions for the next rounds

- Is the dry run's reading-verb list the right safety, or an attack surface
  of its own (a `zig build test` that writes, a git hook)?
- Is `start`/`wait_for` Shale's job, or a box policy that belongs elsewhere?
- Does the staged overlay belong in the core (both hosts) or only the CLI?
- Is `run`-through-the-script enough, or do real pipelines (streaming)
  matter for a 10 MB log?
- What does Claude actually type? Walk the five commonest workflows end to
  end in proposed Shale, and count keystrokes against bash.

## Rounds

**Round 1** (a cold reviewer with the session's 6,609 commands): the families
and counts; the host table; `run` first; the edit gaps (long strings, the dry
run's missing overlay, no rollback); git over `run`; the fallback rule.
