# Shale's long runs and streams: a design note

**Not built.** This is a proposal for metal-vmm QUEUE 211's M2 to M6 and
its SSE item, written after V (the VM) and M1 (`yield`, copy at a yield)
landed, for the box and Steve to cut down before anything touches a host.
It is short on purpose, and every point is one to accept, change or
strike.

## What V and M1 already give

- **A run's whole state is data.** The VM never recurses: its program
  counter, its frames, its operand stack, the run's slots and counters,
  and the arena are fields, not Zig stack frames. **So a run can stop
  between any two ops and go on later**, not only at a `yield`. That is
  the one new fact this note builds on.
- **`yield` is where memory is collected.** Copy-at-yield keeps the arena
  to what the run still reaches, charged, and capped by `kept`.
- **Every stop has its place**, and the walker holds the VM to its
  semantics in the tests.

## 1. A slice: the one host-free piece both hosts need

Proposed in `src/script/` (portable, no host): a `vm.Task` that owns a
Run, its code and its machine, and steps it:

```zig
pub const Slice = struct { steps: u64 };
pub const Outcome = union(enum) {
    yielded: u64, // seconds asked for
    paused, // the slice's steps ran out at an op boundary (one-shot streams only)
    finished,
    stopped: Stop, // fail fast: no restart
};
pub fn step(task: *Task, slice: Slice) Outcome;
```

- **Two meanings of a slice running out.** For a *task*, a slice that
  spends its steps without yielding is a **stop** ("never yields": the
  per-slice budget, M6's first planted task). For a *one-shot run*
  streamed to a watcher, it is a **pause**: the run goes on in the next
  slice, unchanged. The difference is the caller's to choose, with one
  flag.
- **Budgets stay the run's.** Steps, reads and changes count across
  slices, as one run. A task's lifetime budgets would be its own
  (`lifetime=<s>`, M4).
- **Tests come for free:** a run cut into slices of every size from 1
  step up must end exactly as the uncut run does: the same output,
  effects, stop and steps. That is the gate again, with the walker as
  the oracle.

## 2. M2: Linux, a task on its own thread

- One thread for the task, beside the connections. Each slice: take the
  turn, `step`, release the turn. On `.yielded(s)`, sleep `s` outside
  the turn. On `.finished` or `.stopped`, record the verdict and end.
- **Its test:** a request sent while the task sleeps is answered before
  the task wakes, with the turn's own counters as the evidence.
- **What it must not do:** take the turn while it sleeps, or touch the
  application's state outside a slice. HOST.md, "One handler at a time":
  only handlers, and now slices, run under the turn.

## 3. M3: metal, the idle task

- `idle.Task` runs one slice per idle step, with per-slice budgets. Its
  arena comes from the page allocator, never the request heap.
- **The floor:** at least one slice every 60 s, even under load, counted
  as a busy turn.
- Kernel work: the box's, after M2 shows the shape on Linux.

## 4. The one-shot stream (the SSE item): it needs slices, not `yield`

The queue guessed the one-shot stream needs no yield. It needs no
*`yield` in the script*, but it does need slices, on both hosts:

- **The turn never waits on the network** (HOST.md). So a handler can't
  write a run's output to its own stream while it runs. The output must
  go to the bus, and the stream be a kept stream, served outside the
  turn on Linux and **between handlers on metal**.
- **On metal, a run inside one handler can't be watched while it runs**:
  kept streams are served only between handlers. A streamed one-shot run
  must run as slices, the handler that started it having returned. That
  is section 1's `.paused`.
- **So:** `POST /admin/script` with `stream=1` in the envelope checks
  everything as now (signature, sequence, durably recorded) and returns
  at once with the run's id. The run then goes on in slices. `GET
  /admin/shale/runs/<id>/stream` is the kept stream of its output. The
  plain one-shot route stays as it is.

The nuances, each a proposed decision:

| nuance | proposed |
|---|---|
| the watcher disconnects | **the run finishes.** Its effects happen whether or not anyone watches; stopping on a closed socket would make a run's effects depend on the network. The log says it ran unwatched |
| reconnects | each output line is a numbered event in the run's ring; `Last-Event-ID` resumes after it. Lines that fell off the ring are announced (`event: missing`, `data: <first> <last>`), never skipped silently |
| heartbeats | the bus's `: ping` keepalives already exist. Add an `event: state` every period: the slice count, the steps, and the state (`running`, `finished`, `stopped`). A watcher alarms on no state event within two periods, the same rule as the external checker below |
| the single thread | the stream is a kept stream (bus.zig), so its writes are queued and drained as chat's are, with the same back-pressure and drop rules. A slice publishes; it never writes a socket |
| auth | the bearer key on every GET, so a reconnect is re-checked by being a new request. The run itself is signed as now |
| several watchers | each a subscriber to the run's key; the ring serves each from its own `Last-Event-ID` |
| Caddy | nothing to change, to be confirmed on the box: `reverse_proxy` flushes `text/event-stream` responses as they come, and sets no response timeout by default; chat's live streams already pass through the same Caddyfile. Check with a stream held open for 10 minutes |

## 5. M4 to M6, in one line each

- **M4, the lifecycle:** `mode=task lifetime=<s>` in the signed envelope
  (at most 30 days). Install, stop and replace are signed and burn
  sequence numbers. Expiry is checked at every wake.
- **M5, `host()`:** a map of named integers from a typed provider beside
  `host_facts`, never parsed from display strings; a key the host lacks
  is an `index` error. `status(s)` sets the verdict. The route shows the
  state, the verdict, the ring, the steps, the line paused on and the
  kept size.
- **M6, a simulated week on metal-vmm,** with the planted bad tasks.
- **The external checker** (Steve: the watchdog's death detected from
  outside) goes beside angry-gopher's `deploy/watchdog.py`, with its
  tests beside `test_watchdog.py`. It alarms on a stale verdict (no new
  slice in two periods), any state but running, the route missing or
  failing, or under two days of lifetime left. "No news" is never ok.

## What I'd build next, if asked

Section 1's `vm.Task` and its sliced-equals-uncut test: host-free, small,
and the piece every later milestone stands on. No host or kernel change
until the box has seen it.
