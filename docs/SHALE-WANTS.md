# What Claude reached past Shale for

The ledger the dogfood design names (`docs/designs/DESIGN-shale-dogfood.md`,
"Making the ban real"). Until the ban is in force (the hook goes in once
metal-vmm QUEUE 233 is done), Claude uses bash and Python freely, and writes
here each time it does something that looks like Shale's job (Steve,
2026-10-17: "do note when you do something that seems like something we may
want for shale"). A line: the date, a tag, what was done, and the Shale that
would do it; a tag that recurs three times goes to the queue. Once the hook is
in, its log (`~/.local/state/shale/wants.tsv`) feeds this file instead.

## Wants

| date | tag | what Claude did | the Shale that would do it |
|---|---|---|---|
| 2026-10-17 | queue-edit | inserted QUEUE 232 and 233 and FEEDBACK entries with python, anchoring on a neighbour's text | the queue tool (QUEUE 233 item 6): `queue_add`, `feedback_add` |
| 2026-10-17 | multi-edit | about 30 python heredocs today, several exact replacements each, asserted once (designs, docs, QUEUE) | `edit`'s list form and long strings (QUEUE 232) |
| 2026-10-17 | md-census | counted tracked markdown and its lines per repo (`git ls-files '*.md'` piped to `xargs cat \| wc -l`) | `git_ls_files` and `count_lines` (QUEUE 233), a loop over repos |
| 2026-10-17 | gate-chain | ran builds and tiers in sequence, detached, each result a line in a summary file, a waiter polling the file | `job_start` of a Shale script that `run`s each step and appends its result; `job_wait` on the file (QUEUE 233 item 4) |
| 2026-10-17 | http-status | `curl -s -o /dev/null -w "%{http_code}"` after publishing each essay | `run` of curl and its kept line; later `http_get` |
| 2026-10-17 | doc-check | five cold agents audited every doc in seven repos by hand; each listed checks a script could run every time: every cited path and `file:N` resolves, in this repo or a named sibling; every tracked doc is linked from the README; a README names no release tag or short hash; no "Steve, DATE" later than its line's commit; each table of names (builtins, knobs, routes, env vars, budgets, `/version` fields, build steps, scripts) equals the code's list | `git_ls_files`, `walk`, `re_find` over docs and source, `run` of `git log -1 --format=%cs`; one Shale script per repo in `.shale/`, run by its gate |
| 2026-10-17 | queue-check | the metal-vmm audit found duplicate numbers in QUEUE-ARCHIVE.md (99, 101, B14, B16, B23, P1), done items in the live queue, a stale "continue from 225", sections out of order | QUEUE 233 item 6's `queue_check`, with those duplicates as its fixtures |
| 2026-10-17 | quiet-edit | the linux_host refactor's 22 word renames printed about 300 lines of diff, all of it in my context; the gate (rightly) allows no filter | `edit(..., {quiet = true})` or quiet effects, the diff behind `--verbose` (essay notes/shale-from-the-inside.md) |
| 2026-10-17 | zig-rename | `edit`'s word mode reached an enum literal (`.watch`), a verb in comments and two test names | a token-aware rename in the Linux prelude over `std.zig.Tokenizer`: identifiers only, never in strings, comments or after a `.` |
| 2026-10-17 | dry-run-overlay | a dry run of `replace` then `edit` on the same file previewed the edits against the old file | a dry run that keeps its changes in an overlay, so later reads see them |
| 2026-10-17 | slice-and-grep | no `drop` (a slice is `last(take(l, j), j - i)`); `grep(p, "edit%(")`, a Lua habit, silently matched nothing | `drop`/`slice`; a plain-text `grep` that warns on a pattern character, or `grep_re` |
| 2026-10-17 | default-mounts | couldn't grep zig's std (outside the root), nor `edit` my own scratch scripts | a read-only mount of the zig install by default; the script's own folder readable |
| 2026-10-17 | walk-more-trap | on v33's prod, `walk("chat", {like = "*.md"})` ended with a `more` entry whose path was a `.png`; my script took it for a transcript (SHALE.md's checklist says to read `kind` first; I didn't) | a filtered walk's `more` entry still trips a careful author: name it so it can't be taken for a match (a `resume` field on the walk's result, not an entry), or make `like` apply to it |
| 2026-10-17 | git-prelude-dot | `git_commit(".", ...)` from the repo's own root stopped: `"."` is not a name; I ran from the parent instead | the git prelude takes `"."` (or no repo) as the root itself |
| 2026-10-18 | zig-nested-decls | metal-vmm main.zig's seams were found from its top level; the kernel's tcp.zig is one `Table` of 1,363 lines, and `zig_decls` cannot see inside it | `zig_decls(p, {in = "Table"})`: a container's own declarations and fields, with `uses`, so the seam finder (~/shale-scripts/seams.shale) works below the top level. **Done** (2026-10-18): `zig_decls(p, {container = name})`, with `reaches` (members through a `.`, by name) |
| 2026-10-18 | zig-move-banners | each move left its section banners (`// ── the interval timer ──`) over nothing in `from`; a blank line between a banner and its declarations keeps it from being "directly above" | `zig_move` takes a banner whose whole section it moves (the box's ~/shale-scripts/zig_tidy.shale removes the empty ones after). **Done** (2026-10-18) |
| 2026-10-18 | zig-shadow-check | an import named `machine` collided with seven parameters and locals named `machine` (no shadowing in Zig); the box's zig_split refuses a name the file already uses, by a word match | with `zig_tokens` (QUEUE 238): an exact check, identifiers only, before anything is written. **Done** (2026-10-18): `zig_tokens(p, {tag})`, the box's (238's item 1), and zig_split checks with it |
| 2026-10-17 | transcript-search | grepped the session's transcript for a test failure's lost output; no mount reaches it | none yet: an output the gate made me cut short (`tail`) was the real loss; a failed run's whole output kept in a file Shale can read |

## Out of scope

| date | tag | what Claude did | why it is not Shale's |
|---|---|---|---|
| 2026-10-17 | transcript-mine | parsed the session's 310 MB JSONL transcript in python to extract every Bash command and count programs | a one-off analysis of a format Shale has no reason to read (JSON at that size); if it recurs, a zig tool in `tools/` |
| 2026-10-17 | signal-experiment | a bash script that traps and logs signals, with children in their own group and session, to learn how Claude Code ends a timed-out call | an experiment on processes and signals themselves, which Shale deliberately does not expose |
