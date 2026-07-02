## Tasks

Zig was just bumped from 0.15.2 to 0.16.0. `make check` now fails with std API drift.
Fix ONLY the following files — do NOT touch any other file (another agent owns the driver files and will fix those separately):

1. `src/ipc/idle_strategy.zig` — around lines ~73 and ~132: `std.Thread.sleep(...)` no longer exists on `std.Thread` in Zig 0.16.0. Find the correct 0.16.0 replacement for sleeping N nanoseconds and use it in both call sites.
2. `src/logbuffer/log_buffer.zig` — around line ~65: `std.fs.createFileAbsolute(path, ...)` no longer exists in Zig 0.16.0. Find the correct replacement API and use it, preserving the same flags/behavior.
3. `src/archive/catalog.zig` — around line ~87: `std.fs.cwd()` is no longer a member of `std.fs` in Zig 0.16.0. Find the correct replacement.
4. `src/bench/fanout.zig` — around line ~83: `std.time.Timer` no longer exists under `std.time` in Zig 0.16.0. Find the correct replacement type/namespace and update usage (start/read/lap semantics should be preserved).
5. `src/bench/throughput.zig` — around line ~122: same `std.time.Timer` issue as above — same fix.
6. `src/net.zig` — around line ~74: code references `ip6.flowinfo`, but `Io.net.Ip6Address` (or whatever the 0.16.0 equivalent struct is) has no `flowinfo` field in 0.16.0. Inspect the actual struct definition and fix the code to match (either use the correct field name, or remove/adjust the logic if the field genuinely no longer exists — preserve behavior as closely as possible and leave a short comment if something had to be dropped).

CRITICAL — do not guess the 0.16.0 API from memory or training data. Consult the actual Zig 0.16.0 standard library source, which is vendored/available at:
- `/nix/store/4011jw1w9cx2l4qcmml0lmm9jr83l7pi-zig-0.16.0/lib/zig/std/`
- Also check `vendor/zig` if present (a shallow clone of Zig 0.16.0 per this repo's setup).

Use `grep`/`rg` against those sources for the relevant symbols (e.g. `Thread.zig`, `fs.zig`, `Io/net.zig` or `net.zig`, `time.zig`) to find the exact current API before editing. Match the surrounding code style in each file. Keep changes minimal and behavior-preserving — this is a mechanical API-migration fix, not a refactor.

## Verification

Run this to confirm your specific errors are gone (errors from driver/*.zig files are owned by another agent and are expected to still be present — ignore them):

```
make build 2>&1 | grep -E "idle_strategy|log_buffer|catalog|fanout|throughput|net.zig"
```

This should print nothing (or only unrelated warnings) once your 6 files are fixed.

## Done when
- All 6 files above compile cleanly with no errors attributable to them
- No other files were modified
- Report exactly which 0.16.0 API replacement was used for each of the 6 fixes
