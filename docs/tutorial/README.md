# Aeron in Zig — Tutorial

Learn Aeron protocol internals and Zig systems programming by building Aeron from scratch.

**Audience**: experienced engineers from C/C++/Rust, Go, or Java backgrounds.
**Prerequisite**: fluency in at least one systems language. No Zig or Aeron experience needed.

---

## How This Works

This repo contains two things at once:

| Path | What it is |
|------|-----------|
| `src/` | Full reference implementation — always compiles, always passes `make check` |
| `tutorial/` | Your workspace — stubs with `@panic("TODO: implement")` and pre-written tests |
| `docs/tutorial/` | Chapter docs — one per module, read before touching code |

---

## Choose Your Track

You can read this tutorial from two different perspectives:

### Track A: "I'm learning Zig"
Focus on the **ZIG:** annotations in the source and the **Zig Track** sections in the docs. You'll learn:
- How to use `std.posix` for low-level socket and file I/O.
- Lock-free programming with atomics and `@cmpxchgStrong`.
- Explicit memory management with the `Allocator` API.
- C-interop with `extern struct` and pointer arithmetic.

### Track B: "I'm learning Aeron"
Focus on the **AERON:** annotations in the source and the **Aeron Track** sections in the docs. You'll learn:
- The Aeron wire protocol and frame layouts.
- Reliable UDP delivery via SETUP/STATUS and NAK retransmissions.
- High-performance shared-memory IPC via ring buffers and broadcast.
- Consensus and replication with Aeron Cluster (Raft).

---

## Course Map

### Part 0 — Orientation

| Chapter | File | What you'll learn |
|---------|------|-------------------|
| [0.1 What is Aeron?](00-orientation/01-what-is-aeron.md) | — | Why UDP? Why shared memory? Aeron's "Why" |
| [0.2 What is Zig?](00-orientation/02-what-is-zig.md) | — | Zig's philosophy for systems engineers |
| [0.3 System Tour](00-orientation/03-system-tour.md) | — | High-level architecture and data flow |
| [0.4 First Pub/Sub](00-orientation/04-first-pubsub.md) | — | Run the demo end-to-end |

### Part 1 — Foundations *(Parallel)*

| Chapter | `src/` file | Aeron concept | Zig concept |
|---------|------------|---------------|-------------|
| [1.1 Frame Codec](01-foundations/01-frame-codec.md) | `src/protocol/frame.zig` | Wire framing | `extern struct` |
| [1.2 Ring Buffer](01-foundations/02-ring-buffer.md) | `src/ipc/ring_buffer.zig` | Client→Driver IPC | Atomics |
| [1.3 Broadcast](01-foundations/03-broadcast.md) | `src/ipc/broadcast.zig` | Driver→Client Event | `*anyopaque` |
| [1.4 Counters](01-foundations/04-counters.md) | `src/ipc/counters.zig` | Positions & Stats | Cache-alignment |
| [1.5 Log Buffer](01-foundations/05-log-buffer.md) | `src/logbuffer/log_buffer.zig` | 3-partition term | `mmap` views |

### Part 2 — Data Path *(Sequential)*

| Chapter | `src/` file | Aeron concept | Zig concept |
|---------|------------|---------------|-------------|
| [2.1 Term Appender](02-data-path/01-term-appender.md) | `src/logbuffer/term_appender.zig` | Atomic tail advance | CAS loops |
| [2.2 Term Reader](02-data-path/02-term-reader.md) | `src/logbuffer/term_reader.zig` | Fragment scanning | Callbacks |
| [2.3 UDP Transport](02-data-path/03-udp-transport.md) | `src/transport/udp_channel.zig` | URIs & Multicast | `std.posix` |

### Part 3 — The Driver *(Sequential)*

| Chapter | `src/` file | Aeron concept | Zig concept |
|---------|------------|---------------|-------------|
| [3.1 Sender](03-driver/01-sender.md) | `src/driver/sender.zig` | Retransmissions | `std.Thread` |
| [3.2 Receiver](03-driver/02-receiver.md) | `src/driver/receiver.zig` | NAK & Flow control | Error sets |
| [3.3 Conductor & CnC](03-driver/03-conductor.md) | `src/driver/conductor.zig` | Resource lifecycle | `mmap` layout |
| [3.4 Media Driver](03-driver/04-media-driver.md) | `src/driver/media_driver.zig` | Agent orchestration | `comptime` |

### Part 4 — Client Library *(Sequential)*

| Chapter | `src/` file | Aeron concept | Zig concept |
|---------|------------|---------------|-------------|
| [4.1 Publications](04-client/01-publications.md) | `src/publication.zig` | Back-pressure | Return enums |
| [4.2 Subscriptions](04-client/02-subscriptions.md) | `src/subscription.zig` | Reassembly | `std.ArrayList` |
| [4.3 Integration](04-client/03-integration-tests.md) | `test/` | System testing | `std.testing` |
| [4.4 Interop](04-client/04-interop.md) | — | Cross-language | C-ABI compatibility |

### Part 5 — Archive

| Chapter | Aeron concept |
|---------|--------------|
| [5.1 Archive Protocol](05-archive/01-archive-protocol.md) | SBE messages |
| [5.2 Catalog](05-archive/02-catalog.md) | Persistent state |

### Part 6 — Cluster

| Chapter | Aeron concept |
|---------|--------------|
| [6.1 Consensus Module](06-cluster/01-cluster-protocol.md) | Raft state machine |
| [6.2 Log Replication](06-cluster/03-log-replication.md) | Append/Commit |

---

## Commands

```bash
make tutorial-check   # compile-check your tutorial/ stubs
make check            # verify the reference implementation (src/)
make examples         # build and run example applications
```

---

## References

### Upstream Aeron
- **Repo**: https://github.com/aeron-io/aeron
- **Protocol**: `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h`

### Zig
- **Docs**: https://ziglang.org/documentation/0.15.2/
- **Source**: https://codeberg.org/ziglang/zig/src/tag/0.15.2/lib/std
