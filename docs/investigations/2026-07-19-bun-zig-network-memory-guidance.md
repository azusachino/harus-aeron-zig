# Bun Zig reference: memory and network guidance

Reference snapshot: `vendor/bun` at `bun-v1.2.23` (`cf1367137d`). Bun is a
reference corpus only; its runtime architecture and APIs are not Aeron API
requirements.

## Findings

### Memory ownership

- Use a stack-first allocation path for bounded hot-path work. Bun's
  `HTTPThread.RequestBodyBuffer` uses a 32 KiB stack fallback and reuses a
  512 KiB heap buffer for larger bodies (`src/http/HTTPThread.zig`).
- Use arenas for request-scoped graphs and temporary parse state, then release
  the whole arena at the scope boundary (`src/install/NetworkTask.zig`,
  `src/http/http.zig`).
- Reuse poll records and buffers instead of allocating per readiness event;
  Bun's `FilePoll` explicitly documents reuse because stale event generations
  must be handled safely (`src/async/posix_event_loop.zig`).
- Keep ownership visible in the type: every reusable heap buffer has an
  explicit `put`/`deinit` path, and stack-backed data is not freed.

### TCP and readiness

- Treat a successful socket write as partial progress, not completion. Bun's
  TCP echo example retains unwritten data and retries it from a `drain`
  callback (`bench/snippets/tcp-echo.bun.ts`).
- Make readiness one-shot and re-register interest after the callback. Bun's
  Linux loop uses `epoll_wait`, processes a bounded event array, and
  re-registers readable/writable polls (`src/io/io.zig`).
- Keep lifecycle separate from readiness: Bun tracks active handles with a
  small `KeepAlive` state machine (`src/async/posix_event_loop.zig`). Aeron
  should similarly distinguish socket liveness, publication flow control, and
  driver/client lifecycle.
- Keep platform branches explicit: epoll on Linux and kqueue on macOS, with
  compile-time guards rather than silently selecting incompatible behavior.

### UDP and burst handling

- Nonblocking mode and readiness are coupled. Bun marks descriptors
  nonblocking only when the descriptor is pollable and routes reads/writes
  through nonblocking syscall wrappers (`src/sys.zig`, `src/io/openForWriting.zig`).
- Batch receive is an optimization, not a correctness assumption. Bun exposes
  libuv's `recvmmsg` capability (`src/deps/libuv.zig`); Aeron must preserve
  packet ordering, loss detection, NAK generation, and retransmission whether
  one or many datagrams are received per poll.
- Socket monitoring is debug-gated and records complete read/write payloads
  only when enabled (`src/sql/postgres/SocketMonitor.zig`). Aeron diagnostics
  should remain opt-in and aggregate counters rather than print per packet in
  normal runs.

## Guidance for harus-aeron-zig

1. Add stack/fixed-buffer fast paths to cluster-client message construction;
   do not allocate and free the session envelope for every order.
2. Separate `doWork` maintenance from application pacing. A client loop must
   keep liveness and driver-control polling active without sleeping once per
   order, while still bounding in-flight egress and honoring flow control.
3. Model UDP receive progress as a bounded batch with explicit counters for
   packets, dropped packets, NAKs, retransmits, and egress fragments.
4. Preserve partial-write and backpressure state until the transport confirms
   progress; never treat a successful enqueue as remote delivery.
5. Add platform-specific poller tests and burst tests before changing socket
   buffer sizes or batching behavior. Every optimization needs a correctness
   test for loss, reorder, retry, and shutdown.
6. Keep `TRACE_PERF=1`-style diagnostics opt-in, aggregate timings, and make
   every benchmark report publish, egress, retry, loss, and timeout counts.

## Scope boundary

Bun's JavaScript-facing socket API, libuv compatibility layer, and HTTP event
loop are not direct substitutes for Aeron's media-driver protocol. The useful
transfer is the engineering discipline: explicit ownership, bounded reusable
storage, readiness-driven I/O, backpressure-aware writes, platform isolation,
and diagnostics that are cheap when disabled.
