# Phase 1 Batch 2 — Driver Feature Parity Plan

Date: 2026-03-30

**Goal:** close the remaining P1 parity gaps to reach a feature-complete v1.0 media driver.

**Priority:**
1. Image liveness & Flow control (highest priority for interop stability)
2. Idle strategy (performance and resource hygiene)
3. Shared Publication type & IPC support (API surface completion)
4. DistinctErrorLog & SystemCounters (observability)

---

## Task P1-8: Shared Publication Type

**Files:** `src/publication.zig`, `src/aeron.zig`

- [ ] Implement `Publication` (concurrent/shared) type with internal reference counting.
- [ ] Multiple threads can hold the same `Publication` (unlike `ExclusivePublication`).
- [ ] Use `std.atomic.Value` for ref-counting and shared tail pointers if needed.
- [ ] Client `addPublication` should return the shared `Publication` type.

## Task P1-9: IPC Channel Support

**Files:** `src/driver/conductor.zig`, `src/driver/media_driver.zig`, `src/transport/udp_channel.zig`

- [ ] Support `aeron:ipc` URI in `UdpChannel` and `Conductor`.
- [ ] IPC publications bypass the `Sender` and `Receiver` — data flows directly through shared log buffers.
- [ ] Conductor handles IPC command routing and resource mapping.

## Task P1-11: Image Liveness & Publication Timeout

**Files:** `src/driver/receiver.zig`, `src/driver/sender.zig`, `src/driver/conductor.zig`

- [ ] Implement `ReceiverLivenessTracker` (or similar) to detect stale images.
- [ ] Image is closed if no DATA/SETUP seen within `image_liveness_timeout_ns`.
- [ ] Publication is considered disconnected if no STATUS seen within `publication_connection_timeout_ns`.
- [ ] Emit `ON_UNAVAILABLE_IMAGE` to clients when an image times out.

## Task P1-12: Flow Control Strategy

**Files:** `src/driver/flow_control.zig` (new), `src/driver/sender.zig`

- [ ] Implement `FlowControl` interface.
- [ ] Implement `UnicastFlowControl` (default for unicast).
- [ ] Implement `MinMulticastFlowControl` (default for multicast).
- [ ] Sender uses flow control to calculate `publisherLimit` based on receiver window feedback.
- [ ] Support `max_window` and `receiver_tag` if needed for parity.

## Task P1-14: DistinctErrorLog & SystemCounters

**Files:** `src/driver/media_driver.zig`, `src/driver/conductor.zig`, `src/counters_report.zig`

- [ ] Allocate and write to the `DistinctErrorLog` section in CnC.
- [ ] Implement `SystemCounters` for driver-level metrics:
  - `BYTES_SENT`, `BYTES_RECEIVED`
  - `STATUS_MESSAGES_RECEIVED`, `NAK_MESSAGES_RECEIVED`
  - `HEARTBEATS_SENT`
  - `ERRORS`, `CLIENT_KEEP_ALIVE_COUNT`
- [ ] Expose these via `stat` tool.

## Task P1-15: Idle Strategy

**Files:** `src/ipc/idle_strategy.zig` (new), `src/main.zig`, `src/aeron.zig`

- [ ] Implement `IdleStrategy` interface.
- [ ] Implement `BusySpinIdleStrategy`.
- [ ] Implement `YieldingIdleStrategy`.
- [ ] Implement `SleepingIdleStrategy` (ms precision).
- [ ] Implement `BackoffIdleStrategy` (progressive spin → yield → sleep).
- [ ] Use idle strategies in conductor, sender, receiver, and client duty cycles.

---

## Execution Sequence

1. **Liveness & Flow Control** (Agent A) — critical for multi-process stability.
2. **Idle Strategy** (Agent B) — improves CPU efficiency and overall system responsiveness.
3. **Shared Publication & IPC** (Agent C) — completes the core API surface.
4. **Error Log & System Counters** (Agent D) — final polish and observability.

---

## Verification

- `make check`
- `make interop-smoke`
- `make test-integration` (all scenarios passing)
- `stat` tool shows real driver counters.
