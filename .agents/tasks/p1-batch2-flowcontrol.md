# Task: Flow Control Strategy

## Context

The driver currently assumes infinite window for unicast (only implicit back-pressure via `back_pressure` error). Real Aeron uses a `FlowControl` interface to adjust `publisherLimit` based on receiver window feedback (STATUS messages).

## What to do

1. Create `src/driver/flow_control.zig`.
2. Define `FlowControl` interface (methods: `onStatusMessage`, `onIdle`, `initialize`).
3. Implement `UnicastFlowControl`:
   - Just takes the receiver window from the last STATUS message and updates `publisherLimit`.
4. Implement `MinMulticastFlowControl`:
   - Tracks multiple receivers.
   - `publisherLimit` is the minimum of all receiver positions (plus their windows).
5. Integrate `FlowControl` into `NetworkPublication` in `src/driver/sender.zig`.
6. When a STATUS frame arrives at the sender:
   - Pass it to the publication's flow control instance.
   - Flow control instance updates the `publisherLimit` counter in shared memory.

## Files to modify

- `src/driver/flow_control.zig` (new)
- `src/driver/sender.zig`
- `src/driver/conductor.zig` (to create flow control on publication add)

## Success criteria

- `make check` passes.
- Multicast sender respects the slowest subscriber (back-pressure propagates).
- `make interop-smoke` still passes.
