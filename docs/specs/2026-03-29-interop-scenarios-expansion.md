# Interop Scenarios Expansion

Date: 2026-03-29

## Goal

Expand Zig↔Java interop validation beyond the existing single pub/sub smoke test to cover multi-stream, exclusive publication, and client-side reconnect. Each scenario is a separate finite Java helper, delivered as its own PR.

## Current State

- `deploy/InteropSmoke.java` — single pub/sub (10 messages, stream 1001)
- `deploy/CountersChecker.java` — validates 6 counter types via CnC mmap
- `deploy/entrypoint-java.sh` — orchestrates both with marker-file coordination
- Infrastructure: `docker-compose.ci.yml`, shared `/dev/shm/aeron` tmpfs

## Scenarios

### PR 1: MultiStreamSmoke.java

**What**: 2–3 concurrent pub/sub pairs on different stream IDs over the same UDP channel.

**Validates**:
- Zig driver correctly demuxes frames by stream ID
- Messages arrive on correct streams with no cross-contamination
- Counters scale correctly (separate publisher/subscriber counters per stream)

**Contract**:
- Configurable stream count (default 3) and message count per stream (default 10)
- Each stream sends unique payload prefix for identification
- Exit 0 on success, non-zero with diagnostic on any mismatch
- Marker-file coordination: waits for `/tmp/smoke-ready`, writes `/tmp/multistream-done`

### PR 2: ExclusivePublicationSmoke.java

**What**: Exclusive publication offer + verify, then second publication attempt on the same channel/stream.

**Validates**:
- Zig driver grants exclusive access to first publisher
- Second publication attempt gets appropriate error/back-pressure
- Messages flow correctly on the exclusive publication
- Correct counter types allocated for exclusive pub

**Contract**:
- Opens exclusive pub on stream 2001, publishes messages, verifies receipt
- Attempts second exclusive pub on same channel+stream, expects rejection
- Exit 0 on success
- Marker-file: waits for `/tmp/smoke-ready`, writes `/tmp/exclusive-done`

### PR 3: ReconnectSmoke.java

**What**: Java client disconnects and reconnects while the Zig driver stays up, resumes pub/sub.

**Validates**:
- Zig driver handles client disconnect gracefully (no crash, resources cleaned)
- Reconnected client can establish new session on same channel/stream
- Messages flow on the new session
- Counters reset/reallocate correctly after reconnect

**Contract**:
- Phase 1: connect, pub/sub N messages, verify, close Aeron context
- Phase 2: reconnect (new Aeron context), pub/sub N messages, verify
- Exit 0 if both phases succeed
- Marker-file: waits for `/tmp/smoke-ready`, writes `/tmp/reconnect-done`

## Entrypoint Integration

Each PR updates `deploy/entrypoint-java.sh` to run the new scenario after existing checks. Scenarios run sequentially (shared `/dev/shm/aeron`). The entrypoint exits on first failure.

## Acceptance Criteria (per PR)

- New Java file compiles with `javac` against Aeron 1.50.2
- `make interop-smoke` passes end-to-end
- No changes to Zig source required (validates existing driver behavior)
- Marker-file protocol consistent with existing coordination pattern

## Delivery Order

1. MultiStreamSmoke → PR
2. ExclusivePublicationSmoke → PR
3. ReconnectSmoke → PR

Each PR is independently mergeable. Later PRs assume earlier ones are merged.
