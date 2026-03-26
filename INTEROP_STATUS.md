# Interop Smoke Test — Investigation Status

Branch: `feature/phase10-upstream-parity`
Goal: `make interop-smoke` passes (Zig driver ↔ Java BasicSubscriber receives 10 messages)

## Current Status: BLOCKED — keepalive timeout

```
DriverTimeoutException: FATAL - MediaDriver keepalive: age=10011ms > timeout=10000ms
  at ClientConductor.checkLiveness (ClientConductor.java:1601)
  at ClientConductor.awaitResponse (ClientConductor.java:1529)
  at ClientConductor.addSubscription (ClientConductor.java:661)
```

The Java client sends `ADD_SUBSCRIPTION` to the to-driver ring buffer, then waits up to
10 seconds for a response on the to-clients broadcast buffer. It never gets one → timeout.

## Root Cause Hypothesis

The driver is not processing `ADD_SUBSCRIPTION` commands from the ring buffer and not
writing a `ON_SUBSCRIPTION_READY` response to the to-clients broadcast buffer.

Specifically:
1. Java writes `ADD_SUBSCRIPTION` to the to-driver ring buffer (ManyToOneRingBuffer)
2. Our conductor calls `rb.read(handler, ...)` — should dispatch to `handleCommand()`
3. `handleCommand()` in `conductor.zig` must match type `ADD_SUBSCRIPTION = 0x04` and
   write `ON_SUBSCRIPTION_READY` (type 0x0F) to the to-clients broadcast buffer
4. The broadcast buffer is a `BroadcastTransmitter` — Java reads it via `BroadcastReceiver`

## Fixed This Session (commit f7be1ee)

| File | Fix |
|------|-----|
| `cnc.zig` | `CNC_VERSION` = 512 (0.2.0 format, not library version) |
| `cnc.zig` | `CNC_HEADER_SIZE` = 128 (not 4096) |
| `cnc.zig` | Added `error_log_buffer_length`, `start_timestamp_ms`, `driver_pid` fields |
| `cnc.zig` | Added `setDriverHeartbeat()` at CONSUMER_HEARTBEAT_OFFSET = data_capacity + 640 |
| `media_driver.zig` | Buffer sizes include Agrona trailers (+768, +128) |
| `media_driver.zig` | Write heartbeat on init + refresh each conductor tick |
| `ring_buffer.zig` | Fix record layout: length@0, type@4 (was swapped) |
| `ring_buffer.zig` | Add negative-sentinel commit protocol in write() |
| `ring_buffer.zig` | Atomic load for length in read() |
| `Makefile` | Scope `zig fmt` to `src/ build.zig` (avoids .zig-cache AccessDenied) |

## Next Steps

### 1. Verify ADD_SUBSCRIPTION is being read

Add a log line in `conductor.zig` `handleCommand()` to confirm the ring buffer dispatch
is reaching the right case. Check what msg_type_id values are arriving.

Java ADD_SUBSCRIPTION type: `ControlProtocolEvents.ADD_SUBSCRIPTION = 0x04`
(from `io.aeron.command.ControlProtocolEvents`)

### 2. Implement ON_SUBSCRIPTION_READY response

After processing ADD_SUBSCRIPTION, the conductor must write to the to-clients broadcast buffer:
- Response type: `ControlProtocolEvents.ON_SUBSCRIPTION_READY = 0x0F`
- Payload: `SubscriptionReadyFlyweight` — correlation_id (i64) + channel_status_indicator_id (i32)
- Write via `BroadcastTransmitter.transmit(type, buffer, offset, length)`

### 3. Verify BroadcastTransmitter layout

`src/ipc/broadcast.zig` — check transmit() writes Agrona BroadcastTransmitter format:
- Record header: length (i32) @ 0, type (i32) @ 4 (same as ring buffer)
- Tail counter at buffer end

### 4. Verify Java client can parse the response

Java `ClientConductor.onSubscriptionReady()` expects correlation_id matching
what it sent in ADD_SUBSCRIPTION. Check that correlation_id is echoed correctly.

## Key Source References

- Java command types: `io.aeron.command.ControlProtocolEvents`
- Java ADD_SUBSCRIPTION format: `io.aeron.command.SubscriptionMessageFlyweight`
- Java ON_SUBSCRIPTION_READY format: `io.aeron.command.SubscriptionReadyFlyweight`
- Agrona BroadcastTransmitter: `org.agrona.concurrent.broadcast.BroadcastTransmitter`
- Our conductor: `src/driver/conductor.zig`
- Our broadcast: `src/ipc/broadcast.zig`

## How to Run Interop Test Locally

```bash
# Build fresh image
AERON_VERSION=1.50.2 podman-compose -f deploy/docker-compose.ci.yml build --no-cache zig-driver

# Run with fresh volumes (stale cnc.dat causes false failures)
AERON_VERSION=1.50.2 podman-compose -f deploy/docker-compose.ci.yml down -v
AERON_VERSION=1.50.2 MSG_COUNT=10 podman-compose -f deploy/docker-compose.ci.yml up \
  --abort-on-container-exit --exit-code-from java-client
```
