# Aeron-Zig Parity Audit v2

Date: 2026-03-30

## Overall Assessment

The project has a **real, functioning media driver** that passes Zig↔Java interop smoke tests. The core data path works end-to-end: ADD_PUBLICATION → SETUP → Image → DATA → STATUS flow-control → subscriber reads. Archive and Cluster have real protocol codecs and state machines but are not wired to live Aeron I/O.

**Estimated completeness: ~35% of upstream Aeron feature surface.**

---

## Subsystem Scorecards

### Media Driver — 60% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `media_driver.zig` | 449 | Real orchestration, 3-thread model | 70% |
| `conductor.zig` | 1,402 | 8 commands handled, ref-counting fixed | 55% |
| `sender.zig` | 637 | Real UDP sendto, SETUP, retransmit | 60% |
| `receiver.zig` | 853 | Real recvfrom, frame dispatch, NAK, Image | 60% |
| `cnc.zig` | 274 | Correct layout, real mmap | 85% |

**Key bugs:**
- `sendError` (conductor:852) silently drops error message body — clients get malformed error
- `handleRemoveCounter` never sends `ON_OPERATION_SUCCESS` back
- `Image.onRemoveSubscription` leaks HWM/sub-pos counters
- `MediaDriver.init()` deprecated but returns dangling stack pointers
- Hard-coded term_length (64KB), initial_term_id (0), fallback dest_address (127.0.0.1:40124)

**Missing features:**
- No exclusive publication command (`CMD_ADD_EXCLUSIVE_PUBLICATION`)
- No IPC channel support
- No flow control strategy (only implicit unicast)
- No heartbeat DATA frames from sender
- No image liveness / publication connection timeout
- No idle strategy (busy-spin only)
- No `DistinctErrorLog` (error log section allocated but never written)
- No `SystemCounters` (driver-level metrics)
- No inter-agent command queue (conductor directly locks receiver mutex)
- Single receive endpoint per driver

### IPC / Foundation — 50% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `ring_buffer.zig` | 369 | Functional but CAS ordering bug | 45% |
| `broadcast.zig` | 481 | Core transmit/receive works | 65% |
| `counters.zig` | 386 | Alloc/free/get/set works | 55% |

**Critical bugs:**
- **Ring buffer CAS ordering inverted** — concurrent writers can corrupt padding records (write-side CAS-then-wrap order wrong vs Agrona)
- **Counter RECORD_ALLOCATED** uses plain write, not store-release — metadata invisible to other cores
- No `MAX_MESSAGE_LENGTH` validation in ring buffer
- No consumer heartbeat / `checkUnblockedCommand`

### Log Buffer — 45% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `log_buffer.zig` | 240 | Real mmap create/open | 60% |
| `metadata.zig` | 129 | Core fields with proper atomics | 55% |
| `term_appender.zig` | 274 | **raw_tail is instance-local, not shared mmap** | 30% |
| `term_reader.zig` | 325 | Core scan works, missing acquire load | 40% |

**Critical bugs:**
- **`term_appender.zig` raw_tail is instance-local** instead of pointing into shared mmap metadata — multiple processes won't see each other's tail advances
- **frame_length commit is plain store**, not store-release — paired with reader's acquire load, this is a memory ordering bug
- **`term_reader.zig` frame_length read is plain load**, not acquire — stale data on ARM
- appendData writes aligned length to frame_length (should be unaligned per upstream)
- No fragmented message support (appendUnfragmented only)
- Missing `compareAndSetActiveTermCount` for atomic term rotation

### Protocol — 95% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `frame.zig` | 388 | All 13 frame types, comptime assertions | 95% |

**Minor gaps:**
- `ResolutionEntry` missing comptime size assertion
- `HEADER_LENGTH = 16` hardcoded (struct is 12 bytes) — potential wire mismatch

### Transport — 65% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `endpoint.zig` | 154 | Real sockets, multicast join | 70% |
| `uri.zig` | 518 | 18 params parsed | 60% |

**Gaps:**
- `IP_MULTICAST_TTL` and `IP_MULTICAST_IF` not applied to send socket
- `SO_SNDBUF`/`SO_RCVBUF` parsed but not applied
- 7+ URI params parsed but not propagated to `UdpChannel` struct

### Client Library — 40% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `aeron.zig` | 474 | Real IPC via cnc.dat | 45% |
| `publication.zig` | 207 | ExclusivePublication only | 35% |
| `subscription.zig` | 108 | Basic poll | 40% |

**Key gaps:**
- No `Publication` (concurrent/shared) type — only `ExclusivePublication`
- No `addExclusivePublication` distinct command
- `close()` doesn't send REMOVE commands to driver
- No fragment assembler
- `doWork` doesn't handle `ON_ERROR`, `ON_COUNTER_READY`, `ON_UNAVAILABLE_IMAGE`
- `initial_term_id` hardcoded to 0

### Archive — 30% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `archive.zig` | 421 | Protocol codecs | 40% |
| `catalog.zig` | 648 | Real file I/O, O(n) lookup | 50% |
| `conductor.zig` | 1,229 | Full command dispatch | 35% |
| `recorder.zig` | 852 | Real segment files | 40% |
| `replayer.zig` | 781 | Reads files, **doesn't publish** | 15% |

**Key gaps:**
- Replay does not call `Publication.offer()` — confirmed stub comment in code
- No live Aeron subscription wiring for recorder
- No `AeronArchive` client proxy
- No `RecordingSignal` / `RecordingPos` counter
- No replication
- Catalog is O(n) linear scan, full rewrite on every mutation

### Cluster — 20% complete

| Component | Lines | Status | Score |
|-----------|-------|--------|-------|
| `cluster.zig` | 708 | Election + embedded tests | 30% |
| `conductor.zig` | 952 | In-process command dispatch | 20% |
| `election.zig` | 565 | State machine, no real replication | 25% |
| `log.zig` | 620 | In-memory log entries | 15% |
| `protocol.zig` | 354 | All 12 message types | 90% |

**Key gaps:**
- **All consensus messaging is in-process** — no real Aeron Publications/Subscriptions
- `leader_log_replication` is a no-op skip-through
- Snapshot is a boolean flag only — no data persistence
- No `ClusteredService` interface / `ClusteredServiceAgent`
- No `ClusterMarkFile` / `RecordingLog`
- No `TimerService`
- `test/cluster/failover_test.zig` and `log_replication_test.zig` reference non-existent APIs — won't compile

### Tools — 80% complete

| Tool | Status |
|------|--------|
| `stat.zig` | Real — live CnC counter display |
| `streams.zig` | Real — counter grouping by session/stream |
| `events.zig` | Real — event log decoder |
| `loss.zig` | Real — loss report reader |
| `errors.zig` | Real — error log reader |
| `cluster_tool.zig` | **Stub** — prints "not yet fully integrated" |

### Tests & Benchmarks

- **Unit tests**: 319+ passing, good coverage of driver/protocol/IPC
- **Integration tests**: pub/sub, flow control, error injection
- **Cluster tests**: `test/cluster/failover_test.zig` and `log_replication_test.zig` **broken** (reference non-existent APIs)
- **Interop**: 5 Java scenarios (InteropSmoke, CountersChecker, MultiStream, ExclusivePub, Reconnect)
- **Benchmarks**: throughput, latency (HDR histogram), fanout — all real

---

## Priority Roadmap

### P0 — Correctness (blocks all interop confidence)

1. **Fix ring buffer CAS ordering** — concurrent writer corruption
2. **Fix term_appender raw_tail** — must point into shared mmap, not instance-local
3. **Fix term_appender/reader memory ordering** — store-release for commit, acquire for read
4. **Fix counter RECORD_ALLOCATED** — use atomic store-release
5. **Fix sendError** — transmit the error body, not just header
6. **Fix counter leak** on subscription removal

### P1 — Driver Feature Parity (v1.0 gate)

7. Add `CMD_ADD_EXCLUSIVE_PUBLICATION` support
8. Add shared `Publication` type (concurrent, ref-counted)
9. IPC channel support
10. Heartbeat DATA frames from sender
11. Image liveness / publication connection timeout
12. Flow control strategy (min multicast, unicast)
13. Apply URI socket options (SO_SNDBUF/RCVBUF, TTL, multicast IF)
14. `DistinctErrorLog` and `SystemCounters`
15. Idle strategy (not busy-spin)
16. Client `close()` sends REMOVE commands

### P2 — Archive Live Wiring

17. Wire recorder to real Aeron subscription
18. Wire replayer to real Aeron publication (`offer()`)
19. `AeronArchive` client proxy
20. O(1) catalog lookup
21. `RecordingSignal` / `RecordingPos` counter

### P3 — Cluster Live Wiring

22. Wire consensus messages to real Aeron publications
23. Implement `leader_log_replication` phase
24. Snapshot persistence via Archive
25. `ClusteredService` interface
26. `ClusterMarkFile` / `RecordingLog`
27. Fix broken cluster test files
