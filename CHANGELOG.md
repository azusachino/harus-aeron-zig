# Changelog

All notable changes to this project will be documented in this file.

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
