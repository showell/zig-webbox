# zig-webbox

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its
store); webbox does the HTTP, the cookies, the streams and the disk, and a
host runs it.

- **Two hosts, one library.** The `webbox_linux` module runs a site as a
  Linux process. [zig-metal-unikernel](https://github.com/showell/gopher-metal)
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

## Checks

    zig build test

## Status (2026-10-13)

| | |
|---|---|
| Source | moved from angry-gopher's `zig-server/src`, with its history (24 files) |
| Serves | lynrummy.com, as part of angry-gopher v29 on metal |
| Tests | the library's own unit tests; the request-edge harness for its number parses still runs in angry-gopher |
