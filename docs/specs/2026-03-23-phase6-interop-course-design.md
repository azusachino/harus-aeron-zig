# Phase 6 — Wire Compatibility + Course Quality

**Date**: 2026-03-23
**Status**: Approved
**Audit basis**: `docs/audit-2026-03-23.md`

---

## Goal

Bring `harus-aeron-zig` to full wire compatibility with the Java Aeron driver, and simultaneously
build a dual-track course where every module has both a Zig systems programming annotation and
an Aeron protocol concept annotation. Both tracks converge at three milestones.

---

## Approach: Two Independent Lanes + Merge Milestones

The interop lane and course lane run as separate sequential sub-agent sequences. They share
milestone gates where both lanes must be green (all tests pass, `make check` clean) before either
lane advances to the next milestone.

```
Interop lane:  I-1 → I-2 → I-3 → I-4 → I-5 ─── [M1] ─── I-6 → I-7 → I-8 ─── [M2] ─── I-9 ─── [M3]
Course lane:   C-1 ──────────────────────────── [M1] ─── C-2 → C-3 → C-4 ─── [M2] ─── C-5 → C-6 → ... ─── [M3]
```

C-1 (gap audit, read-only) may run concurrently with I-1 since they touch different files.
All other tasks are sequential within their lane.

---

## Milestones

| Milestone | Description | Interop gate | Course gate |
|-----------|-------------|--------------|-------------|
| **M1** — Structural correctness | All known bugs fixed; Zig-only pub/sub unblocked | I-1 through I-5 pass `make check` | C-1 complete (gap report written) |
| **M2** — Zig-only driver working | End-to-end Zig pub/sub via CnC.dat; mmap log files on disk | I-6 through I-8 pass integration test | C-2 through C-4 written and reviewed |
| **M3** — Java interop | Java `Aeron.connect()` succeeds; cross-language pub/sub smoke test passes | I-9 passes (gated on `AERON_INTEROP=1`) | C-5 through C-9 written and reviewed |

A merge agent runs `make check` on the full tree at each milestone and updates `docs/plan-phase6.md`
before the next wave starts.

---

## Interop Lane Tasks

### I-1: Fix `publisher_limit` init
**Files**: `src/publication.zig`
**Problem**: `publisher_limit = 0` causes every `offer()` to return `.back_pressure`.
**Fix**: Initialise to `term_length`. Update when receiver window advances (flow control integration).
**Acceptance**: Unit test — `offer("hello")` returns `.ok`, not `.back_pressure`.

### I-2: Fix broadcast `HEADER_LENGTH` (12→8 bytes)
**Files**: `src/ipc/broadcast.zig`
**Problem**: Record header is 12 bytes; Agrona expects 8 (type i32 + length i32 only).
**Fix**: Remove reserved i32 field; update all offset arithmetic.
**Acceptance**: Unit test — transmit + receive roundtrip produces correct bytes.

### I-3: Fix `RttMeasurement` frame size (24→32 bytes)
**Files**: `src/protocol/frame.zig`
**Problem**: `receiver_id: i64` was omitted; upstream frame is 32 bytes.
**Fix**: Add `receiver_id: i64 align(4)` field; update comptime size assert to 32.
**Acceptance**: `comptime { std.debug.assert(@sizeOf(RttMeasurement) == 32); }` compiles.

### I-4: SETUP→Image creation path
**Files**: `src/driver/receiver.zig`, `src/driver/conductor.zig`
**Problem**: SETUP frames are silently discarded. No Image is created for incoming sessions.
**Fix**: On SETUP receipt, receiver enqueues a signal to conductor; conductor creates Image,
maps log buffer, sends STATUS reply back to sender.
**Acceptance**: Integration test — subscriber receives frames after sender sends SETUP.

### I-5: NAK timer coalescing
**Files**: `src/driver/receiver.zig`
**Problem**: NAKs sent immediately with hardcoded 4096-byte length.
**Fix**: Track gap start/length per Image; coalesce adjacent gaps; delay NAK by configurable
`nak_delay_ns` (default 1ms); compute exact gap length from received vs expected offset.
**Acceptance**: Unit test — two adjacent gaps produce one NAK covering both; no NAK sent
within delay window of initial gap detection.

### I-6: mmap-backed log buffers
**Files**: `src/logbuffer/log_buffer.zig`
**Problem**: Log buffers are heap-allocated; zero-copy path does not exist.
**Fix**: Replace `allocator.alloc` with `std.posix.mmap` backed by a file under `aeron.dir`.
File path: `<aeron.dir>/publications/<session_id>-<stream_id>.logbuffer`.
**Acceptance**: Integration test — log buffer file created on disk at expected path after publication created.

### I-7: `CnC.dat` file layout
**Files**: `src/driver/cnc.zig` (new), `src/driver/media_driver.zig`
**Problem**: No `CnC.dat` file; Java clients cannot discover the driver.
**Fix**: Implement `CncFile` struct with:
- Magic number (`0x5352444e` — "NRDS" LE) at offset 0
- Version at offset 4
- `to_driver_buffer_length`, `to_clients_buffer_length`, `counters_metadata_buffer_length`,
  `counters_values_buffer_length`, `client_liveness_timeout_ns` — all at defined offsets
- Padding to 4096 bytes
- Ring buffer immediately after header
- Broadcast buffer immediately after ring buffer

Create file at `<aeron.dir>/CnC.dat` during `MediaDriver.init()`.
**Acceptance**: File exists at expected path; first 4 bytes match magic number; ring buffer
capacity matches configured `to_driver_buffer_length`.

### I-8: `Aeron.doWork()` real conductor polling
**Files**: `src/aeron.zig`
**Problem**: `doWork()` returns 0; no ring buffer writes or broadcast reads happen.
**Fix**: On `Aeron.init()`, mmap `CnC.dat`; locate ring buffer and broadcast buffer by offset.
`doWork()` reads pending broadcast messages (publication ready, subscription ready, image ready,
error) and updates internal state. `addPublication()` / `addSubscription()` write commands to
ring buffer.
**Acceptance**: Integration test — Zig client calls `addPublication()`, driver creates log buffer
file; client `doWork()` receives `ON_PUBLICATION_READY`; `offer()` succeeds.

### I-9: Java interop smoke test
**Files**: `test/interop/` (new directory)
**Problem**: No cross-language test.
**Fix**: Docker Compose file with official `aeronmd` Java container + Zig driver container.
Two test cases (gated on env flag `AERON_INTEROP=1`):
1. Zig publishes 100 messages → Java `BasicSubscriber` receives all 100
2. Java `BasicPublisher` sends 100 messages → Zig subscribes, receives all 100
**Acceptance**: Both cases pass when `AERON_INTEROP=1`; test is skipped otherwise.

---

## Course Lane Tasks

### C-1: Audit `LESSON` comment gaps
**Files**: all `src/**/*.zig`, `docs/tutorial/`
**Output**: `docs/course/lesson-gap-report.md`
**Task**: Enumerate every module; for each, note: does it have `LESSON(...)` comments? Are there
dual annotations (Zig angle + Aeron angle)? Is there a corresponding tutorial chapter?
Produce a gap table: module × (has-zig-lesson, has-aeron-lesson, has-tutorial-chapter).

### C-2: Dual-annotate frame codec chapter
**Files**: `src/protocol/frame.zig`, `docs/tutorial/part/frame-codec.md`
**Zig angle**: `extern struct`, comptime size assertions, `align(4)` for packed C structs.
**Aeron angle**: wire frame layout rationale, `#pragma pack(4)` equivalence, FrameType enum values.
**Blocked by**: M1

### C-3: Dual-annotate logbuffer chapter
**Files**: `src/logbuffer/`, `docs/tutorial/part/logbuffer.md`
**Zig angle**: 3-partition design, `packTail` bit manipulation, `@cmpxchgStrong` CAS.
**Aeron angle**: zero-copy data path, term rotation, why 3 partitions.
**Blocked by**: M1

### C-4: Dual-annotate IPC chapter
**Files**: `src/ipc/`, `docs/tutorial/part/ipc.md`
**Zig angle**: lock-free ring buffer, `@atomicLoad`/`@atomicStore` memory ordering, broadcast cursor.
**Aeron angle**: client→driver command protocol, driver→client notification protocol, correlation IDs.
**Blocked by**: M1

### C-5: Write transport chapter
**Files**: `src/transport/`, `docs/tutorial/part/transport.md`
**Zig angle**: `std.posix` UDP API, non-blocking sockets, multicast group join.
**Aeron angle**: SETUP/STATUS handshake, NAK retransmit flow, unicast vs multicast channel URIs.
**Blocked by**: M2

### C-6: Write conductor + CnC chapter
**Files**: `src/driver/`, `docs/tutorial/part/conductor-cnc.md`
**Zig angle**: mmap file layout, `std.posix.mmap`, pointer arithmetic into mapped memory.
**Aeron angle**: CnC.dat format, how a client discovers the driver, resource lifecycle.
**Blocked by**: M2

### C-7: Annotate example apps
**Files**: `examples/*.zig`
**Task**: Add inline `// ZIG: ...` and `// AERON: ...` comments to every non-trivial line in
`basic_publisher.zig`, `basic_subscriber.zig`, `throughput.zig`, `cluster_demo.zig`.
Verify all examples compile (`make examples`).
**Blocked by**: M2

### C-8: Write interop chapter
**Files**: `docs/tutorial/part/interop.md`
**Content**: Java↔Zig handshake walkthrough step by step; SBE note for archive (why archive
protocol is not yet wire-compatible); known remaining gaps.
**Blocked by**: M3

### C-9: Write course index + reading paths
**Files**: `docs/tutorial/README.md`
**Content**: Two reading tracks:
- "I'm learning Zig" — start from frame.zig, follow Zig annotations
- "I'm learning Aeron" — start from architecture.md, follow Aeron annotations
Module dependency map, estimated reading time per chapter.
**Blocked by**: M3

---

## Sub-Agent Execution Model

Each task is dispatched as a single sub-agent with:
- A focused prompt: exact files to touch, acceptance criteria, `make check` as the exit gate
- No shared mutable state between agents — each reads current repo state fresh
- Status tracked in `docs/plan-phase6.md` (one row per task, updated by the agent on completion)

**Agent prompt template**: `docs/agent-prompt-template.md`

---

## Files Created by This Plan

| File | Purpose |
|------|---------|
| `docs/audit-2026-03-23.md` | Full audit findings |
| `docs/specs/2026-03-23-phase6-interop-course-design.md` | This document |
| `docs/plan-phase6.md` | Execution tracking table |
| `docs/agent-prompt-template.md` | Reusable sub-agent prompt format |
| `docs/course/lesson-gap-report.md` | Output of C-1 |
| `docs/tutorial/part/*.md` | Tutorial chapters (C-2 through C-9) |
| `src/driver/cnc.zig` | CnC.dat implementation (I-7) |
| `test/interop/` | Java interop smoke tests (I-9) |
