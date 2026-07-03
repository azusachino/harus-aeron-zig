# Plan: Agrona Module Extraction + Interop Fix

Date: 2026-04-17  
Branch target: `fix/agrona-module-interop`  
Goal: unblock `make interop-smoke` by fixing the IPC protocol round-trip, with
Agrona primitives extracted into a proper module along the way.

## Context

The interop smoke test is blocked because the ADD_SUBSCRIPTION → ON_SUBSCRIPTION_READY
round-trip has never been tested as a connected flow. Tests have been calling handlers
directly, bypassing `doWork()` and `ring_buffer.read()`. The test harness also injects
SETUP signals directly into internal queues instead of parsing real SETUP frames.

See: `docs/audits/2026-04-17-parity-audit.md` for the full audit.

---

## Phase 1 — Extract Agrona Module

**Goal**: Move IPC primitives into `lib/agrona/`, wire as a named module in `build.zig`.
All existing tests must still pass after this phase.

### Steps

1. Create `lib/agrona/` with `root.zig`, re-exporting all public types.
2. Move (not copy) these files:
   - `src/ipc/ring_buffer.zig` → `lib/agrona/ring_buffer.zig`
   - `src/ipc/broadcast.zig`   → `lib/agrona/broadcast.zig`
   - `src/ipc/counters.zig`    → `lib/agrona/counters.zig`
   - `src/ipc/idle_strategy.zig` → `lib/agrona/idle_strategy.zig`
3. Update `src/ipc.zig` (or wherever these are re-exported) to `@import("agrona")`.
4. In `build.zig`:
   - Add `const agrona_mod = b.addModule("agrona", .{ .root_source_file = b.path("lib/agrona/root.zig") })`.
   - Add `agrona` import to `aeron_mod`, driver exe, and all test steps that need it.
   - Add a dedicated `test-agrona` step rooted at `lib/agrona/root.zig`.
5. `make check` passes.

### Acceptance

- `make test-agrona` runs and all existing ring buffer / broadcast tests pass.
- `make check` green.

---

## Phase 2 — Byte-Level Agrona Parity Tests

**Goal**: Validate that the Zig byte layout matches what Java/C Agrona produces.
Current tests are Zig↔Zig only — no byte-level format verification.

### Tests to add in `lib/agrona/`

#### ring_buffer — byte layout

Cross-reference: `vendor/aeron/aeron-client/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java`

- `test "java-compat: ADD_SUBSCRIPTION record layout"` — write type 0x04 with a known
  payload, assert exact bytes at offset 0 (length), 4 (type), 8..N (payload). Must
  match what Java writes.
- `test "java-compat: metadata offsets match agrona trailer"` — assert
  `TAIL_POSITION_OFFSET`, `HEAD_CACHE_POSITION_OFFSET`, `HEAD_POSITION_OFFSET`,
  `CONSUMER_HEARTBEAT_OFFSET`, `METADATA_LENGTH` against Java constants.
- `test "java-compat: padding record layout"` — trigger wrap, assert padding record
  has `length` then `type=-1` at correct offsets.

#### broadcast — byte layout

Cross-reference: `vendor/aeron/aeron-client/src/main/c/concurrent/aeron_broadcast_transmitter.h`

- `test "java-compat: transmit record header layout"` — transmit type 0x0F07 with
  12-byte payload, assert bytes: `length (i32) @ recordOffset`, `type (i32) @ recordOffset+4`,
  `payload @ recordOffset+8`, tail counter at `capacity`.
- `test "java-compat: ON_SUBSCRIPTION_READY payload layout"` — write a 12-byte
  `SubscriptionReadyFlyweight` (correlation_id i64 @ 0, channel_status_indicator_id i32 @ 8),
  assert exact bytes, assert Java receiver would parse it correctly.
- `test "java-compat: TRAILER_LENGTH == 128"` — constant check.

### Acceptance

All new byte-layout tests pass. No test may use `@import("aeron")` internal structs —
only raw byte assertions against known offsets.

---

## Phase 3 — Fix the Conductor Round-Trip

**Goal**: Write a real end-to-end test for the ADD_SUBSCRIPTION → ON_SUBSCRIPTION_READY
flow and fix any bugs found along the way.

### Test to write: `test/driver/conductor_ipc_test.zig`

This is the file mapped in `upstream_map.jsonl` that does not exist. It must:

1. Allocate a shared CNC-layout buffer (to-driver ring buffer + to-clients broadcast).
2. Write an `ADD_SUBSCRIPTION` command (type 0x04) directly to the ring buffer bytes —
   NOT via `handleAddSubscription()` directly.
3. Call `conductor.doWork()` once.
4. Read the to-clients broadcast buffer and verify:
   - A record with type `0x0F07` (ON_SUBSCRIPTION_READY) is present.
   - `correlation_id` (i64 @ 0) matches what was written.
   - `channel_status_indicator_id` (i32 @ 8) is non-negative.

### Likely bugs to fix

- Verify `conductor.zig` `handleCommand()` correctly dispatches type `0x04` via
  `ring_buffer.read()` (not just in the direct-call path).
- Verify `BroadcastTransmitter.transmit()` is called with the correct type and payload.
- Verify `doWork()` calls `rb.read()` with a non-zero limit.

### Acceptance

`make test-driver` passes with `conductor_ipc_test.zig` included.

---

## Phase 4 — Fix SETUP Frame Parsing in Receiver

**Goal**: Replace test injection with real UDP SETUP frame parsing.

### Current state

`test/harness.zig:48` injects `SetupSignal` directly:
```zig
try self.driver.receiver_agent.pending_setups.append(self.allocator, sig);
```

### What needs to exist

In `src/driver/receiver.zig`, a function that:
1. Accepts a raw UDP datagram buffer.
2. Reads the frame type field (offset 4, i16 little-endian).
3. If frame type == `0x05` (SETUP), parses `SetupFlyweight` fields into `SetupSignal`.
4. Appends to `pending_setups`.

Cross-reference: `vendor/aeron/aeron-client/src/main/java/io/aeron/protocol/SetupFlyweight.java`

### Field offsets for SetupFlyweight

| Field | Offset | Type |
|-------|--------|------|
| frame_length | 0 | i32 |
| version + flags + type | 4 | packed (type=i16 @ 6) |
| term_offset | 8 | i32 |
| session_id | 12 | i32 |
| stream_id | 16 | i32 |
| initial_term_id | 20 | i32 |
| active_term_id | 24 | i32 |
| term_length | 28 | i32 |
| mtu_length | 32 | i32 |
| ttl | 36 | i32 |

### Test to add

`test/driver/setup_frame_parse_test.zig`:
- Build a raw SETUP frame byte buffer using known offsets.
- Call `receiver.parseSetupFrame(buf)`.
- Assert the returned `SetupSignal` fields match expected values.
- Assert an invalid frame type returns `error.NotSetupFrame`.

### Update `test/harness.zig`

After the parser is verified: change `injectSetupFrame()` to build a raw SETUP
frame and call the parser, rather than injecting directly. This makes integration
tests exercise the real parsing path.

### Acceptance

`make test-driver` includes setup parse tests and passes.  
`test/harness.zig` no longer bypasses parsing.

---

## Phase 5 — Fix upstream_map.jsonl Integrity

**Goal**: `upstream_map.jsonl` must reflect reality.

- Mark the three previously-missing tests as `"status": "done"` only after their
  files exist and pass.
- Add entries for new tests added in phases 3 and 4.
- Audit all other `"status": "done"` entries — if the test file doesn't exist or
  doesn't exercise the mapped Java behavior, change status to `"missing"` or
  `"partial"`.

---

## Sequence Summary

| Phase | Deliverable | Make target |
|-------|-------------|-------------|
| 1 | `lib/agrona/` module extracted | `make test-agrona` |
| 2 | Byte-layout parity tests | `make test-agrona` |
| 3 | `conductor_ipc_test.zig` + round-trip fix | `make test-driver` |
| 4 | SETUP frame parser + harness fix | `make test-driver` |
| 5 | `upstream_map.jsonl` cleanup | — |

Run `make check` after each phase before moving to the next.

---

## Out of Scope

- Archive / cluster parity (separate audit needed)
- Real UDP loopback interop test (depends on phases 3–4 being done first)
- Zig-side publisher path — not blocking the ADD_SUBSCRIPTION issue
