# Wire Compatibility Audit — harus-aeron-zig

**Date**: 2026-03-23
**Auditor**: Claude Sonnet 4.6
**Scope**: Full codebase review against upstream Aeron Java/C reference

---

## Summary

The implementation is structurally sound — module layout, naming, and lock-free primitives all mirror the upstream design. However, several critical gaps prevent actual wire compatibility with the Java Aeron driver. The repo is not yet interoperable with `io.aeron.Aeron.connect()`.

**Status by phase:**

| Phase | Structural correctness | Wire compatible |
|-------|----------------------|-----------------|
| Phase 1 — Media Driver | Mostly correct (4 bugs) | No — CnC.dat missing |
| Phase 2 — Archive | Simplified (no SBE) | No |
| Phase 3 — Cluster | Simplified (no SBE) | No |
| Phase 4 — Observability | Correct | N/A |

---

## Critical Bugs (block all interop)

### B-1: `publisher_limit = 0` on init (`src/publication.zig`)

`ExclusivePublication.init()` sets `publisher_limit = 0`. The guard in `offer()` is:

```zig
if (current_position >= self.publisher_limit) return .back_pressure;
```

Since `current_position` starts at 0 and `0 >= 0` is true, **every offer returns `.back_pressure` immediately**. Publications are permanently blocked. `publisher_limit` should be initialised to `term_length` and updated as the receiver window advances.

### B-2: Broadcast `HEADER_LENGTH = 12` (`src/ipc/broadcast.zig`)

Agrona's `BroadcastTransmitter` record header is **8 bytes** (type: i32 + length: i32). This implementation uses 12 (adds an unused reserved i32). All byte offsets into the broadcast buffer are shifted by 4 bytes relative to what a Java receiver expects.

### B-3: `RttMeasurement` is 24 bytes, upstream is 32 (`src/protocol/frame.zig`)

The `receiver_id: i64` field was intentionally omitted with a comment. The upstream C header defines it, making the frame 32 bytes. A real Aeron peer sending an RTT frame will cause frame-type misdetection.

### B-4: No `CnC.dat` file (`src/driver/media_driver.zig`)

Java `Aeron.connect()` locates the driver by opening `<aeron.dir>/CnC.dat` — a memory-mapped file with a specific layout:
- version magic (i32)
- ring buffer length, broadcast buffer length, counters metadata/values lengths (i32 each)
- padding to cache-line boundary
- embedded client→driver ring buffer
- embedded driver→client broadcast buffer

Without this file, no Java client can connect to the Zig driver.

### B-5: `Aeron.doWork()` is a stub (`src/aeron.zig`)

```zig
pub fn doWork(_: *Aeron) i32 { return 0; }
```

No conductor polling, no ring buffer read, no broadcast receive. The client library does not connect to anything.

### B-6: Log buffers are heap-allocated, not mmap'd (`src/logbuffer/log_buffer.zig`)

Real Aeron creates log buffer files under `aeron.dir` and maps them into both driver and client address spaces. Without mmap-backed files, the zero-copy data path doesn't exist and a Java client cannot reach the log buffer.

---

## Secondary Bugs (affect correctness, not just interop)

### B-7: SETUP frame ignored in Receiver (`src/driver/receiver.zig`)

SETUP frames are received and discarded. Real Aeron creates an `Image` upon SETUP receipt and sends a `StatusMessage` reply to the sender. Without this, subscribers never receive data from external senders.

### B-8: NAK sends hardcoded 4096-byte length, no timer coalescing (`src/driver/receiver.zig`)

```zig
nak_header.length = 4096; // Request a chunk
```

Real Aeron coalesces adjacent gaps, delays NAKs (to avoid flooding the sender on transient loss), and computes the exact gap length. The current implementation would flood the sender on any packet loss.

---

## Archive / Cluster gaps (not wire-compatible with Java counterparts)

### G-1: Archive protocol uses plain structs, not SBE

Real `AeronArchive` control messages use Simple Binary Encoding (SBE). This implementation uses simplified Zig structs. A Java `AeronArchive` client cannot talk to the Zig archive.

### G-2: `handleListRecordings` has a no-op handler

```zig
pub fn handle(_: *const catalog_mod.RecordingDescriptorEntry) void {
    // Placeholder: in a real system, this would serialize the descriptor.
}
```

List recordings returns a count but does not serialize or deliver the descriptors.

### G-3: Archive replay reads in-memory buffer, not file

`handleReplay` sources data from `session.writer.buffer.items` (an `ArrayList`). Real recordings are file-backed; replay should mmap the recording file.

---

## What Is Correctly Implemented

| Component | Assessment |
|-----------|-----------|
| Frame codec (`extern struct`, `align(4)` on pack fields) | Correct |
| Log buffer 3-partition layout, `packTail`, `activePartitionIndex` | Correct |
| Term appender CAS tail advance | Correct |
| Term reader forward scan, padding skip | Correct |
| Ring buffer CAS, head/tail metadata offsets | Correct |
| UDP socket (unicast + multicast join/leave, non-blocking) | Correct |
| URI parser (endpoint, control, control-mode, term-length, session-id) | Correct |
| Flow control types (`OfferResult`, `back_pressure`, `not_connected`) | Correct structure |
| Counters map (atomic get/set/add/CAS) | Correct |
| Loss report, event log, counters report (Phase 4) | Correct |
| Raft election state machine (Phase 3) | Structurally correct |

---

## Educational Value Assessment

**Strengths:**
- `LESSON(...)` inline comments in `frame.zig` (e.g., `align(4)` / `#pragma pack(4)` equivalence)
- Module structure mirrors upstream Java package layout — cross-referencing is easy
- `examples/`, `tutorial/` compile-check target in `build.zig`
- Architecture doc covers all layers with a dependency graph

**Gaps:**
- B-1 (`publisher_limit = 0`) means `basic_publisher.zig` always stalls — confusing first run
- No `CnC.dat` walkthrough — the most non-obvious part of Aeron
- No explanation of the mmap zero-copy data path — the most important performance property
- `LESSON` comments exist in frame.zig but are absent from logbuffer, IPC, transport, conductor
- No dual annotation (Zig systems angle vs Aeron protocol angle) for any module
- No course index or reading paths for different learner profiles

---

## Prioritised Fix List

| Priority | ID | Fix | Files |
|----------|-----|-----|-------|
| P0 | B-1 | `publisher_limit` init | `src/publication.zig` |
| P0 | B-2 | Broadcast header 12→8 bytes | `src/ipc/broadcast.zig` |
| P0 | B-3 | `RttMeasurement` 24→32 bytes | `src/protocol/frame.zig` |
| P0 | B-7 | SETUP→Image creation path | `src/driver/receiver.zig`, `src/driver/conductor.zig` |
| P1 | B-8 | NAK timer coalescing | `src/driver/receiver.zig` |
| P1 | B-6 | mmap log buffers | `src/logbuffer/log_buffer.zig` |
| P1 | B-4 | `CnC.dat` file layout | `src/driver/cnc.zig` (new), `src/driver/media_driver.zig` |
| P1 | B-5 | `Aeron.doWork()` real polling | `src/aeron.zig` |
| P2 | G-1 | SBE archive protocol | `src/archive/protocol.zig` |
| P2 | G-2 | List recordings serialization | `src/archive/conductor.zig` |
| P2 | G-3 | File-backed archive replay | `src/archive/replayer.zig` |
