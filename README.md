# harus-aeron-zig

Aeron reimplemented in Zig — wire-compatible with the real [Aeron](https://github.com/aeron-io/aeron)
UDP protocol. Also a structured course for learning both Aeron internals and Zig systems programming.

## What Is Aeron?

Aeron is a high-performance messaging system built on UDP. It delivers reliable, low-latency
unicast and multicast transport via memory-mapped log buffers and NAK-based retransmission —
no brokers, no overhead, just bytes and math.

## Project Status: v0.1.0 (Work in Progress)

`harus-aeron-zig` is a **work-in-progress Zig reimplementation of the Aeron messaging protocol**, targeting wire compatibility with [aeron-io/aeron](https://github.com/aeron-io/aeron).
Current parity: protocol frames (100%), archive protocol (100%), IPC (95%), cluster (90%), URI parser (95%).
Not yet production-ready — gaps remain before claiming full upstream compatibility.

- **Phase 1-4**: Media Driver (Conductor, Sender, Receiver agents) + Client API (Publication/Subscription)
- **Phase 5**: Archive (recording, replay, catalog persistence)
- **Phase 6**: Cluster (Raft consensus, replicated state machine)

See [`docs/plan.md`](docs/plan.md) for the complete implementation roadmap.

## What Is This Repo?

Two things at once:

| Path | What it is |
|------|-----------|
| `src/` | Reference implementation — always compiles, always passes `make check` |
| `tutorial/` | Learner workspace — stubs to implement, tests to pass |
| `docs/tutorial/` | Course chapters — one per module, Aeron concept + Zig concept + exercise |

## Features

- **Media Driver**: High-performance duty-cycle agents (Conductor, Sender, Receiver).
- **Client Library**: Publication and Subscription APIs with zero-copy data path.
- **Archive**: Record and replay Aeron streams with persistent catalogs.
- **Cluster**: Raft-based consensus for fault-tolerant state machine replication.
- **Interoperability**: Interop test infrastructure included (`make interop`) — wire compatibility is a work in progress.

## Course Roadmap

The tutorial is divided into 6 parts, following the implementation order:

1. **Foundations**: Frame codecs, lock-free ring buffers, and shared memory counters.
2. **Data Path**: Term appenders, readers, and UDP transport.
3. **The Driver**: Orchestrating the Media Driver agents and CnC.dat.
4. **Client API**: High-level Publication/Subscription handles and Java interop.
5. **Archive**: Control protocols and persistent recording catalogs.
6. **Cluster**: Raft election state machines and replicated log coordination.

Start the course at [`docs/tutorial/README.md`](docs/tutorial/README.md).


## Getting Started

```bash
# Enter dev shell (provides zig 0.15.2, zls, prettier)
nix develop

# Build
make build

# Run tests
make test

# Check your tutorial stubs
make tutorial-check
```

## Tutorial

Start at [`docs/tutorial/README.md`](docs/tutorial/README.md).

The course covers 6 parts — from orientation through cluster — each pairing one Aeron
concept with one Zig concept. Audience: engineers from C/C++/Rust, Go, or Java backgrounds.

## Stack

- **Language**: Zig 0.15.2 (pinned via `flake.lock`)
- **Dev tooling**: Nix devShell (`nix develop`)
- **Task runner**: `make`
- **Interop pin**: Aeron `1.50.2`
- **Reference**: [aeron-io/aeron](https://github.com/aeron-io/aeron)

## Upstream Source

- Preferred source of truth for protocol/spec checks: local `vendor/aeron` when present.
- If `vendor/aeron` is missing or stale, refresh it first with `make setup-upstream-aeron`.
- Shadow clone the official upstream with `make setup-upstream-aeron`.
- Default upstream ref is `release/1.50.x`, cloned into `vendor/aeron`.
- Override if needed: `make setup-upstream-aeron AERON_UPSTREAM_REF=1.50.2`.
- Preferred source of truth for Zig 0.15.2 API/source checks: local `vendor/zig` when present.
- If `vendor/zig` is missing or stale, refresh it with `make setup-upstream-zig`.
- Shadow clone the Zig upstream tag with `make setup-upstream-zig`.
- Default upstream ref is `0.15.2`, cloned into `vendor/zig`.
- Interop jars and upstream test/doc references in this repo are pinned to Aeron `1.50.2`.
