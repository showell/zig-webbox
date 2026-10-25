# zig-webbox

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its
store); webbox does the HTTP, the cookies, the streams and the disk, and a
host runs it.

- **Two hosts, one library.** The `webbox_linux` module runs a site as a
  Linux process. [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
  runs the same sources on a machine with no operating system, handing them
  its own `host_io`.
- **Several applications, one site.** `combo.Mount` serves a primary
  application at `/` and others beside it under their own prefix
  ("Combining applications", below).
- **The applications on it:** "The webbox ecosystem", below. Each names
  `.webbox` in its `build.zig.zon`; a grep of the sibling checkouts finds
  them all.

Zig 0.17.0 (`build.zig.zon`'s `minimum_zig_version`). Every repo here is a
sibling checkout under one directory, and each names the others by
relative path.

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

## For an application: the hosted root

An application's build hands its hosts one module, its **hosted root**,
which exports two declarations:

- **`site`**: `webbox.site.Site(App)`, where `App` is the application's
  table: `routes`, `setup`, `StartReport`, `bodyLimit`, and the optional
  `uploader`, `family` and `between`. `src/site.zig` (above `Site`) says
  each.
- **`hosting`**: what only the application can say about itself:
  `name`, `data_name`, `whole_read_max`, `cache_largest_most` and
  `describeStart(report, writer)`. zig-metal-unikernel's kernel requires the
  last four, and says so at compile time (its `probe/gopher.zig`); a Linux
  `main` uses what it needs.

The Linux host runs it from the application's own `main` (`webbox_linux`);
the kernel runs it through `addAppKernel` (zig-metal-unikernel's
`build.zig`). An application answers from `/` and makes its page URLs
relative, so it can be mounted under any prefix.

## Combining applications

`src/combo.zig` (`webbox.combo`) makes several applications one hosted
root:

    const combined = webbox.combo.Mount(@import("dog_park"), &.{
        .{ .prefix = "/todo", .root = @import("roc_todo") },
    });
    pub const site = combined.site;
    pub const hosting = combined.hosting;

The primary keeps `/` and the host's data and secrets roots; each mount
answers under its prefix (one segment of `[a-z0-9-]`) with the prefix
stripped (`http.stripTarget`, `http.restoreTarget`), a bare prefix 303s to
itself with a slash, and its files are `<data>/<name>` and `<auth>/<name>`. Families,
body limits, uploaders, `between` and `hosting` compose; `src/combo.zig`'s
header is the rule for each, and what it does not do (no URL rewriting, no
bus-key separation, no nested mounts).

**A combination's build lives in its primary's repo**: its root module, its
Linux `main`, its serve step and its kernel (`addAppKernel` with `.parts`,
each mounted application's module and assets.zon). Pitfalls:

- **Two Roc applications in one binary** share Roc's four runtime symbols.
  The combination's root declares `pub const roc_hooks =
  @import("roc_hooks");` (`<roc-webbox>/src/roc_hooks.zig`), and the
  kernel's root forwards it.
- **One Roc compiler per combination:** the primary's, passed down as
  `-Droc`. Each Roc application pins its version in a `roc-version` file;
  pins that disagree fail at configure.

## The webbox ecosystem

Sibling checkouts beside this one. Each README is the detail; the commands
are from each repo's `build.zig` (`zig build -l` lists them).

| repo | what | build, test, serve | metal | where it serves |
|---|---|---|---|---|
| [zig-webbox](https://github.com/showell/zig-webbox) | this library | `zig build test`, `zig build consumers` | through zig-metal-unikernel | (a library) |
| [angry-gopher](https://github.com/showell/angry-gopher) | Gopher Chat and the rest of lynrummy.com; **primary** of lynrummy.com's combination (`zig-server/src/router.zig`: Codex Chat at `/codex-chat`, the UO town at `/uo`) | `ops/check_zig` (its gate); `cd zig-server && zig build run` (:9001) | zig-metal-unikernel's `zig build gopher` (`gopher.elf`) | lynrummy.com, on the `metal` droplet behind prod's Caddy |
| [cobble-webbox](https://github.com/showell/cobble-webbox) | Cobblestone's Codex apps: Codex Chat (module `codex_chat`), Damian's UO town (`uo_town`), the games, Idea Forge | `zig build test`; `serve-chat` (:9106), `serve-uo` (:9107), `serve` (games, :9104), `serve-ideas` (:9105) | none of its own: mounted in angry-gopher's | inside lynrummy.com: Codex Chat since v38; the UO town is on angry-gopher's master, unreleased |
| [dog-park](https://github.com/showell/dog-park) | the Dog Park game (Zig, Roc physics); **primary** of Dog Park + TODO (`src/combos/dogpark_todo.zig`) | `zig build test`, `zig build check`; `play` (:9103); `dogpark-todo`, `serve-dogpark-todo` (:9113) | `zig build metal` (`dogpark.elf`), `metal-gate`; `metal-dogpark-todo` (`dogpark-todo.elf`) | dogpark.lynrummy.com, its own droplet (its `DEPLOY.md`) |
| [roc-webbox](https://github.com/showell/roc-webbox) | a Roc platform for webbox, a TODO list on it (modules `roc_todo`, `roc_todo_metal`, `roc_hooks`) | `zig build test` (the Roc `roc-version` pins); `serve` (:9110) | `zig build metal` (`roc-todo.elf`) | nowhere: alone, or in dog-park's combination |
| [observatory](https://github.com/showell/observatory) | a machine that polls another's `/version` | `zig build test`; `run` (:9104) | `zig build metal` (`observatory.elf`) | prod, as a Linux program watching Dog Park |
| [shale](https://github.com/showell/shale) | the script language, on `store` | `zig build test` | (in the applications' kernels) | (a library) |
| [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel) | the kernel that serves any hosted root with no OS (`addAppKernel`) | `zig build test`; `zig build gopher`; tiers in its README | it is the kernel | its `DEPLOY.md`: a release is a `v*` tag |

Ports collide (cobble-webbox's `serve` and the Observatory's `run` are both
:9104); each step names the environment variable that moves it.

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
this checkout and one at a time, shale's `zig build test`, metal-vmm's
queue tool (by shale's `shale`), the Observatory's and dog-park's `zig build test`, zig-metal-unikernel's `zig
build gopher` and angry-gopher's `ops/check_zig`; it needs those checkouts
beside this one, and fails naming one that is missing. Run it before a change
here goes to master: each of them caught a webbox change that `test` passed.
cobble-webbox's and roc-webbox's own tests are not in it (angry-gopher's
check compiles cobble-webbox's two mounted modules).
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
| Serves | lynrummy.com, on zig-metal-unikernel: its newest release tag's message names the zig-webbox commit (`git -C ../zig-metal-unikernel tag -n1 --sort=-creatordate`, the first line). dogpark.lynrummy.com, on the same kernel, through dog-park's own image. master may be ahead of both; `combo.Mount` is newer than v38, the release serving lynrummy.com on 2026-10-25 |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
