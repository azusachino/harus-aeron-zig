# Phase 7 — Parity & Hardening Plan

**Goal:** move from a working v1.0.0 baseline to a more complete Aeron-compatible platform with stronger transport coverage, reverse interop, archive/cluster parity, and better production hardening.

**Primary reference:** https://github.com/aeron-io/aeron

---

## Milestone Map

| Milestone | Goal | Gate | Notes |
|-----------|------|------|-------|
| M7-1 | Driver hardening and test stability | `make check` | Remove the most fragile runtime behavior without regressing the current interop path. |
| M7-2 | Transport breadth | `make test-unit` then `make check` | Expand URI and socket coverage before adding more integration surface. |
| M7-3 | Reverse interop | `AERON_INTEROP=1 make test-interop` | Prove Zig publisher -> Java subscriber alongside the current Java publisher -> Zig subscriber path. |
| M7-4 | Archive parity | `make check` | Move archive control and replay toward upstream Aeron behavior. |
| M7-5 | Cluster parity | `make check` | Continue the cluster stack after archive foundations are less simplified. |
| M7-6 | Stress and failure modes | `make stress` then `make check` | Validate repeated churn, invalid packets, and lifecycle races. |

---

## Execution Tracking

| ID | Area | Milestone | Status | Files |
|----|------|-----------|--------|-------|
| P7-1 | Hardening | M7-1 | pending | `src/driver/conductor.zig`, `src/driver/receiver.zig`, `src/driver/sender.zig` |
| P7-2 | Transport | M7-2 | pending | `src/transport/uri.zig`, `src/transport/udp_channel.zig`, `src/transport/endpoint.zig` |
| P7-3 | Interop | M7-3 | pending | `test/interop/`, `deploy/interop/` |
| P7-4 | Archive | M7-4 | pending | `src/archive/`, `docs/tutorial/05-archive/` |
| P7-5 | Cluster | M7-5 | pending | `src/cluster/`, `docs/tutorial/06-cluster/` |
| P7-6 | Stress | M7-6 | pending | `test/stress/`, `src/driver/`, `src/ipc/` |

---

## Task Prompts

### P7-1: Driver Hardening

**Task:** Remove the remaining runtime fragility from the driver hot path while preserving the current interop behavior.

**Lane:** hardening

**Milestone:** M7-1

**Files to modify:**
- `src/driver/conductor.zig`
- `src/driver/receiver.zig`
- `src/driver/sender.zig`

**Files to create:** none

**Acceptance criteria:**
- `make check`
- `AERON_INTEROP=1 make test-interop`

**Work items:**
1. Replace remaining hot-path debug prints with structured logging or gated diagnostics.
2. Stop swallowing errors in driver paths unless the failure is explicitly expected.
3. Tighten ownership and lifecycle handling for embedded vs standalone driver use.
4. Preserve the current interop path while reducing runtime fragility.

**Suggested verification order:**
1. `make test-unit`
2. `make check`
3. `AERON_INTEROP=1 make test-interop`

### P7-2: Transport Breadth

**Task:** Expand Aeron URI parsing and socket coverage beyond the current happy path.

**Lane:** transport

**Milestone:** M7-2

**Files to modify:**
- `src/transport/uri.zig`
- `src/transport/udp_channel.zig`
- `src/transport/endpoint.zig`

**Files to create:** none

**Acceptance criteria:**
- `make test-unit`
- `make check`

**Work items:**
1. Expand URI parsing for more Aeron-compatible endpoint forms.
2. Cover more multicast and interface combinations.
3. Add tests for channel forms used in upstream Aeron samples.
4. Keep the current UDP behavior stable while broadening accepted inputs.

**Suggested verification order:**
1. `make test-unit`
2. `make check`

### P7-3: Reverse Interop

**Task:** Add the missing Zig publisher -> Java subscriber smoke test.

**Lane:** interop

**Milestone:** M7-3

**Files to modify:**
- `test/interop/run.sh`
- `test/interop/docker-compose.yml`

**Files to create:**
- `test/interop/reverse-compose.yml`
- `test/interop/zig_publisher.zig`
- `test/interop/JavaSubscriber.java`

**Acceptance criteria:**
- `AERON_INTEROP=1 make test-interop`

**Work items:**
1. Keep the Java publisher -> Zig subscriber path intact.
2. Add Zig publisher -> Java subscriber coverage.
3. Make the smoke test matrix explicit rather than one-directional.
4. Keep the Docker build context minimal and deterministic.

**Suggested verification order:**
1. `make check`
2. `AERON_INTEROP=1 make test-interop`

### P7-4: Archive Parity

**Task:** Move the archive stack closer to upstream Aeron behavior.

**Lane:** archive

**Milestone:** M7-4

**Files to modify:**
- `src/archive/`

**Files to create:**
- `docs/tutorial/05-archive/07-parity.md`

**Acceptance criteria:**
- `make check`

**Work items:**
1. Move archive control messages toward the upstream Aeron archive protocol shape.
2. Replace in-memory replay assumptions with file-backed replay.
3. Make recording metadata and listing behave like a real archive service.
4. Add tests for the archive control and replay path.

**Suggested verification order:**
1. `make test-unit`
2. `make check`

### P7-5: Cluster Parity

**Task:** Continue the cluster stack once archive behavior is less simplified.

**Lane:** cluster

**Milestone:** M7-5

**Files to modify:**
- `src/cluster/`
- `docs/tutorial/06-cluster/`

**Files to create:** none

**Acceptance criteria:**
- `make check`

**Work items:**
1. Fill in the remaining cluster lifecycle and recovery paths.
2. Add snapshot/rejoin/replay coverage.
3. Reduce the gap between the current cluster model and upstream Aeron.
4. Add tests for the cluster state machine and recovery behavior.

**Suggested verification order:**
1. `make test-unit`
2. `make check`

### P7-6: Stress and Failure Modes

**Task:** Add stress coverage for repeated churn and invalid network input.

**Lane:** stress

**Milestone:** M7-6

**Files to modify:**
- `test/stress/`
- `src/driver/`
- `src/ipc/`

**Files to create:** none

**Acceptance criteria:**
- `make stress`
- `make check`

**Work items:**
1. Add stress coverage for concurrent publication/subscription churn.
2. Exercise setup retransmit, duplicate setup handling, and invalid packet handling.
3. Keep the receiver and sender stable under repeated driver churn.
4. Add regressions for the failures already found during interop bring-up.

**Suggested verification order:**
1. `make stress`
2. `make check`

---

## Suggested Sequence

1. P7-1 hardening.
2. P7-2 transport breadth.
3. P7-3 reverse interop.
4. P7-6 stress and failure modes.
5. P7-4 archive parity.
6. P7-5 cluster parity.

This order keeps the repository focused on transport correctness and runtime stability before expanding the scope into archive and cluster behavior.

