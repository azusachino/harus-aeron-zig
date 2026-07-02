# Task: Idle Strategy

## Context

The driver and client currently use busy-spinning in their hot loops (`doWork`). This is CPU-intensive and unnecessary for idle periods. Real Aeron uses `IdleStrategy` to back off during idle.

## What to do

1. Create `src/ipc/idle_strategy.zig`.
2. Define `IdleStrategy` interface:
   - `idle(work_count: i32) void`
   - `reset() void`
3. Implement `BusySpinIdleStrategy` (just returns).
4. Implement `YieldingIdleStrategy` (calls `std.Thread.yield()`).
5. Implement `SleepingIdleStrategy` (calls `std.time.sleep(ns)`).
6. Implement `BackoffIdleStrategy`:
   - Spin for N cycles → Yield for M cycles → Sleep for T ns.
7. Integrate `IdleStrategy` into:
   - `MediaDriver` agent loops (Conductor, Sender, Receiver).
   - `Aeron` client `doWork` poll loop.
8. Use `BackoffIdleStrategy` by default for driver agents.

## Files to modify

- `src/ipc/idle_strategy.zig` (new)
- `src/driver/media_driver.zig`
- `src/aeron.zig`
- `src/main.zig` (to allow setting idle strategy via flags)

## Success criteria

- `make check` passes.
- CPU usage drops to ~0% when the driver is idle.
- `make bench` shows minimal latency impact for high-throughput cases (Backoff stays in spin mode).
