# Interop Smoke Test — Status

Goal: `make interop-smoke` passes (Zig driver ↔ Java client, real UDP path, 10 messages).

## Current Status: PASSING ✅ (2026-07-03)

`make interop-smoke` against `aeron@1.50.4` completes with both containers exiting `0`:

```
java-client-1  | Phase 2: OK
java-client-1  | Reconnect OK
java-client-1  | [CLIENT] ReconnectSmoke passed
java-client-1  | [CLIENT] All checks passed
java-client-1 exited with code 0
zig-driver-1  exited with code 0
```

The Java client drives the full wire path through the Zig driver: `ADD_SUBSCRIPTION`
→ `ON_SUBSCRIPTION_READY` round-trip via the ring buffer / broadcast buffer, real UDP
`SETUP` frame parsing, `DATA` frame reassembly, and `STATUS` message replies — plus a
reconnect cycle.

## History

Previously **BLOCKED — keepalive timeout**: the Java client wrote `ADD_SUBSCRIPTION`
to the to-driver ring buffer and never received `ON_SUBSCRIPTION_READY` on the
broadcast buffer, so `ClientConductor.checkLiveness` tripped a
`DriverTimeoutException` after 10s. The 2026-04-17 parity audit traced the root cause
to the receiver having no real SETUP-frame parser and the ring-buffer → conductor →
broadcast round-trip never being exercised (tests injected signals directly into
internal queues).

Closed by PR #30 (`35885e4`), which added the `receiver.zig` SETUP frame parser plus
the connected round-trip tests (`test/driver/{setup_frame_parse,conductor_ipc,
subscription_lifecycle,publication_lifecycle}_test.zig`).

## How to Run Locally

```bash
colima start            # or start any Docker-compatible daemon
make interop-smoke      # 10 messages, CI-friendly
make interop            # full suite, 100 messages, all scenarios
```
