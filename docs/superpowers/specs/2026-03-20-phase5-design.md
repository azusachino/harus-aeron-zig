# Phase 5 Design — Interop, Performance, Tooling & Production Readiness

**Date**: 2026-03-20
**Status**: Approved
**Branch**: `feat/phase5-*` (one branch per sub-phase)

---

## Overview

Phase 5 hardens harus-aeron-zig for production use. Four independent sub-phases run in parallel:

- **5a** — Wire compatibility validation against Java Aeron
- **5b** — Performance benchmarks, fuzz testing, stress testing
- **5c** — CLI tooling suite and sample applications
- **5d** — Production readiness (logging, config, shutdown, health probes)

Each sub-phase is a separate feature branch and PR.

---

## Phase 5a — Wire Compatibility

### Goal

Prove bidirectional interop with the real Java Aeron driver over UDP in k3s.

### Architecture

```
k3s cluster (colima)
├── aeron namespace
│   ├── zig-driver (existing deployment)
│   └── java-aeron (new pod, official aeron-all jar + test harness)
└── interop-test jobs (run tests, exit 0/1)
```

### Test Cases

| ID | Test | Description |
|----|------|-------------|
| I-1 | Zig pub → Java sub | Our driver publishes 1000 messages, Java BasicSubscriber receives all |
| I-2 | Java pub → Zig sub | Java BasicPublisher sends 1000 messages, our driver receives all |
| I-3 | Zig pub → Java archive | Java archive records our stream, replays and verifies |
| I-4 | Bidirectional | Both sides pub+sub simultaneously on different streams |

### Files

| File | Purpose |
|------|---------|
| `deploy/interop/Dockerfile.java-aeron` | Java Aeron image with aeron-all jar |
| `deploy/interop/test-harness.sh` | Runs sample apps, checks results |
| `deploy/interop/job-zig-pub-java-sub.yaml` | K8s Job for I-1 |
| `deploy/interop/job-java-pub-zig-sub.yaml` | K8s Job for I-2 |
| `deploy/interop/job-archive-interop.yaml` | K8s Job for I-3 |
| `deploy/interop/job-bidirectional.yaml` | K8s Job for I-4 |
| `deploy/interop/kustomization.yaml` | Kustomize overlay |

### Makefile Targets

- `make interop` — build images, deploy, run all interop jobs, collect results
- `make interop-build` — build Java Aeron image only
- `make interop-run` — run jobs only (assumes images exist)

### Task Breakdown

1. Create Java Aeron Dockerfile with aeron-all jar from Maven Central
2. Write test harness shell scripts (pub/sub with message count verification)
3. Write k8s Job manifests for each test case
4. Write kustomization overlay for interop namespace
5. Add Makefile targets (interop, interop-build, interop-run)
6. Deploy interop pods and smoke test connectivity
7. Run and debug all 4 interop tests to passing

---

## Phase 5b — Performance & Hardening

### Goal

Validate correctness under adversarial input. Measure throughput and latency baselines.

### Fuzz Targets

Each target feeds random/corrupted bytes into an external input parser using `std.testing.fuzz`.
Note: Zig's fuzz API is experimental (0.14+). If unavailable, fall back to manual random input loops.

| ID | Target | Input | Parser |
|----|--------|-------|--------|
| F-1 | `fuzz_frame_decode` | Random bytes | Frame codec (`protocol/frame.zig`) |
| F-2 | `fuzz_uri_parse` | Random strings | URI parser (`transport/uri.zig`) |
| F-3 | `fuzz_ring_buffer_read` | Corrupted buffer memory | Ring buffer reader (`ipc/ring_buffer.zig`) |
| F-4 | `fuzz_broadcast_receive` | Corrupted broadcast buffer | Broadcast receiver (`ipc/broadcast.zig`) |
| F-5 | `fuzz_log_buffer_read` | Corrupted term data | Term reader (`logbuffer/term_reader.zig`) |
| F-6 | `fuzz_archive_catalog` | Corrupted catalog file | Catalog parser (`archive/catalog.zig`) |

### Benchmarks

| ID | Benchmark | Measures |
|----|-----------|----------|
| B-1 | `bench_throughput` | Messages/sec, bytes/sec at 64B, 1KB, 64KB message sizes |
| B-2 | `bench_latency` | Round-trip histogram: p50, p99, p999 (timestamp in payload) |
| B-3 | `bench_fanout` | 1 pub → N subs scaling (N = 1, 2, 4, 8) |

### Stress Tests

| ID | Test | Scenario |
|----|------|----------|
| S-1 | `stress_term_rotation` | Publish until 100+ term rotations, verify no corruption |
| S-2 | `stress_concurrent_pubs` | 8 concurrent publishers on same stream |
| S-3 | `stress_reconnect` | Publisher disconnect/reconnect 50 cycles |

### Files

| File | Purpose |
|------|---------|
| `src/fuzz/frame.zig` | F-1 |
| `src/fuzz/uri.zig` | F-2 |
| `src/fuzz/ring_buffer.zig` | F-3 |
| `src/fuzz/broadcast.zig` | F-4 |
| `src/fuzz/log_buffer.zig` | F-5 |
| `src/fuzz/catalog.zig` | F-6 |
| `src/bench/throughput.zig` | B-1 |
| `src/bench/latency.zig` | B-2 |
| `src/bench/fanout.zig` | B-3 |
| `test/stress/term_rotation.zig` | S-1 |
| `test/stress/concurrent_pubs.zig` | S-2 |
| `test/stress/reconnect.zig` | S-3 |

### Makefile Targets

- `make fuzz` — run all fuzz targets (default 10s each)
- `make fuzz-TARGET` — run single fuzz target
- `make bench` — run all benchmarks, print results table
- `make stress` — run all stress tests

### Task Breakdown

1. Create fuzz/bench/stress scaffold with build.zig integration for all three directories
2. Implement F-1: frame decode fuzzer
3. Implement F-2: URI parse fuzzer
4. Implement F-3: ring buffer read fuzzer
5. Implement F-4: broadcast receive fuzzer
6. Implement F-5: log buffer read fuzzer
7. Implement F-6: archive catalog fuzzer
8. Implement B-1: throughput benchmark
10. Implement B-2: latency benchmark
11. Implement B-3: fanout benchmark
12. Implement S-1: term rotation stress test
13. Implement S-2: concurrent publishers stress test
14. Implement S-3: reconnect stress test
15. Add Makefile targets (fuzz, bench, stress)

---

## Phase 5c — Tooling & DX

### Goal

Full CLI subcommand suite matching Java Aeron tooling. Sample applications for demos.

### CLI Subcommands

All invoked as `aeron-driver <cmd>`. Shared `--aeron-dir` flag (default from `AERON_DIR` or `/dev/shm/aeron`).

| Subcommand | Java Equivalent | Description |
|------------|-----------------|-------------|
| `stat` | `AeronStat` | Live-refreshing counters (ANSI terminal, 1s refresh) |
| `errors` | `ErrorStat` | Read and display error log from shared memory |
| `loss` | `LossStat` | Loss report: per-stream gap stats |
| `streams` | `StreamStat` | Per-stream positions (pub limit, sender, receiver HWM, sub) |
| `events` | — | Event log reader: FRAME_IN/OUT, CMD_IN/OUT traces |
| `cluster-tool` | `ClusterTool` | Membership list, current leader, snapshot info |

### Prerequisites

- **CnC file mmap reader**: The current `--counters` mode uses placeholder data. A CnC (Command and Control) file reader that mmaps the driver's shared memory is required before any tool can read live driver state. This is task 0 for this sub-phase.

### Shared Infrastructure

- `src/cnc.zig` — CnC file mmap reader (reads counters, error log, loss report from live driver)
- `src/cli.zig` — argument parser and subcommand dispatch
- All tools use `cnc.zig` to mmap the same shared memory files the driver writes
- `stat` uses ANSI escape codes for terminal refresh (no ncurses)

### Sample Applications

| File | Description |
|------|-------------|
| `examples/basic_publisher.zig` | Minimal pub example with message counter |
| `examples/basic_subscriber.zig` | Minimal sub example with fragment handler |
| `examples/throughput.zig` | High-rate pub/sub with live counter display |

### Files

| File | Purpose |
|------|---------|
| `src/cnc.zig` | CnC file mmap reader for live driver state |
| `src/cli.zig` | Subcommand dispatch, shared flags |
| `src/tools/stat.zig` | Live counters display |
| `src/tools/errors.zig` | Error log reader |
| `src/tools/loss.zig` | Loss report reader |
| `src/tools/streams.zig` | Stream position display |
| `src/tools/events.zig` | Event log reader |
| `src/tools/cluster_tool.zig` | Cluster management tool |
| `examples/basic_publisher.zig` | Pub sample |
| `examples/basic_subscriber.zig` | Sub sample |
| `examples/throughput.zig` | Throughput sample |

### Makefile Targets

- `make stat` — alias for `zig-out/bin/aeron-driver stat`
- `make examples` — build all example binaries

### Task Breakdown

0. Implement CnC file mmap reader (`src/cnc.zig`) — prerequisite for all tools
1. Implement CLI arg parser and subcommand dispatch (`src/cli.zig`)
2. Refactor `src/main.zig` to use new CLI dispatch (preserve `--archive`/`--cluster` flags for backward compat with k8s manifests)
3. Implement `stat` subcommand with ANSI live refresh
4. Implement `errors` subcommand
5. Implement `loss` subcommand
6. Implement `streams` subcommand
7. Implement `events` subcommand
8. Implement `cluster-tool` subcommand
9. Write `examples/basic_publisher.zig`
10. Write `examples/basic_subscriber.zig`
11. Write `examples/throughput.zig`
12. Add Makefile targets and build.zig entries for examples

---

## Phase 5d — Production Readiness

### Goal

Make the driver production-grade: structured logging, env config, graceful shutdown, health probes.

### Structured Logging

`src/log.zig` — JSON logger wrapping `std.log`.

```json
{"ts":"2026-03-20T12:00:00.123Z","level":"info","msg":"publication added","component":"conductor","session_id":123,"stream_id":1001}
```

- Level filtering via `AERON_LOG_LEVEL` (trace/debug/info/warn/error)
- Format toggle via `AERON_LOG_FORMAT` (json/text) — text for local dev, json for k8s
- All existing log call sites migrated to the new logger

### Environment Variable Configuration

`src/config.zig` — reads all config from env vars with sensible defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `AERON_DIR` | `/dev/shm/aeron` (Linux), `/tmp/aeron` (macOS) | Shared memory directory |
| `AERON_TERM_LENGTH` | `16777216` (16MB) | Term buffer length |
| `AERON_MTU` | `1408` | MTU length |
| `AERON_CLIENT_TIMEOUT_NS` | `5000000000` (5s) | Client liveness timeout |
| `AERON_LOG_LEVEL` | `info` | Log level |
| `AERON_LOG_FORMAT` | `json` | Log format (json/text) |
| `AERON_HEALTH_PORT` | `8080` | Health endpoint port |

Validated at startup — invalid values produce clear error message + exit(1).

### Graceful Shutdown

`src/signal.zig` — SIGTERM/SIGINT handler.

- Sets atomic `running` flag checked by all duty cycle loops
- Conductor drains in-flight commands before exit
- Archive flushes and closes recording files
- Cluster: stop accepting new sessions and drain in-flight (leader transfer deferred to future work)
- Timeout: if shutdown exceeds 10s, force exit

### Health & Readiness Probes

`src/health.zig` — minimal HTTP responder (raw TCP socket).

Constraints: read first line only, match `GET /healthz` or `GET /readyz`, respond with fixed string. No header parsing, no keep-alive, no chunked encoding. This is NOT a general HTTP server.

| Endpoint | Response | Condition |
|----------|----------|-----------|
| `GET /healthz` | 200 OK | Process alive |
| `GET /readyz` | 200 OK / 503 | Driver initialized, all agents running |

- Runs on dedicated thread, does not interfere with duty cycles
- K8s manifests updated with `livenessProbe` and `readinessProbe`

### Files

| File | Purpose |
|------|---------|
| `src/log.zig` | Structured JSON/text logger |
| `src/config.zig` | Env var config reader with validation |
| `src/signal.zig` | SIGTERM/SIGINT graceful shutdown |
| `src/health.zig` | HTTP health/readiness endpoint |
| `src/main.zig` | Updated to use config, logger, signal, health |
| `src/driver/media_driver.zig` | Updated with running flag, shutdown sequence |
| `deploy/k8s/media-driver.yaml` | Add liveness/readiness probes |
| `deploy/k8s/cluster.yaml` | Add liveness/readiness probes |

### Task Breakdown

1. Implement structured logger (`src/log.zig`) with JSON and text formats
2. Implement env var config reader (`src/config.zig`) with validation
3. Implement signal handler (`src/signal.zig`) with atomic running flag
4. Implement HTTP health server (`src/health.zig`)
5. Integrate logger into driver hot path modules (conductor, sender, receiver, main)
6. Integrate config into MediaDriverContext and main.zig
7. Integrate signal handler into media_driver.zig duty cycles
8. Integrate health server startup into main.zig
9. Update k8s manifests with health probes
10. Integration test: verify graceful shutdown completes cleanly

---

## Dependency Graph

```
Phase 5a (interop)     — independent
Phase 5b (perf)        — independent
Phase 5c (tooling)     — independent
Phase 5d (production)  — independent

Within 5c: cli.zig (task 1) blocks all subcommand tasks (3-8)
Within 5d: log.zig (task 1) and config.zig (task 2) block integration tasks (5-8)
```

All four sub-phases can be worked in parallel on separate branches.

---

## Total Task Count

| Sub-phase | Tasks |
|-----------|-------|
| 5a — Interop | 7 |
| 5b — Performance | 14 |
| 5c — Tooling | 13 |
| 5d — Production | 10 |
| **Total** | **44** |
