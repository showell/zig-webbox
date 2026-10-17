#!/bin/sh
# **SHALE-GATE'S WRAPPER** (metal-vmm QUEUE 233, chunk 5): what the
# PreToolUse hook on Bash and Monitor runs. It runs `shale-gate` (built by
# `zig build` into zig-out/bin, or the one SHALE_GATE names) on the hook's
# JSON, and turns anything but its pass (0) or its refusal (2) into a
# refusal: a missing or broken binary refuses, it never passes.
bin="${SHALE_GATE:-$(dirname "$0")/../zig-out/bin/shale-gate}"
"$bin"
rc=$?
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -eq 2 ] && exit 2
echo "shale-gate: $bin failed (exit $rc), so the call is refused" >&2
exit 2
