# Design: a background run's output, streamed (proposed)

**Parked** (metal-vmm QUEUE, "Parked": "216's output ring and SSE stream",
Steve, 2026-10-16: revisit when a script needs to report as it runs).
Today `GET /admin/script` shows a background run's output after it ends.
This is what was proposed, kept from the old SHALE-TASKS.md (its other
sections are built and described in SHALE.md, "The contract: a run as a
host sees it" and "The VM").

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
