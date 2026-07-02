# Task: Image Liveness & Publication Timeout

## Context

The driver currently keeps images and publications alive forever once created. Upstream Aeron tracks liveness based on frame activity (DATA/SETUP for images, STATUS for publications) and connection timeouts.

## What to do

1. Read `src/driver/receiver.zig` — understand `Image` struct and `doWork` poll loop.
2. Read `src/driver/sender.zig` — understand `NetworkPublication` and `doWork`.
3. Read `src/driver/conductor.zig` — understand how resources are tracked and closed.
4. Add `last_activity_ns: i64` to `Image` and `NetworkPublication`.
5. Update `last_activity_ns` when frames are received (for Image) or processed (for Publication).
6. In the conductor (or a dedicated tracker), periodically check for timed-out resources:
   - `IMAGE_LIVENESS_TIMEOUT_NS` (default 5s)
   - `PUBLICATION_CONNECTION_TIMEOUT_NS` (default 5s)
7. On timeout:
   - For Image: close it and notify client via `ON_UNAVAILABLE_IMAGE`.
   - For Publication: mark it as disconnected (log metadata `IS_CONNECTED = false`).
8. Ensure cleanup is safe (no double-free, mutex-guarded if shared).

## Files to modify

- `src/driver/receiver.zig`
- `src/driver/sender.zig`
- `src/driver/conductor.zig`
- `src/config.zig` (for timeout settings)

## Success criteria

- `make check` passes.
- Images are automatically removed if the sender stops sending for >5s.
- `make test-integration` with a "publisher disconnect" scenario passes (proves EOS/cleanup).
