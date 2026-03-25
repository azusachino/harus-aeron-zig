# Phase 10 — Upstream Test Parity & CI

**Date**: 2026-03-25
**Status**: Approved
**Version target**: 0.1.x → 0.2.0

---

## Goal

Establish behavioural parity with the upstream `aeron-io/aeron` test suite by:

1. Porting every upstream test scenario to idiomatic Zig tests in `test/`
2. Running the real Java Aeron 1.46.7 client against our driver in GitHub Actions CI
3. Replacing the existing k8s-based interop infrastructure with a lightweight, CI-native approach

This is not line-coverage chasing. Success means every scenario in `test/upstream_map.jsonl` has a Zig test and a CI green tick.

---

## What Changes

### Removed (clean slate — delete immediately, no deprecation period)

| Path | Reason |
|------|--------|
| `deploy/interop/` | Replaced by `deploy/docker-compose.ci.yml` |
| `test/stress/` | Replaced by `make bench` (lighter, CI-friendly) |
| `test/interop/` | Replaced by scenario test files in `test/protocol/`, `test/driver/`, etc. |

### Moved

| From | To | Reason |
|------|----|--------|
| `deploy/k8s/` | `k8s/` (project root) | k8s is a local development tool, not a deployment artifact |

**Note**: Any Makefile targets that reference `deploy/k8s/` (e.g. `kubectl apply -k deploy/k8s/`) must be updated to `k8s/` as part of the move.

### Added

```
.github/
  workflows/
    ci.yml              ← Zig test matrix (all PRs)
    interop.yml         ← Java interop (main push + manual trigger)

deploy/
  docker-compose.ci.yml ← lightweight Java+Zig interop for CI smoke

k8s/                    ← moved from deploy/k8s/ — local use only

test/
  UPSTREAM_MAP.md       ← traceability: our test ↔ upstream class ↔ status
  protocol/
    frame_codec_test.zig
    uri_parser_test.zig
    flow_control_test.zig
  driver/
    session_establishment_test.zig
    publication_lifecycle_test.zig
    subscription_lifecycle_test.zig
    conductor_ipc_test.zig
    loss_and_recovery_test.zig
  archive/
    catalog_test.zig
    record_replay_test.zig
    segment_rotation_test.zig
  cluster/
    election_test.zig
    log_replication_test.zig
    failover_test.zig
```

---

## CI Architecture

### Workflow files

- `.github/workflows/ci.yml` — jobs: `lint`, `zig-test`, `interop-smoke`, `core-pipeline`
- `.github/workflows/interop.yml` — jobs: `interop-full`, `bench` (main + manual only)

### Skeleton: `.github/workflows/ci.yml`

```yaml
name: CI
permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command make lint

  zig-test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/cache@v4
        with:
          path: ~/.cache/zig
          key: zig-${{ matrix.os }}-${{ hashFiles('build.zig.zon') }}
      - run: nix develop --command make check
      - run: nix develop --command make test-scenarios

  interop-smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: temurin
          cache: maven
      - run: nix develop --command make build
      - run: docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit --exit-code-from java-client
        env:
          AERON_VERSION: "1.46.7"

  core-pipeline:
    if: always()
    runs-on: ubuntu-latest
    needs: [lint, zig-test, interop-smoke]
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
```

### Skeleton: `.github/workflows/interop.yml`

```yaml
name: Interop Full
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  interop-full:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/setup-java@v4
        with: { java-version: '21', distribution: temurin, cache: maven }
      - run: nix develop --command make build
      - run: docker compose -f deploy/docker-compose.ci.yml --profile full up --abort-on-container-exit

  bench:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command make bench
```

### Job 1: `zig-test` (every PR + main push)

Runs on: `ubuntu-latest`, `macos-latest`
Trigger: all PRs, all pushes to main
Timeout: ~5 min

```
nix develop --command make check          # fmt + build + unit tests + lesson-lint
nix develop --command make test-scenarios # protocol/driver/archive/cluster tests
```

Cache: `~/.cache/zig` keyed on `build.zig.zon` hash per OS.

### Job 2: `interop-smoke` (every PR)

Runs on: `ubuntu-latest`
Trigger: all PRs
Timeout: ~3 min

```
docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit
# Smoke: 10 messages each direction (java-pub→zig-sub, zig-pub→java-sub)
# Passes if both containers exit 0
```

Uses `actions/setup-java@v4` (JDK 21, Temurin) + Aeron 1.46.7 jar (Maven cached).

### Job 3: `interop-full` (main push + manual dispatch only)

Runs on: `ubuntu-latest`
Trigger: push to main, `workflow_dispatch`
Timeout: ~15 min

```
docker compose -f deploy/docker-compose.ci.yml up --profile full --abort-on-container-exit
# Full matrix: 100 messages pub/sub + archive record/replay + cluster 3-node smoke
```

### Job 4: `bench` (main push only)

Runs on: `ubuntu-latest`
Trigger: push to main
Timeout: ~5 min

```
nix develop --command make bench
# Throughput/latency baseline — result posted as job summary, not a gate
```

### Merge gate

PRs require `zig-test` + `interop-smoke` to be green. `bench` and `interop-full` are advisory on main.

---

## Test Scenario Mapping

Test files map to upstream `aeron-io/aeron` test classes. Tracked in `test/UPSTREAM_MAP.md`:

### Protocol layer

| Our file | Upstream class | Upstream path |
|----------|---------------|---------------|
| `test/protocol/frame_codec_test.zig` | `DataHeaderFlyweightTest` | `aeron-client/src/test/java/io/aeron/` |
| `test/protocol/frame_codec_test.zig` | `SetupFlyweightTest` | same |
| `test/protocol/frame_codec_test.zig` | `StatusMessageFlyweightTest` | same |
| `test/protocol/uri_parser_test.zig` | `ChannelUriTest` | `aeron-client/src/test/java/io/aeron/` |
| `test/protocol/flow_control_test.zig` | `ReceiverWindowTest` | `aeron-driver/src/test/java/io/aeron/driver/` |

### Driver layer

| Our file | Upstream class | Upstream path |
|----------|---------------|---------------|
| `test/driver/session_establishment_test.zig` | `PublicationImageTest` | `aeron-driver/src/test/java/io/aeron/driver/` |
| `test/driver/session_establishment_test.zig` | `DriverConductorTest` (SETUP/STATUS cases) | same |
| `test/driver/publication_lifecycle_test.zig` | `DriverConductorTest` (add/remove pub) | same |
| `test/driver/subscription_lifecycle_test.zig` | `DriverConductorTest` (add/remove sub) | same |
| `test/driver/conductor_ipc_test.zig` | `DriverConductorTest` (IPC command dispatch) | same |
| `test/driver/loss_and_recovery_test.zig` | `LossHandlerTest` | `aeron-driver/src/test/java/io/aeron/driver/` |
| `test/driver/loss_and_recovery_test.zig` | `RetransmitHandlerTest` | same |

### Archive layer

| Our file | Upstream class | Upstream path |
|----------|---------------|---------------|
| `test/archive/catalog_test.zig` | `CatalogTest` | `aeron-archive/src/test/java/io/aeron/archive/` |
| `test/archive/record_replay_test.zig` | `ArchiveTest` | same |
| `test/archive/segment_rotation_test.zig` | `RecordingWriterTest` | same |

### Cluster layer

| Our file | Upstream class | Upstream path |
|----------|---------------|---------------|
| `test/cluster/election_test.zig` | `ElectionTest` | `aeron-cluster/src/test/java/io/aeron/cluster/` |
| `test/cluster/log_replication_test.zig` | `ClusterTimerTest` + `LogReplicationTest` | same |
| `test/cluster/failover_test.zig` | `ClusterNodeTest` (failover cases) | same |

---

## Docker Compose CI Layout

`deploy/docker-compose.ci.yml` skeleton:

```yaml
services:
  zig-driver:
    build:
      context: .
      dockerfile: Dockerfile.zig        # nix-based, runs `make run`
    networks: [aeron]
    environment:
      AERON_DIR: /tmp/aeron
      AERON_TERM_BUFFER_LENGTH: "65536"

  java-client:
    build:
      context: deploy/
      dockerfile: Dockerfile.java-aeron
      args:
        AERON_VERSION: "${AERON_VERSION:-1.46.7}"
    networks: [aeron]
    depends_on: [zig-driver]
    environment:
      AERON_DIR: /tmp/aeron             # shared tmpfs with zig-driver
      MSG_COUNT: "${MSG_COUNT:-10}"     # 10 for smoke, 100 for full
    command: ["java", "-cp", "/aeron-all.jar", "io.aeron.samples.AeronSubscriber"]

networks:
  aeron:
    driver: bridge

# Profile: full — adds archive + cluster scenarios
```

**Aeron IPC**: UDP only (containers are separate processes on the same Docker bridge network). No shared memory mmap between containers.

**Smoke profile** (default): `MSG_COUNT=10`, pub/sub only.
**Full profile** (`--profile full`): `MSG_COUNT=100`, adds `java-archive-client` for record/replay round-trip.

---

## Upstream Test Porting Rules

When porting a test case from Java/C++ to Zig:

1. **Same scenario, not same code** — translate the *intent* not the implementation
2. **Use `std.testing` only** — no third-party test frameworks
3. **Name tests descriptively** — `test "DriverConductor: add_publication creates log buffer and sends ready"` not `test "test1"`
4. **Reference upstream** — each test file opens with a comment block:
   ```zig
   // Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java
   // Aeron version: 1.46.7
   // Coverage: add_publication, remove_publication, client_keepalive, terminate_driver
   ```
5. **No `unreachable` in test paths** — use `try` and let errors surface cleanly
6. **One scenario per `test` block** — do not bundle multiple scenarios; each maps to one upstream test method

---

## build.zig Test Steps

All scenario test files are **new files** created in `test/protocol/`, `test/driver/`, `test/archive/`, `test/cluster/`. They import `src/aeron.zig` as the library under test. Each directory gets its own root test file that `@import`s the scenario files.

Add these steps to `build.zig` (follow the existing `test-unit` / `test-integration` pattern):

```zig
// Zig 0.15.2 API — use b.path() not .{ .path = "..." }
const test_protocol = b.addTest(.{
    .root_source_file = b.path("test/protocol/frame_codec_test.zig"),
    .target = target,
    .optimize = optimize,
});
test_protocol.root_module.addImport("aeron", aeron_mod);
const run_test_protocol = b.addRunArtifact(test_protocol);

// repeat for driver, archive, cluster
```

Add a top-level `test-scenarios` step that depends on all four run steps.

New `make` targets (add to Makefile after existing `test-integration` target):

```makefile
test-protocol:  ## Run protocol scenario tests
	nix develop --command zig build test-protocol

test-driver:    ## Run driver scenario tests
	nix develop --command zig build test-driver

test-archive:   ## Run archive scenario tests
	nix develop --command zig build test-archive

test-cluster:   ## Run cluster scenario tests
	nix develop --command zig build test-cluster

test-scenarios: test-protocol test-driver test-archive test-cluster  ## Run all scenario tests
```

Update `make check` to include `test-scenarios`:

```makefile
check: fmt-check build test test-scenarios lesson-lint  ## Full check: fmt + build + all tests
```

### UPSTREAM_MAP.md format

`test/UPSTREAM_MAP.md` uses this schema:

```markdown
# Upstream Test Map
<!-- Status: [ ] = not started, [~] = partial, [x] = complete -->

## Protocol

| Our test file | Upstream class | Upstream path | Status |
|---|---|---|---|
| `test/protocol/frame_codec_test.zig` | `DataHeaderFlyweightTest` | `aeron-client/src/test/java/io/aeron/` | [ ] |
...
```

Update status to `[~]` when partially ported, `[x]` when all scenarios from that upstream class are covered.

---

## Aeron Version Pin

All Java interop uses **Aeron 1.46.7** (already pinned in `Makefile`).

Reference test classes fetched from:
`https://github.com/aeron-io/aeron/tree/1.46.7/`

---

## Success Criteria

- [ ] All rows in `test/UPSTREAM_MAP.md` show status `[x]`
- [ ] `ci.yml` `zig-test` job green on ubuntu + macos
- [ ] `interop.yml` `interop-smoke` green on every PR
- [ ] `make check` includes `test-scenarios` and passes
- [ ] `k8s/` retained at root; no k8s references in CI workflows
- [ ] `deploy/interop/`, `test/stress/`, `test/interop/` deleted

---

## References

- Upstream test classes: `https://github.com/aeron-io/aeron/tree/1.46.7/`
- TigerBeetle CI pattern: `https://github.com/tigerbeetle/tigerbeetle/blob/main/.github/workflows/ci.yml`
- xev nix+zig CI: `https://github.com/mitchellh/libxev/blob/main/.github/workflows/test.yml`
- Parity audit: `.agents/PARITY_AUDIT.md`
