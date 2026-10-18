# zig-webbox

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its
store); webbox does the HTTP, the cookies, the streams and the disk, and a
host runs it.

- **Two hosts, one library.** The `webbox_linux` module runs a site as a
  Linux process. [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
  runs the same sources on a machine with no operating system, handing them
  its own `host_io`.
- **The applications on it:** [angry-gopher](https://github.com/showell/angry-gopher)
  (lynrummy.com), [dog-park](https://github.com/showell/dog-park) and the
  Observatory (`observatory/`). Each names `.webbox` in its
  `build.zig.zon`; a grep of the sibling checkouts finds them all.

## The modules

| module | root | what |
|---|---|---|
| `webbox` | `src/webbox.zig` | portable: what an application's code imports |
| `webbox_linux` | `src/webbox_linux.zig` | the Linux host, for a Linux `main` only |
| `host_io` | `src/host_io_std.zig` | the one file that names the host: std's `Io` here |

An application depends on this repo by path (a sibling checkout) and takes
all three from `b.dependency("webbox", ...)`. It imports the library by
module name, never a file by path.

Every public module, with one line on what it is, is in the two index files:
`src/webbox.zig` and `src/webbox_linux.zig`.

## For a host

A host runs a `site.Site(App)`. **The authority is `src/site.zig`'s header
and its `Host`, and `src/wake.zig`;** this is the map.

- **Three calls, in order:** `mem_meter.init(base)` before anything else;
  `start(io, Host)` once, before the first request; then per request
  `route`, and serve or drop the stream it answers (`bus.serveKept`,
  `bus.nextFrame`, `bus.drop`).
- **`Host`**, everything a host supplies, once: `roots` (the data and
  secrets directories), `free_space`, `trusted_proxy`, and the optional
  `facts`, `log`, `logs`, `say` and `fetch`.
- **`between(io, Now) Wake`**, the application's work between requests,
  one slice at a time. `Wake` says when it next needs a turn: `more` (now),
  `at` (a time on the awake clock) or `idle` (until a request or its
  fetch ends). `Now` carries both clocks; `periodAfter` schedules a period
  from when it was due.
- **The fetch** (`host_fetch`): one GET at a time, which the application
  starts from `between` and reads on a later call. A host offers it as a
  `Fetcher`; the outcomes are `Outcome`. On Linux it is `linux_fetch`, on a
  thread of its own.
- **The Linux host** (`webbox_linux.linux_host`): `Env` and `Options`
  configure it. It steps `between` on a thread of its own, under the turn,
  and sleeps on a doorbell that every handler's end rings, until the site's
  `Wake.at` or a ring.

## Scripts: Shale

`webbox.script` (`src/script/`) runs **Shale**, a small language for a
site's own data. You explore the store and print, read the output, then
write a script that changes things. It has Lua's look and smaller
semantics of its own. Every effect goes through webbox's `store`, so a
script does the same on Linux and metal, and every run stays inside its
budgets. A script **just runs**: a stopped run keeps what it already did,
and its effects log says what.

**The reference is [docs/SHALE.md](docs/SHALE.md):**
- the language and its grammar;
- every builtin, with its cost and its errors;
- the budgets and what each charges;
- the store and its confinement;
- the runner (`zig build script`) and the signed route on the live site
  (`script_route`, `zig build shale-sign`);
- a short tutorial;
- a cookbook of operator scripts, each tested against a store shaped like
  angry-gopher's data;
- what was decided and refused.

    script.run(io, backing_allocator, root, source, budgets, now, out) -> Result

## Checks

    zig build test          # every test but the expensive ones: about 30 s
    zig build consumers     # the applications' own checks against this tree: minutes
    zig build fuzz          # the expensive fuzzes and sweeps, for a bug hunt
    zig build doc-check     # every repo's docs: each cited path and name is there

**`test`** includes the library's own shape (`src/library_test.zig`: what
each root reaches it names, the modules each half may import, no page
embedded, every named module in its test block, `Io` from `host_io`).
**`consumers`** runs, against this checkout and one at a time, the
Observatory's and dog-park's `zig build test`, zig-metal-unikernel's `zig
build gopher` and angry-gopher's `ops/check_zig`; it needs those checkouts
beside this one, and fails naming one that is missing. Run it before a change
here goes to master: each of them caught a webbox change that `test` passed.
**`fuzz`** runs the tests named `expensive fuzz: ...` or `expensive sweep:
...`, which `test` counts as skipped: a fuzz hunts bugs once, and each bug it
finds becomes a test of its own. `-Dtest-timing` prints each test's time,
slowest first. **`doc-check`** runs `tools/doc_check.shale` (metal-vmm QUEUE
237) from the folder that holds the repos, its fixtures first: in every
repo's tracked docs but the history, each backticked or linked path must
resolve (in the doc's repo, a sibling the line names, or one repo alone), and
each `` `file`'s `name` `` must be in that file. It fails on any finding, and
no gate runs it yet.

`-Dtest-filter=TEXT` runs only the tests whose names contain it;
`-Dscript-fuzz=N` sets how many sources the script fuzzer runs. Two more
steps measure and are run by hand, by no tier: `zig build script-bench`
(Shale's hot paths) and `zig build shale-scale` (the largest site each
cookbook script fits). `zig build --help` lists every step and option.

Others run these too: angry-gopher's `ops/check_zig` and zig-metal-unikernel's
tier 3 both run `zig build test` here. And every file under the kernel's
`src/pinned/` is a byte-for-byte copy of one here (`src/body.zig` as
`webbox_body.zig`, `src/wake.zig` as `webbox_wake.zig`); its
`zig build pinned` fails when a copy differs.

## Docs

- [docs/SHALE.md](docs/SHALE.md): Shale's reference (above).
- [docs/SHALE-AGENTS.md](docs/SHALE-AGENTS.md): Shale as an agent's tool on
  Linux.
- [docs/SHALE-WANTS.md](docs/SHALE-WANTS.md): the ledger of what Claude
  reached past Shale for.
- [docs/designs/DESIGN-shale-dogfood.md](docs/designs/DESIGN-shale-dogfood.md):
  the design for Claude working in Shale instead of bash and Python.

## Status

| | |
|---|---|
| Source | first moved from angry-gopher's `zig-server/src`, with its history |
| Serves | lynrummy.com, on zig-metal-unikernel: its newest release tag's message names the zig-webbox commit (`git -C ../zig-metal-unikernel tag -n1 --sort=-creatordate`, the first line). dogpark.lynrummy.com, on the same kernel, through dog-park's own image. master may be ahead of both |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
