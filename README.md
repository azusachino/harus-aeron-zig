# harus-aeron-zig

Aeron reimplemented in Zig — wire-compatible with the real [Aeron](https://github.com/aeron-io/aeron)
UDP protocol. Also a structured course for learning both Aeron internals and Zig systems programming.

## What Is Aeron?

Aeron is a high-performance messaging system built on UDP. It delivers reliable, low-latency
unicast and multicast transport via memory-mapped log buffers and NAK-based retransmission —
no brokers, no overhead, just bytes and math.

## Project Status: v1.0.0

`harus-aeron-zig` is a **complete, wire-compatible implementation of the Aeron messaging protocol**.
All three phases are production-ready:

- **Phase 1-4**: Media Driver (Conductor, Sender, Receiver agents) + Client API (Publication/Subscription)
- **Phase 5**: Archive (recording, replay, catalog persistence)
- **Phase 6**: Cluster (Raft consensus, replicated state machine)

See [`docs/plan-phase6.md`](docs/plan-phase6.md) for the complete v1.0 implementation roadmap and
[`docs/audit-2026-03-23.md`](docs/audit-2026-03-23.md) for wire-compatibility audit against Aeron 1.44.1.

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
- **Interoperability**: Verified against the Java Aeron driver via Docker smoke tests.

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
- **Reference**: [aeron-io/aeron](https://github.com/aeron-io/aeron)
