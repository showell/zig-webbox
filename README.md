# zig-webbox

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its
store); webbox does the HTTP, the cookies, the streams and the disk, and a
host runs it.

- **Two hosts, one library.** The `webbox_linux` module runs a site as a
  Linux process. [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
  runs the same sources on a machine with no operating system, handing them
  its own `host_io`.
- **Two applications use it:** [angry-gopher](https://github.com/showell/angry-gopher)
  (lynrummy.com) and [dog-park](https://github.com/showell/dog-park).

## The modules

| module | root | what |
|---|---|---|
| `webbox` | `src/webbox.zig` | portable: what an application's code imports |
| `webbox_linux` | `src/webbox_linux.zig` | the Linux host, for a Linux `main` only |
| `host_io` | `src/host_io_std.zig` | the one file that names the host: std's `Io` here |

An application depends on this repo by path (a sibling checkout) and takes
all three from `b.dependency("webbox", ...)`. It imports the library by
module name, never a file by path.

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

    zig build test

Others run these too: angry-gopher's `ops/check_zig` and zig-metal-unikernel's
tier 3 both run `zig build test` here. And `src/body.zig` is copied byte for
byte into the kernel's `src/pinned/webbox_body.zig`, whose `zig build pinned`
fails when the two differ.

## Status (2026-10-15)

| | |
|---|---|
| Source | first moved from angry-gopher's `zig-server/src`, with its history |
| Serves | lynrummy.com, in zig-metal-unikernel's v30 (zig-webbox `92ea157`); master is ahead (Shale for v31) |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
