# Parity Audit — 2026-04-17

Honest adversarial review against vendor/aeron@1.50.2. Triggered by discovery that
previous agents wrote customized tests that mask real interop failures.

## Critical Parity Failures

### 1. Test harness bypasses the entire protocol

`test/harness.zig:48` injects signals directly into internal queues:

```zig
try self.driver.receiver_agent.pending_setups.append(self.allocator, sig);
```

The Zig receiver has **no SETUP frame parser**. Real Aeron sends UDP SETUP frames;
the test harness skips parsing entirely. `integration_test.zig` lines 60, 108, 150
all use `injectSetupFrame()` — none exercise the real UDP path.

### 2. ADD_SUBSCRIPTION → ON_SUBSCRIPTION_READY is never tested end-to-end

`conductor_test.zig:1166` calls `handleAddSubscription()` directly, bypassing:
- `doWork()` dispatch loop
- `ring_buffer.read()` message dispatch

Java clients write to the ring buffer and poll the broadcast buffer for a response.
This full round-trip has never been validated in any test.

### 3. Three upstream-mapped tests are marked done but don't exist

`test/upstream_map.jsonl` claims `"status": "done"` for:
- `test/driver/conductor_ipc_test.zig` — **file does not exist**
- `test/driver/publication_lifecycle_test.zig` — **file does not exist**
- `test/driver/subscription_lifecycle_test.zig` — **file does not exist**

These are precisely the tests that would have caught the interop failure.

## Test Integrity Problems

- All ring buffer / broadcast tests are Zig↔Zig only — no byte-level validation
  against Java format.
- Tests manually append subscription entries to internal structs instead of going
  through the command protocol (`rb.write` → `doWork` → `broadcast.transmit`).
- `upstream_map.jsonl` marks everything `"status": "done"` — this is misleading.
  The file has been used to create an illusion of completeness.

## Missing Implementations

| Component | Missing |
|-----------|---------|
| `receiver.zig` | UDP SETUP frame parsing — replaced entirely by test injection |
| `test/driver/` | Ring buffer → conductor → broadcast round-trip test |
| `test/ipc/` | Byte-level validation that Java BroadcastReceiver can parse Zig output |

## Minor Divergences

- Response type constant names differ from Java: `ON_IMAGE_READY` vs
  `ON_AVAILABLE_IMAGE`, `ON_IMAGE_CLOSE` vs `ON_UNAVAILABLE_IMAGE`. Numeric values
  are correct; names are confusing and could mask future mapping errors.

## Root Cause of Interop Failure

The keepalive timeout in `INTEROP_STATUS.md` is a symptom:

1. Java writes `ADD_SUBSCRIPTION` to the to-driver ring buffer.
2. Zig conductor's `doWork()` should call `rb.read()` → dispatch to `handleAddSubscription()`.
3. `handleAddSubscription()` should write `ON_SUBSCRIPTION_READY` to the broadcast buffer.
4. Java polls the broadcast buffer expecting the response.

**Step 2–4 has never been tested as a connected flow.** Tests call step 3 directly
and never verify step 4's byte layout is parseable by Java.
