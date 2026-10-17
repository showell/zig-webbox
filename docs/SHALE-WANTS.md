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

## Out of scope

| date | tag | what Claude did | why it is not Shale's |
|---|---|---|---|
| 2026-10-17 | transcript-mine | parsed the session's 310 MB JSONL transcript in python to extract every Bash command and count programs | a one-off analysis of a format Shale has no reason to read (JSON at that size); if it recurs, a zig tool in `tools/` |
| 2026-10-17 | signal-experiment | a bash script that traps and logs signals, with children in their own group and session, to learn how Claude Code ends a timed-out call | an experiment on processes and signals themselves, which Shale deliberately does not expose |
