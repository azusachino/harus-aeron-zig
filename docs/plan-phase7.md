# Phase 7 — Parity & Hardening Plan

**Goal:** move from a working v1.0.0 baseline to a more complete Aeron-compatible platform with stronger transport coverage, reverse interop, archive/cluster parity, and better production hardening.

**Primary reference:** https://github.com/aeron-io/aeron

## Execution Tracking

| ID | Area | Status | Files |
|----|------|--------|-------|
| P7-1 | Hardening | pending | `src/driver/conductor.zig`, `src/driver/receiver.zig`, `src/driver/sender.zig` |
| P7-2 | Transport | pending | `src/transport/uri.zig`, `src/transport/udp_channel.zig`, `src/transport/endpoint.zig` |
| P7-3 | Interop | pending | `test/interop/`, `deploy/interop/` |
| P7-4 | Archive | pending | `src/archive/`, `docs/tutorial/05-archive/` |
| P7-5 | Cluster | pending | `src/cluster/`, `docs/tutorial/06-cluster/` |
| P7-6 | Stress | pending | `test/stress/`, `src/driver/`, `src/ipc/` |

## P7-1: Driver Hardening

**Files**
- Modify: `src/driver/conductor.zig`
- Modify: `src/driver/receiver.zig`
- Modify: `src/driver/sender.zig`

**Work**
- Replace remaining hot-path debug prints with structured logging or feature-gated diagnostics.
- Stop swallowing errors in driver paths unless the failure is explicitly expected and handled.
- Tighten ownership and lifecycle handling for embedded vs standalone driver use.
- Keep the existing interop behavior stable while reducing runtime fragility.

**Acceptance**
- `make check`
- `AERON_INTEROP=1 make test-interop`

## P7-2: Transport Breadth

**Files**
- Modify: `src/transport/uri.zig`
- Modify: `src/transport/udp_channel.zig`
- Modify: `src/transport/endpoint.zig`

**Work**
- Expand Aeron URI parsing beyond the current happy path.
- Cover more multicast and interface combinations.
- Add tests for channel forms that upstream Aeron commonly uses.

**Acceptance**
- `make test-unit`
- `make check`

## P7-3: Reverse Interop

**Files**
- Create: `test/interop/reverse-compose.yml`
- Create: `test/interop/zig_publisher.zig`
- Create: `test/interop/JavaSubscriber.java`
- Modify: `test/interop/run.sh`

**Work**
- Add Zig publisher -> Java subscriber coverage.
- Keep the existing Java publisher -> Zig subscriber path intact.
- Make the smoke test matrix explicit rather than relying on one direction only.

**Acceptance**
- `AERON_INTEROP=1 make test-interop`

## P7-4: Archive Parity

**Files**
- Modify: `src/archive/`
- Create: `docs/tutorial/05-archive/07-parity.md`

**Work**
- Move archive control messages toward the upstream Aeron archive protocol shape.
- Replace in-memory replay assumptions with file-backed replay.
- Make recording metadata and listing behave like a real archive service.

**Acceptance**
- Archive unit/integration tests pass.
- `make check`

## P7-5: Cluster Parity

**Files**
- Modify: `src/cluster/`
- Modify: `docs/tutorial/06-cluster/`

**Work**
- Fill in the remaining cluster lifecycle and recovery paths.
- Add snapshot/rejoin/replay coverage.
- Reduce the gap between the current cluster model and the upstream architecture.

**Acceptance**
- Cluster tests pass.
- `make check`

## P7-6: Stress & Failure Modes

**Files**
- Modify: `test/stress/`
- Modify: `src/driver/`
- Modify: `src/ipc/`

**Work**
- Add stress coverage for concurrent publication/subscription churn.
- Exercise setup retransmit, duplicate setup handling, and invalid packet handling.
- Keep the receiver and sender stable under repeated driver churn.

**Acceptance**
- `make stress`
- `make check`

