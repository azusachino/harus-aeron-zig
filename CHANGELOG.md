# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.0.0] - 2026-04-11 — Test completeness and release gate

### Added
- **269 tests** across protocol, IPC, log buffer, driver, archive, cluster, integration, and soak suites
- **IPC test suite** (`test/ipc/`): 59 new tests covering ManyToOneRingBuffer (wrap-around, padding, unblock, correlation ID), BroadcastTransmitter/Receiver (lapping, recovery, padding skip), and CountersMap (CRUD, atomics, slot reuse)
- **Log buffer test suite** (`test/logbuffer/`): 33 new tests for TermAppender (fill, rotation, padding frame, flag preservation) and TermReader (fragment limit, padding skip, uncommitted stop, offset math)
- **Protocol expansion**: 46 frame codec tests (all 7 frame types, all flag combos, boundary values), 35 URI tests (all Aeron URI forms, multicast detection, error rejection), 26 flow control tests
- **Driver integration tests**: SETUP handshake, publication reference counting, client keepalive/eviction, retransmit queue drain, session establishment via injected SETUP frames
- **Archive edge cases**: 100-recording catalog lookup, stop-position accuracy, multi-chunk replay, segment rotation consistency, findLastMatchingRecording, null-ID safety
- **Cluster chaos tests**: full canvass→candidate→leader lifecycle, stale-term vote rejection, failover detection, log commit independence, snapshot begin/end state machine, sequential snapshots
- **Stress suite** (`test/stress/`): ring buffer N-message soak, term appender fill-under-load, conductor add/remove publication cycles; all parameterised via `SOAK_ITERS`
- **Release audit**: `docs/audits/1.0.0-release-audit.md` with protocol parity matrix, per-suite test counts, performance baseline, and known-gaps register

### Fixed
- `test/harness.zig`: removed duplicate `createClusterNode`/`injectDelay` functions spliced into struct literal; fixed `!anytype` return type (invalid in Zig) to concrete `ConsensusModule`
- Formatting: applied `zig fmt` to `src/cluster/protocol.zig`, `src/archive/archive.zig`, `src/ipc/ring_buffer.zig`

## [0.2.0] - 2026-03-25 — Phase 10: Upstream Test Parity & CI

### Added
- **Scenario testing framework**: 14 scenario tests across protocol, driver, archive, cluster (test/)
- **CI automation**: GitHub Actions matrix (Linux + macOS), interop smoke gate with Docker Compose
- **Interop infrastructure**: docker-compose.ci.yml for lightweight Java↔Zig smoke tests
- **Local CI verification**: Podman support in nix devShell with podman-compose integration
- **Wire protocol compliance**: cnc.dat filename lowercase (matches Aeron C++/Java implementations)

### Changed
- Dockerfile: enable nix-command and flakes experimental features for container builds
- Makefile: interop targets now use podman-compose with proper env vars and exit-code gating
- Architecture: streamlined k8s deployment from deploy/k8s/ to k8s/ at project root

### Fixed
- cnc.dat filename case sensitivity (was CnC.dat, now lowercase for full Aeron parity)
- Phase 9: Strict Aeron URI parsing/normalization with all upstream channel forms
- Phase 9: Remaining wire frame variants (RTTM, ResolutionEntry) with full codec coverage
- Phase 9: Malformed-input rejection in frame decoder (no panics on untrusted UDP data)
- Phase 8: STATUS flow control with receiver window management and position feedback loop
- Phase 8: Live CnC tooling (stat/errors/loss/streams/events/cluster-tool) backed by real mmap
- Phase 8: Archive operational fidelity (segment rotation, catalog persistence, restart reconstruction)
- Phase 8: Cluster consensus fidelity (follower catch-up/rejoin, election continuity, failover)
- Phase 8: Multi-frame processing in processDatagram (receiver walks all Aeron frames per UDP)
- Phase 8: Image rebuild_position initialization from active_term_id in SETUP handshake
- Phase 8: Memory leak in aeron.zig (heap *Image pointers now destroyed in deinit)

## [0.1.0] - 2026-03-23

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
