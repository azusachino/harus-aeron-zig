# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Strict Aeron URI parsing/normalization with all upstream channel forms
- Remaining wire frame variants: RTTM, ResolutionEntry with full codec coverage
- Malformed-input rejection in frame decoder (no panics on untrusted UDP data)
- STATUS flow control: receiver window management, position feedback loop
- Live CnC tooling: stat/errors/loss/streams/events/cluster-tool backed by real mmap reads
- Archive operational fidelity: segment rotation, catalog descriptor persistence, restart reconstruction
- Cluster consensus fidelity: follower catch-up/rejoin, election continuity, session redirect/failover
- Interop automation: Zig↔Java matrix (pub/sub, archive, cluster) via single `make interop`
- Performance baseline: throughput/latency/fanout benchmarks + soak test scenarios

### Fixed
- Multi-frame processing in processDatagram (receiver now walks all Aeron frames per UDP datagram)
- Image rebuild_position initialization from active_term_id in SETUP handshake
- Memory leak in aeron.zig: heap *Image pointers now destroyed in deinit

## [1.0.0] - 2026-03-23

### Added
- Full Aeron wire protocol implementation in Zig.
- Lock-free ring buffer and broadcast IPC.
- Shared-memory counters for flow control and stats.
- UDP transport with unicast and multicast support.
- Media Driver agents: Conductor, Sender, Receiver.
- Client Library with Publication and Subscription APIs.
- Aeron Archive support (Recording and Replay).
- Aeron Cluster consensus module (Raft).
- Structured Tutorial Course (Parts 1-6) with dual Zig/Aeron tracks.
- Java interop smoke tests.

### Fixed
- Critical bugs in conductor test buffer layout.
- Broadcast transmit alignment for cross-language compatibility.
- Data frame header sizes for full wire compatibility with Aeron 1.44.1.

## [0.5.0] - 2026-03-15
- Initial public preview.
- Basic IPC pub/sub working.
- Basic UDP unicast working.
