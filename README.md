# harus-aeron-zig

Aeron reimplemented in Zig — wire-compatible with the real [Aeron](https://github.com/aeron-io/aeron)
UDP protocol. Also a structured course for learning both Aeron internals and Zig systems programming.

## What Is Aeron?

Aeron is a high-performance messaging system built on UDP. It delivers reliable, low-latency
unicast and multicast transport via memory-mapped log buffers and NAK-based retransmission —
no brokers, no overhead, just bytes and math.

## What Is This Repo?

Two things at once:

| Path | What it is |
|------|-----------|
| `src/` | Reference implementation — always compiles, always passes `make check` |
| `tutorial/` | Learner workspace — stubs to implement, tests to pass |
| `docs/tutorial/` | Course chapters — one per module, Aeron concept + Zig concept + exercise |

## Roadmap

- **Phase 1 — Media Driver**: full pub/sub over UDP, wire-compatible with Java/C++ Aeron
- **Phase 2 — Archive**: record and replay streams via `aeron-archive`
- **Phase 3 — Cluster**: Raft-based consensus via `aeron-cluster`

See [`docs/plan.md`](docs/plan.md) for the full task breakdown.

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
