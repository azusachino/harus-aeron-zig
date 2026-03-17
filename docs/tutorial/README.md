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

**The loop for each chapter:**
1. Read the chapter doc in `docs/tutorial/`
2. Fill in the stub in `tutorial/` until `make tutorial-check` passes
3. Compare against `src/` or `git diff chapter-NN-slug` when stuck

---

## Course Map

### Part 0 — Orientation *(start here)*

Before writing a line, understand the system and see it run.

| Chapter | File | What you'll learn |
|---------|------|-------------------|
| [0.1 What is Aeron?](00-orientation/01-what-is-aeron.md) | — | Why UDP? Why shared memory? What problem Aeron solves |
| [0.2 What is Zig?](00-orientation/02-what-is-zig.md) | — | Zig mental model for C/Rust/Go/Java engineers |
| [0.3 System Tour](00-orientation/03-system-tour.md) | — | Architecture diagram — how all pieces fit together |
| [0.4 First Pub/Sub](00-orientation/04-first-pubsub.md) | — | Run the demo end-to-end before implementing anything |

### Part 1 — Foundations *(parallel — no deps between chapters)*

The building blocks. Each chapter is independent; tackle them in any order.

| Chapter | `src/` file | `tutorial/` stub | Aeron concept | Zig concept |
|---------|------------|-----------------|---------------|-------------|
| [1.1 Frame Codec](01-foundations/01-frame-codec.md) | `src/protocol/frame.zig` | `tutorial/protocol/frame.zig` | UDP wire framing | `extern struct`, comptime assertions |
| [1.2 Ring Buffer](01-foundations/02-ring-buffer.md) | `src/ipc/ring_buffer.zig` | `tutorial/ipc/ring_buffer.zig` | Client→driver IPC | Atomics, `@cmpxchgStrong` |
| [1.3 Broadcast](01-foundations/03-broadcast.md) | `src/ipc/broadcast.zig` | `tutorial/ipc/broadcast.zig` | Driver→client notifications | `*const fn`, `*anyopaque` |
| [1.4 Counters](01-foundations/04-counters.md) | `src/ipc/counters.zig` | `tutorial/ipc/counters.zig` | Flow control positions | Cache-line alignment, `@alignOf` |
| [1.5 Log Buffer](01-foundations/05-log-buffer.md) | `src/logbuffer/log_buffer.zig` | `tutorial/logbuffer/log_buffer.zig` | Three-term ring structure | `std.posix.mmap`, slice views |

### Part 2 — Data Path *(sequential)*

How data actually moves through the log buffer.

| Chapter | `src/` file | `tutorial/` stub | Aeron concept | Zig concept |
|---------|------------|-----------------|---------------|-------------|
| [2.1 Term Appender](02-data-path/01-term-appender.md) | `src/logbuffer/term_appender.zig` | `tutorial/logbuffer/term_appender.zig` | Atomic tail advance | CAS loops, retry patterns |
| [2.2 Term Reader](02-data-path/02-term-reader.md) | `src/logbuffer/term_reader.zig` | `tutorial/logbuffer/term_reader.zig` | Fragment scanning | Callbacks, `*anyopaque` context |
| [2.3 UDP Transport](02-data-path/03-udp-transport.md) | `src/transport/udp_channel.zig` | `tutorial/transport/udp_channel.zig` | Unicast + multicast | `std.posix` sockets, `std.net.Address` |

### Part 3 — The Driver *(sequential)*

The three agents that make up the media driver process.

| Chapter | `src/` file | `tutorial/` stub | Aeron concept | Zig concept |
|---------|------------|-----------------|---------------|-------------|
| [3.1 Sender](03-driver/01-sender.md) | `src/driver/sender.zig` | `tutorial/driver/sender.zig` | Duty-cycle sender | `std.Thread`, busy-spin |
| [3.2 Receiver](03-driver/02-receiver.md) | `src/driver/receiver.zig` | `tutorial/driver/receiver.zig` | NAK + flow control | `!T`, `errdefer`, error sets |
| [3.3 Conductor](03-driver/03-conductor.md) | `src/driver/conductor.zig` | `tutorial/driver/conductor.zig` | Command/control | Tagged unions, exhaustive `switch` |
| [3.4 Media Driver](03-driver/04-media-driver.md) | `src/driver/media_driver.zig` | `tutorial/driver/media_driver.zig` | Agent orchestration | `comptime`, interfaces without vtables |

### Part 4 — Client Library *(sequential)*

The API a user calls to publish and subscribe.

| Chapter | `src/` file | `tutorial/` stub | Aeron concept | Zig concept |
|---------|------------|-----------------|---------------|-------------|
| [4.1 Publications](04-client/01-publications.md) | `src/publication.zig` | `tutorial/publication.zig` | Back-pressure, offer | Sentinel enum return types |
| [4.2 Subscriptions](04-client/02-subscriptions.md) | `src/subscription.zig` | `tutorial/subscription.zig` | Fragment reassembly | Slices, `std.ArrayList` |
| [4.3 Integration Tests](04-client/03-integration-tests.md) | `test/` | — | Wire compatibility | `std.testing`, test harness |

### Part 5 — Archive *(requires Part 4)*

Record and replay Aeron streams.

| Chapter | Aeron concept |
|---------|--------------|
| [5.1 Archive Protocol](05-archive/01-archive-protocol.md) | Recording control protocol |
| [5.2 Catalog](05-archive/02-catalog.md) | Persistent recording catalog |
| [5.3 Recorder](05-archive/03-recorder.md) | Recording sessions + file I/O |
| [5.4 Replayer](05-archive/04-replayer.md) | Replay from recording file |
| [5.5 Archive Conductor](05-archive/05-archive-conductor.md) | Archive command loop |
| [5.6 Archive Main](05-archive/06-archive-main.md) | Standalone archive binary |

### Part 6 — Cluster *(requires Part 5)*

Raft-based consensus for state machine replication.

| Chapter | Aeron concept |
|---------|--------------|
| [6.1 Cluster Protocol](06-cluster/01-cluster-protocol.md) | Session + consensus messages |
| [6.2 Election](06-cluster/02-election.md) | Raft leader election |
| [6.3 Log Replication](06-cluster/03-log-replication.md) | Append/commit + follower ACK |
| [6.4 Cluster Conductor](06-cluster/04-cluster-conductor.md) | Client sessions + service interface |
| [6.5 Cluster Main](06-cluster/05-cluster-main.md) | ConsensusModule + binary |

---

## Commands

```bash
make tutorial-check   # compile-check your tutorial/ stubs
make check            # verify the reference implementation (src/)
git diff chapter-01-frame-codec chapter-02-ring-buffer  # see what changed
```

---

## References

### Upstream Aeron
- **Repo**: https://github.com/aeron-io/aeron
- **Protocol headers (C)**: `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h`
- **LogBuffer descriptor (Java)**: `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java`
- **Agrona (ring buffer, broadcast, counters)**: `aeron-driver/src/main/java/org/agrona/concurrent/`

### Zig
- **Docs**: https://ziglang.org/documentation/0.15.0/
- **Stdlib source**: https://github.com/ziglang/zig/tree/0.15.0/lib/std

### Course Design Inspiration
- **mini-lsm** (skyzh) — Pattern C: `src/` reference + `tutorial/` stubs + chapter git tags
- **ziglings** — chapter slug naming conventions
- **rustlings** — parallel exercises/solutions structure (Pattern A, not used here)
