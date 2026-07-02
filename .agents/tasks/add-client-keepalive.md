# Task: Add CLIENT_KEEPALIVE heartbeat to client library

## Context

The driver conductor (`src/driver/conductor.zig`) handles `CMD_CLIENT_KEEPALIVE` (command ID 0x06) and evicts clients after 5 seconds of no keepalive. The client library (`src/aeron.zig`) never sends keepalives — it relies on implicit IPC activity.

## What to do

1. Read `src/aeron.zig` — understand the client struct and its duty cycle / poll method
2. Read `src/driver/conductor.zig` lines 733-748 (`handleClientKeepalive`) — understand expected message format
3. Add `last_keepalive_ms: i64 = 0` field to the Aeron client struct
4. Add constant `KEEPALIVE_INTERVAL_MS: i64 = 1_000` (1s, well within 5s driver timeout)
5. Add `sendKeepaliveIfDue()` method that:
   - Checks elapsed time since last keepalive
   - Writes `CMD_CLIENT_KEEPALIVE` to the to-driver ring buffer (match existing command write patterns)
6. Call `sendKeepaliveIfDue()` from the client's duty cycle / poll / doWork method

## Files to modify

- `src/aeron.zig`

## Success criteria

- `make check` passes
- Client sends keepalive every ~1s during idle periods
