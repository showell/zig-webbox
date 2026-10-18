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

**Shale**, the script language for a site's own data, is its own repo,
[shale](https://github.com/showell/shale) (`../shale`), built on this
library's `store`: an application takes its `shale` module beside
`webbox`. It lived here (`src/script/`) until 2026-10-18; its history is
this repo's (`git log -- src/script`).

## Checks

    zig build test          # the library's tests: seconds
    zig build consumers     # its docs, then the consumers' own checks against this tree: minutes

**`test`** includes the library's own shape (`src/library_test.zig`: what
each root reaches it names, the modules each half may import, no page
embedded, every named module in its test block, `Io` from `host_io`).
**`consumers`** runs shale's doc check on this repo's docs, then, against
this checkout and one at a time, shale's `zig build test`, the
Observatory's and dog-park's `zig build test`, zig-metal-unikernel's `zig
build gopher` and angry-gopher's `ops/check_zig`; it needs those checkouts
beside this one, and fails naming one that is missing. Run it before a change
here goes to master: each of them caught a webbox change that `test` passed.
`-Dtest-filter=TEXT` runs only the tests whose names contain it;
`-Dtest-timing` prints each test's time, slowest first.

Others run these too: angry-gopher's `ops/check_zig` and zig-metal-unikernel's
tier 3 both run `zig build test` here. And every file under the kernel's
`src/pinned/` is a byte-for-byte copy of one here (`src/body.zig` as
`webbox_body.zig`, `src/wake.zig` as `webbox_wake.zig`); its
`zig build pinned` fails when a copy differs.

## Status

| | |
|---|---|
| Source | first moved from angry-gopher's `zig-server/src`, with its history |
| Serves | lynrummy.com, on zig-metal-unikernel: its newest release tag's message names the zig-webbox commit (`git -C ../zig-metal-unikernel tag -n1 --sort=-creatordate`, the first line). dogpark.lynrummy.com, on the same kernel, through dog-park's own image. master may be ahead of both |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
