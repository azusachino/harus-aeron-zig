# Todo

## Phase 1 — Media Driver (In Progress)

- [x] P1-1: Protocol Frame Codec (`src/protocol/frame.zig`)
- [x] P1-2: Log Buffer — Metadata & Term Rotation (`src/logbuffer/`)
- [x] P1-3: Term Appender (`src/logbuffer/term_appender.zig`) — after P1-2
- [x] P1-4: Term Reader (`src/logbuffer/term_reader.zig`) — after P1-2 ✓ implemented
- [x] P1-5: IPC Ring Buffer (`src/ipc/ring_buffer.zig`)
- [x] P1-6: Broadcast Transmitter/Receiver (`src/ipc/broadcast.zig`)
- [x] P1-7: Counters Map (`src/ipc/counters.zig`)
- [x] P1-8: UDP Channel & Transport (`src/transport/`)
- [x] P1-9: Sender Agent (`src/driver/sender.zig`) — after P1-1,2,3,8
- [x] P1-10: Receiver Agent (`src/driver/receiver.zig`) — after P1-1,2,8
- [x] P1-11: Driver Conductor (`src/driver/conductor.zig`) — after P1-5,6,7
- [x] P1-12: Media Driver Orchestrator (`src/driver/media_driver.zig`) — after P1-9,10,11
- [x] P1-13: Client Library (`src/aeron.zig`, `src/publication.zig`, etc.) — after P1-5,6,7
- [x] P1-14: Integration Tests (`test/`) — after P1-12,13

## Phase 2 — Aeron Archive (Complete)

- [x] P2-1: Archive Protocol Codec (`src/archive/protocol.zig`)
- [x] P2-2: Recording Catalog (`src/archive/catalog.zig`)
- [x] P2-3: Recorder (`src/archive/recorder.zig`)
- [x] P2-4: Replayer (`src/archive/replayer.zig`)
- [x] P2-5: Archive Conductor (`src/archive/conductor.zig`)
- [x] P2-6: Archive Context + Main (`src/archive/archive.zig`)

## Phase 3 — Aeron Cluster (Complete)

- [x] P3-1: Cluster Protocol Codec (`src/cluster/protocol.zig`)
- [x] P3-2: Raft Election (`src/cluster/election.zig`)
- [x] P3-3: Log Replication (`src/cluster/log.zig`)
- [x] P3-4: Cluster Conductor (`src/cluster/conductor.zig`)
- [x] P3-5: Cluster Context + Main (`src/cluster/cluster.zig`)

## Phase 4 — Polish & Observability (Complete)

- [x] P4-1: Aeron URI Parser (`src/transport/uri.zig`)
- [x] P4-2: Loss Report (`src/loss_report.zig`)
- [x] P4-3: Driver Events Log (`src/event_log.zig`)
- [x] P4-4: Counters Reporting (`src/counters_report.zig`)

## Done

- [x] Project layout init (flake.nix, Makefile, build.zig, AGENTS.md, docs/)
- [x] Protocol frame stubs (`src/protocol/frame.zig` — stubs, not complete)
- [x] Log buffer stub (`src/logbuffer/log_buffer.zig`)
- [x] Ring buffer stub (`src/ipc/ring_buffer.zig`)
