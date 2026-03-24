# LESSON Comment Gap Report

**Date**: 2026-03-23
**Scan**: All `src/**/*.zig` modules for `LESSON(...)` comments
**Status**: Phase 6 course track preparation

## Summary

Only **3 LESSON comments** are present across the entire codebase, covering 2 modules out of 20+ core modules:
- `src/protocol/frame.zig` (2 comments, topic: `frame-codec`)
- `src/ipc/broadcast.zig` (1 comment, topic: `broadcast-buffer`)

**Gap**: 38 of 39 core modules have **zero Zig-angle or Aeron-angle instructional comments**.

---

## Coverage Table

| Module | Zig Lesson | Aeron Lesson | Tutorial Chapter |
|--------|-----------|--------------|------------------|
| **Protocol Layer** | | | |
| `src/protocol/frame.zig` | partial | partial | missing |
| **Log Buffer (Term)** | | | |
| `src/logbuffer/log_buffer.zig` | no | no | missing |
| `src/logbuffer/term_appender.zig` | no | no | missing |
| `src/logbuffer/term_reader.zig` | no | no | missing |
| `src/logbuffer/metadata.zig` | no | no | N/A |
| **IPC (Ring & Broadcast)** | | | |
| `src/ipc/ring_buffer.zig` | no | no | missing |
| `src/ipc/broadcast.zig` | no | partial | missing |
| `src/ipc/counters.zig` | no | no | missing |
| **Transport Layer** | | | |
| `src/transport/udp_channel.zig` | no | no | missing |
| `src/transport/endpoint.zig` | no | no | N/A |
| `src/transport/poller.zig` | no | no | N/A |
| `src/transport/uri.zig` | no | no | N/A |
| **Driver** | | | |
| `src/driver/sender.zig` | no | no | missing |
| `src/driver/receiver.zig` | no | no | missing |
| `src/driver/conductor.zig` | no | no | missing |
| `src/driver/media_driver.zig` | no | no | missing |
| **Client API** | | | |
| `src/publication.zig` | no | no | missing |
| `src/subscription.zig` | no | no | missing |
| `src/image.zig` | no | no | N/A |
| `src/aeron.zig` | no | no | N/A |
| **Archive** | | | |
| `src/archive/archive.zig` | no | no | missing |
| `src/archive/catalog.zig` | no | no | missing |
| `src/archive/conductor.zig` | no | no | missing |
| `src/archive/protocol.zig` | no | no | missing |
| `src/archive/recorder.zig` | no | no | missing |
| `src/archive/replayer.zig` | no | no | missing |
| **Cluster** | | | |
| `src/cluster/cluster.zig` | no | no | missing |
| `src/cluster/conductor.zig` | no | no | missing |
| `src/cluster/election.zig` | no | no | missing |
| `src/cluster/log.zig` | no | no | missing |
| `src/cluster/protocol.zig` | no | no | missing |

---

## Found LESSON Comments

### `src/protocol/frame.zig`

**Line 76:**
```zig
// LESSON(frame-codec): Aeron's C header uses #pragma pack(4), so i64 fields
// at non-8-aligned offsets need align(4) in Zig to match the wire layout.
receiver_id: i64 align(4),
```
**Type**: Dual-angle (Zig language feature + Aeron protocol detail)
**Coverage**: Explains Zig `align()` attribute in context of Aeron struct layout requirements

**Line 106:**
```zig
// LESSON(frame-codec): receiver_id was added in later Aeron versions (total 32 bytes).
// We implement the 24-byte version as specified in the project plan.
```
**Type**: Aeron-angle (versioning/compatibility)
**Coverage**: Documents evolution of Aeron frame format, justifies implementation choice

### `src/ipc/broadcast.zig`

**Line 2:**
```zig
// LESSON(broadcast-buffer): lock-free broadcast using a shared ring buffer with atomic cursors.
```
**Type**: Aeron-angle (architecture concept)
**Coverage**: High-level description of broadcast buffer design pattern

---

## Priority Gaps for M2 Course Tasks

Course milestone M2 (C-2, C-3, C-4) requires instruction on:

### Critical (blocks course development)
| Module | Task Impact | Required Annotations |
|--------|-------------|---------------------|
| `src/ipc/ring_buffer.zig` | C-2 foundation | Zig: atomic operations, lock-free queues; Aeron: ring buffer invariants |
| `src/ipc/counters.zig` | C-2 foundation | Aeron: performance counter semantics, shared-memory isolation |
| `src/logbuffer/term_appender.zig` | C-3 data path | Zig: unsafe pointer arithmetic, frame alignment; Aeron: term buffer appending rules |
| `src/logbuffer/term_reader.zig` | C-3 data path | Zig: memory ordering, volatile reads; Aeron: term buffer scanning, backpressure |
| `src/transport/udp_channel.zig` | C-3 I/O | Zig: socket APIs; Aeron: URI parsing, channel configuration |
| `src/driver/sender.zig` | C-3 flow | Aeron: packet transmission, flow control, retransmission strategy |
| `src/driver/receiver.zig` | C-3 flow | Aeron: packet reception, NAK handling, out-of-order recovery |
| `src/driver/conductor.zig` | C-3 control | Aeron: driver state machine, lifecycle management |

### High Priority (strongly recommended)
| Module | Reason |
|--------|--------|
| `src/publication.zig` | C-4 client API — publish semantics, buffering, backpressure handling |
| `src/subscription.zig` | C-4 client API — subscription lifecycle, image management |
| `src/driver/media_driver.zig` | C-3 driver entry point — I/O loop, thread model, shutdown |

### Medium Priority (tutorial-dependent)
| Module | Reason |
|--------|--------|
| `src/logbuffer/log_buffer.zig` | Foundation; may defer if C-2 deep-dive is text-heavy |
| `src/logbuffer/metadata.zig` | Metadata layout; instructional value depends on ring buffer complexity |
| `src/transport/endpoint.zig` | I/O multiplexing; depends on `poller.zig` design |
| `src/transport/poller.zig` | Platform abstraction; design-specific (epoll/kqueue) |
| `src/transport/uri.zig` | URI grammar; low teaching priority |

---

## Recommendations

### Immediate Actions (Before C-2)
1. Add **Zig-angle LESSON comments** to `src/ipc/ring_buffer.zig` (atomic operations, Zig safety model).
2. Add **Aeron-angle LESSON comments** to `src/ipc/counters.zig` (semantics of shared counters in Aeron).
3. Ensure `src/protocol/frame.zig` comments are polished for **01-foundations/01-frame-codec.md** tutorial.

### Pre-C-3 Sprint
4. Add dual-angle LESSON comments to term buffer modules:
   - `src/logbuffer/term_appender.zig` — Zig pointer safety + Aeron append semantics
   - `src/logbuffer/term_reader.zig` — Zig memory visibility + Aeron backpressure
5. Add transport-layer annotations:
   - `src/transport/udp_channel.zig` — URI parsing + channel setup
   - `src/driver/sender.zig` / `src/driver/receiver.zig` — packet flow + error handling

### Pre-C-4 Sprint
6. Add client API instruction:
   - `src/publication.zig` — publish patterns, buffering strategy
   - `src/subscription.zig` — image binding, lifecycle

### Documentation Alignment
- **LESSON format**: `LESSON(topic-slug): <1-line summary of teaching point>`
- **Placement**: Above or inline with the code region being explained
- **Scope**: Focus on "why" and Aeron protocol/Zig language interaction, not "how"
- **Link convention**: Include `See docs/tutorial/part/<chapter>.md` in first comment if tutorial chapter exists

---

## Statistics

| Metric | Value |
|--------|-------|
| Total modules scanned | 39 |
| Modules with LESSON comments | 2 |
| Total LESSON comments found | 3 |
| Coverage | 7.7% (3 of 39 modules) |
| **Modules needing Zig-angle instruction** | 20 |
| **Modules needing Aeron-angle instruction** | 37 |
| **Modules requiring dual-angle annotations** | 36 |

---

## Appendix: Lesson Topics Found

- `frame-codec` (2 instances) — Aeron protocol frame layout, Zig struct alignment
- `broadcast-buffer` (1 instance) — lock-free broadcast buffer architecture

## Appendix: Tutorial Chapter Mapping Status

**Existing chapters:**
- `docs/tutorial/01-foundations/` — 5 chapters (frame-codec, ring-buffer, broadcast, counters, log-buffer)
- `docs/tutorial/02-data-path/` — 3 chapters (term-appender, term-reader, udp-transport)
- `docs/tutorial/03-driver/` — 4 chapters (sender, receiver, conductor, media-driver)
- `docs/tutorial/04-client/` — 3 chapters (publications, subscriptions, integration-tests)
- `docs/tutorial/05-archive/` — 6 chapters (protocol, catalog, recorder, replayer, conductor, main)
- `docs/tutorial/06-cluster/` — 5 chapters (protocol, election, log-replication, conductor, main)

**Modules mapped but tutorial missing:**
- `src/driver/conductor.zig` → needs `03-driver/03-conductor.md`
- `src/driver/media_driver.zig` → needs `03-driver/04-media-driver.md`

**Modules with no tutorial mapping:**
- `src/logbuffer/metadata.zig`
- `src/transport/endpoint.zig`
- `src/transport/poller.zig`
- `src/transport/uri.zig`
- `src/image.zig`
- `src/aeron.zig` (top-level client entry point)
- Archive/cluster: all mapped
