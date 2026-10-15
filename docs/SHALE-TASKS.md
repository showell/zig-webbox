# Shale's background runs and streams: a design note

**Rewritten to Steve's model** (metal-vmm QUEUE 211, 2026-10-15). The
watchdog, the task lifecycle, `host()` and the simulated week are cut: a
background run is a long scan, not a forever-program. What is built is
marked **built**; the rest is a proposal for the box to cut down before
anything touches a kernel.

## The model, in one paragraph

A run is **atomic** (today's: whole inside one request, and it may change
the store) or **background** (it only reads, and is stepped in slices
between requests). A slice ends after any store call or after N steps,
whichever comes first, so "swap it out on any I/O request" is a slice
boundary after the call. Builtins are never cut; their work is capped
instead. One background run at a time: a second is refused. The VM is an
opaque `Process` to its host: a handful of calls, nothing of its insides.

## 1. A slice: the one host-free piece both hosts need

**Built** (`vm.Task`; `process.zig`, "the contract", in SHALE.md). A run's
whole state is data, so it can stop between any two ops and go on later:

- `Process.step(.{ .steps, .now })` runs one slice: `paused`, `finished`
  or `stopped`. **A slice ends after `steps`, or after any store call**
  (`builtins.touches_store`), whether the call returned or failed into an
  `attempt`. `now()` is the slice's clock.
- **The gate holds it.** Every run in the tests is also run cut into
  slices of 1 to 29 steps, and must equal the uncut run in everything. A
  run that calls no change builtin is cut **as a background run**, so
  every read-only script in the suite holds background to atomic (a plant
  that adds a step in a background slice fails 74 tests).
- **Budgets stay the run's**: steps, reads and changes count across
  slices, as one run.
- **`yield()` is only a collection point** now: pure work is preempted by
  steps, so it schedules nothing.

## 2. The caps: a builtin is a bounded slice of time

**Built.** A builtin runs whole inside its slice, so each call's work is
capped, and scripts loop in parts:

| cap | default | a call past it | in parts |
|---|---|---|---|
| `call_bytes`: what one `read` or scan brings | 1 MiB | an `argument` error naming the range form | `read(p, offset, n)`, `count_in(p, s, offset, n)`, `find_in(...)`, `count_lines(...)` |
| `call_entries`: what one `walk` considers | 256 | the part ends with `{path, kind = "more"}` | `walk(p, {after = that path})` |

Each `walk` stat counts as a read. A background run passes by an entry
that vanished between its folder's listing and its stat.

**The worst case on metal's numbers** (a disk command about 1 ms, a
contiguous run of clusters one request of up to 1 MiB):

- a 1 MiB read or scan of a contiguous file: about 1 command, ~1 ms;
- the same file in 4 KiB clusters scattered: up to ~256 commands, ~256 ms;
- a `walk` of 256 entries: 256 stats, plus a listing per folder; each stat
  is a directory lookup, a command when its sectors are not cached:
  up to ~256 ms cold.

**Not capped yet:** one `ls` (or a walk's listing) of a folder with
thousands of entries is one call. Its cost is the folder's directory
sectors, read whole. A cap there would need `ls` in parts too; it is the
box's to weigh.

## 3. The background run on Linux

**Built in the route** (`script_route.zig`), the host's half next:

- **The envelope:** `shale-1 target=... sequence=... expires=...` plus
  ` mode=background` or ` mode=kill`. None is atomic; `mode=atomic` is not
  a spelling. Signed and recorded as today: a background run's number is
  spent when it starts.
- **One at a time:** a second background run is refused 503 `busy`
  *before* its number is spent. A host that steps none (no `backing`
  allocator) refuses one 501 `no_background`.
- **Answered at once:** 202 and its number. `writeBackgroundStatus` shows
  the run going (steps, slices, output so far) or the one that ended last.
- **Kill:** a signed `mode=kill` request ends the run going (409
  `not_running` when none is), its memory given back.
- **Its memory** is the host's allocator, never a request's heap; every
  byte comes back at its end or its kill (the tests' allocator checks).
- **The log:** its start (with ` mode=background`), its progress at most
  every 10 s, and its end (finished, stopped, or killed by which number).
  Progress is not logged every slice: a walk-heavy run takes a slice a
  store call, so a line a slice would be a write per read, from a run
  that only reads. That is a change from the queue's "per slice"; the box
  may want it otherwise.
- **Scheduling (the host's half, next):** `Site.between(io)`, the app's
  hook, calls `script_route.sliceBackground`. The Linux host runs a thread
  that takes the turn for one slice, lets go, and yields to any handler
  waiting for the turn before it takes it again; with no run, it sleeps
  50 ms. So a request arriving mid-run waits at most one slice.

## 4. The stream (the SSE item): proposed, after metal's scheduling

A background run's output is a kept stream, served between handlers:

- `GET .../runs/<id>/stream` is the kept stream of its output; each line a
  numbered event in a ring, so `Last-Event-ID` resumes after it. Lines
  fallen off the ring are announced (`event: missing`, `data: <first>
  <last>`), never skipped silently.
- **A watcher never keeps a run alive, nor stops one:** its effects (none:
  it only reads) and its end do not depend on the network.
- **Heartbeats:** the bus's `: ping`, and an `event: state` each period
  (slices, steps, state).
- **Auth:** the bearer key on every GET; a reconnect is a new request,
  checked again.
- **Caddy:** `reverse_proxy` flushes `text/event-stream` as it comes;
  chat's streams already pass through it. To confirm on the box with a
  stream held open for 10 minutes.

## 5. Metal: the box's (stop and report before any kernel change)

- One slice after each handler, plus slices in idle time: a request waits
  at most one slice, and the run never starves, so there is no floor.
- The run's memory from the page allocator, never the request heap.
- An overrun (a slice past its wall-time target) shows on `/admin/host`,
  as idle steps' do.
- A second Process later should need no kernel change but a count.
