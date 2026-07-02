## Context

The repo just bumped Zig from 0.15.2 to 0.16.0 (flake.nix/flake.lock). `make check` now fails
with std API drift and error-set mismatches. You own ONLY these files — do NOT touch any other
file (another agent owns idle_strategy/log_buffer/catalog/bench/net.zig):

- src/driver/sender.zig
- src/driver/receiver.zig
- src/driver/conductor.zig
- src/transport/endpoint.zig (only touch if strictly needed to fix the error sets described below)

Do NOT guess the 0.16.0 API from memory. Consult the actual Zig 0.16.0 std library source at
/nix/store/4011jw1w9cx2l4qcmml0lmm9jr83l7pi-zig-0.16.0/lib/zig/std/ before making changes
(relevant files: Thread/Mutex.zig, array_list.zig, Io/net.zig or the posix socket send path).
Match the surrounding code style. Make minimal, behavior-preserving changes only.

## Tasks

1. Fix `src/driver/conductor.zig` around lines ~206 and ~894: compile error `'lock' is not
   marked 'pub'`. Something is accessing a `.lock` field/member on a Mutex-like type that isn't
   public in 0.16.0. Inspect the actual type being locked (read the surrounding code to find the
   declaration/import) and check std's Thread/Mutex.zig in 0.16.0 for the correct public API
   (e.g. `.lock()` method vs a field). Fix the call sites to use the correct 0.16.0 API rather
   than reaching into a private field.

2. Fix `src/driver/receiver.zig` around line ~210: compile error `missing struct field: items`.
   This is very likely an ArrayList literal/initialization that assumed the 0.15.x managed
   ArrayList shape. In 0.16.0, `std.ArrayList` is unmanaged by default (no `.allocator` field,
   init via `.{}` or `.empty`, methods take an explicit allocator argument). Check std's
   array_list.zig in 0.16.0 for the exact unmanaged API and update the initialization and any
   affected method calls (append, deinit, etc.) in receiver.zig to match, without changing
   behavior.

3. Fix the error-set mismatches:
   - `src/driver/receiver.zig` line ~422
   - `src/driver/sender.zig` lines ~170, ~206, ~255, ~337
   Error: `expected type '...error_set', found 'error{WouldBlock}'`.
   This stems from `SendChannelEndpoint.send` (in src/transport/endpoint.zig) and
   `Receiver.sendStatus`'s error sets no longer including `WouldBlock` because the underlying
   0.16.0 socket send API's error set changed shape. Inspect the actual UDP/socket send path
   used in transport/endpoint.zig and cross-reference the 0.16.0 std source (Io/net.zig or the
   posix send wrapper) to see what error `WouldBlock` now surfaces as. Then either:
   (a) update the function's declared error set (e.g. on `SendChannelEndpoint.send` and/or
       `Receiver.sendStatus`) to properly include/propagate `WouldBlock`, or
   (b) update the error name/mapping if 0.16.0 renamed it,
   such that callers can still treat it as a transient, non-fatal condition (must NOT be
   swallowed or turned into a hard error — preserve existing retry/backoff behavior).

## Verification

Run this and confirm none of your owned files produce errors anymore (errors in other files
like idle_strategy/log_buffer/catalog/bench/net.zig are owned by another agent and expected):

```
cd /Users/yinchun.pang/Projects/project-github/harus-aeron-zig && zig build 2>&1 | grep -E "sender|receiver|conductor|endpoint" || true
```

## Done when
- No compile errors reference src/driver/sender.zig, src/driver/receiver.zig,
  src/driver/conductor.zig, or src/transport/endpoint.zig
- No files outside the owned list were modified
- WouldBlock is still handled as a transient condition (not swallowed, not a hard error)
- Report exactly what changed and why for each of the 3 issues above
