# Tutorial Course Design — harus-aeron-zig

**Date**: 2026-03-17
**Status**: Draft

---

## Overview

`harus-aeron-zig` is both a working Aeron implementation and a structured course for
learning Aeron protocol internals and Zig systems programming simultaneously. The audience
is experienced engineers from C/C++/Rust, Zig, Go, or Java backgrounds who want to learn
either Zig or Aeron internals — or both.

---

## Format

**Mix of two delivery mechanisms:**

1. **`docs/tutorial/` chapters** — structured markdown chapters, one per source module,
   organized as a book in 6 parts.

2. **`// LESSON(slug):` inline annotations** in source — medium density (every significant
   struct and function), bridging code to the relevant chapter.

**Exercise model** (Pattern C — mini-lsm style): `src/` is the full reference implementation.
`tutorial/` mirrors `src/` with stub bodies and pre-written failing tests. Git tags mark
chapter checkpoints; learners work in `tutorial/` and compare against `src/` when stuck.

---

## Learning Progression: Spiral

1. **Part 0 — Orientation**: run a working demo end-to-end *before* implementing anything.
   Learner sees the full system alive, then understands *why* each piece exists as they build it.
2. **Parts 1–4 — Bottom-up**: implement foundations → data path → driver → client library.
3. **Parts 5–6 — Archive + Cluster**: build on the working driver.

---

## Course Structure

```
docs/tutorial/
├── README.md                        ← entry point, navigation, prerequisites
├── 00-orientation/
│   ├── 01-what-is-aeron.md          ← the problem Aeron solves; why UDP; why shared memory
│   ├── 02-what-is-zig.md            ← Zig mental model for C/Rust/Go/Java engineers
│   ├── 03-system-tour.md            ← architecture diagram; how all pieces fit together
│   └── 04-first-pubsub.md           ← run the demo; see pub/sub work before implementing
├── 01-foundations/
│   ├── 01-frame-codec.md            ← UDP wire framing + extern struct + comptime assertions
│   ├── 02-ring-buffer.md            ← client→driver IPC + atomics + lock-free patterns
│   ├── 03-broadcast.md              ← driver→client notifications + function pointers
│   ├── 04-counters.md               ← flow control positions + cache-line alignment
│   └── 05-log-buffer.md             ← three-term ring structure + mmap + slice views
├── 02-data-path/
│   ├── 01-term-appender.md          ← CAS tail advance + compare-and-swap loops
│   ├── 02-term-reader.md            ← fragment scanning + *anyopaque callbacks
│   └── 03-udp-transport.md          ← unicast + multicast + std.posix sockets
├── 03-driver/
│   ├── 01-sender.md                 ← duty-cycle pattern + std.Thread + busy-spin
│   ├── 02-receiver.md               ← NAK + flow control + !T error handling
│   ├── 03-conductor.md              ← command/control + tagged unions + state machines
│   └── 04-media-driver.md           ← agent orchestration + comptime interfaces
├── 04-client/
│   ├── 01-publications.md           ← offer + back-pressure + enum return types
│   ├── 02-subscriptions.md          ← polling + fragment reassembly + std.ArrayList
│   └── 03-integration-tests.md      ← wire compatibility against real Java Aeron
├── 05-archive/
│   ├── 01-archive-protocol.md       ← P2-1: recording control protocol + SBE encoding
│   ├── 02-catalog.md                ← P2-2: persistent recording catalog + flat binary files
│   ├── 03-recorder.md               ← P2-3: recording sessions + file I/O + segment rotation
│   ├── 04-replayer.md               ← P2-4: replay sessions + publication from file
│   ├── 05-archive-conductor.md      ← P2-5: archive command/control loop
│   └── 06-archive-main.md           ← P2-6: ArchiveContext + standalone binary
└── 06-cluster/
    ├── 01-cluster-protocol.md       ← P3-1: session + consensus protocol messages
    ├── 02-election.md               ← P3-2: Raft leader election state machine
    ├── 03-log-replication.md        ← P3-3: append/commit log + follower ACK
    ├── 04-cluster-conductor.md      ← P3-4: client sessions + service interface
    └── 05-cluster-main.md           ← P3-5: ClusterContext + ConsensusModule + binary
```

---

## Chapter Template

Every chapter follows this structure:

```markdown
# Chapter N: [Title]

## The Problem
One paragraph: what Aeron needs this module for. No code yet.

## Aeron Concept: [X]
How real Aeron handles it. Reference to upstream source in aeron-io/aeron.
Diagrams where helpful (see Diagrams section below).

## Zig Concept: [Y]
The Zig feature this module exercises, explained from first principles.
Short standalone example (not Aeron-specific).
Bridges from C / Rust / Go / Java where the concept has an analogue.

## Implementation Walkthrough
Walk through the actual source file in src/, pointing at LESSON blocks.
Explain non-obvious decisions (why CAS not mutex, why extern not packed, etc.)

## Exercise
One function to implement in `tutorial/`. Signature + failing test pre-written.
Run `make tutorial-check` to verify. Compare against `src/` or `git diff chapter-NN` when stuck.

## Further Reading
Upstream Aeron source links, Zig stdlib source, relevant papers.
```

---

## LESSON Comment Format

**Placement**: on every significant struct and function (medium density — not every line,
but every place where "why is it done this way?" is non-obvious). Skip private helpers under
10 lines unless they encode a non-obvious tradeoff; those can be explained inline by the
surrounding LESSON block.

**Format**:
```zig
// LESSON(chapter-slug): explanation of the concept this code represents.
// Why this approach was chosen over alternatives.
// See docs/tutorial/part/chapter.md for the full walkthrough.
```

**Example**:
```zig
// LESSON(ring-buffer): The tail is stored as an absolute byte offset, not an index.
// This avoids the ABA problem on wrap-around. At 1GB/s throughput a 64-bit counter
// would take ~585 years to overflow — safe to treat as unbounded.
// See docs/tutorial/01-foundations/02-ring-buffer.md
pub fn write(self: *ManyToOneRingBuffer, msg_type_id: i32, data: []const u8) bool {
```

---

## Concept Mapping (Aeron ↔ Zig ↔ Background Bridge)

| Chapter | Aeron Concept | Zig Concept | Bridge From |
|---------|--------------|-------------|-------------|
| 0.2 | — | Zig mental model | C: no hidden alloc; Rust: no borrow checker; Go: no goroutine scheduler; Java: no GC |
| 1.1 | UDP wire framing | `extern struct`, comptime size assertions | C: `__attribute__((packed))`; Rust: `#[repr(C)]`; Go: `encoding/binary`; Java: `ByteBuffer` |
| 1.2 | Client→driver IPC | `@atomicLoad`, `@cmpxchgStrong` | C: `_Atomic`; Rust: `std::sync::atomic`; Go: `sync/atomic`; Java: `AtomicLong` |
| 1.3 | Driver→client notifications | `*const fn`, `*anyopaque` | C: function pointers; Rust: `fn` types; Go: `func` values; Java: lambdas |
| 1.4 | Flow control positions | Cache-line alignment, `@alignOf` | C: `__attribute__((aligned))`; Rust: `#[repr(align)]`; Go: `unsafe.Alignof` |
| 1.5 | Three-term log buffer | `std.posix.mmap`, slice views | C: `mmap(2)`; Rust: `memmap2`; Go: `golang.org/x/sys/unix`; Java: `MappedByteBuffer` |
| 2.1 | Atomic tail advance | CAS loops, retry patterns | C: `__sync_bool_compare_and_swap`; Rust: `compare_exchange`; Go: `sync/atomic.CompareAndSwap`; Java: `compareAndSet` |
| 2.2 | Fragment scanning | Callbacks, `*anyopaque` context | C: `void*` callbacks; Rust: trait objects; Go: `interface{}`; Java: interfaces |
| 2.3 | Unicast + multicast UDP | `std.posix` sockets, `std.net.Address` | C: BSD sockets; Go: `net.UDPConn`; Java: `DatagramSocket` |
| 3.1 | Duty-cycle sender | `std.Thread`, busy-spin | C: pthreads; Rust: `std::thread`; Go: goroutines; Java: `Thread` |
| 3.2 | NAK + flow control | `!T`, `errdefer`, error sets | C: return codes; Rust: `Result`; Go: `(T, error)`; Java: exceptions |
| 3.3 | Command/control | Tagged unions, exhaustive `switch` | C: enum+union; Rust: `enum`; Go: type switch; Java: sealed classes |
| 3.4 | Agent orchestration | `comptime`, interfaces without vtables | Rust: traits; Go: interfaces; Java: interfaces |
| 4.1 | Back-pressure | Sentinel enum return types | C: magic ints; Rust: `Result`/`Option`; Go: sentinel errors |
| 4.2 | Fragment reassembly | Slices, `std.ArrayList` | C: dynamic arrays; Rust: `Vec`; Go: slices; Java: `List` |
| 4.3 | Wire compatibility | Test harness, `std.testing` | C: cmocka; Rust: `#[test]`; Go: `testing.T`; Java: JUnit |

---

## Exercise Model (Pattern C — mini-lsm style)

Two parallel trees in the same repo on `main`:

- **`src/`** — full reference implementation; always compiles, always passes `make check`
- **`tutorial/`** — mirrors `src/` structure; stub bodies are `@panic("TODO: implement")`
  with pre-written failing tests; this is where learners work

```
tutorial/
├── protocol/frame.zig       ← stub + EXERCISE comment
├── logbuffer/log_buffer.zig
├── ipc/ring_buffer.zig
└── ...                      ← mirrors src/ exactly
```

**Git tags per chapter**: after each chapter's reference implementation lands in `src/`,
tag `main` as `chapter-NN-slug` (e.g. `chapter-01-frame-codec`). Learners can:
- `git diff chapter-01-frame-codec chapter-02-ring-buffer` — see exactly what changed
- `git checkout chapter-01-frame-codec` — start from the repo state at that chapter

**Build flag**: `zig build -Dchapter=N` scopes which tutorial tests are active so CI stays
green on unsolved stubs. Chapters above N are excluded from the test run.

**CI split**:
- `make check` — tests `src/` only (always green on `main`)
- `make tutorial-check` — compile-checks `tutorial/` stubs (must at least compile)

**Learner workflow**:
1. Work in `tutorial/` — fill in stubs until `make tutorial-check` passes
2. Compare against `src/` or `git diff chapter-NN-slug` when stuck
3. No branch switching — everything lives on `main`

**Exercises are sized for ~30-60 minutes of focused work.**

---

## Diagrams

- **Inline Mermaid** (preferred): use fenced ` ```mermaid ` blocks directly in `.md` files
  for flow diagrams, state machines, and sequence diagrams — renders on GitHub and most
  markdown viewers without extra tooling
- **Static images** (fallback): PNG/SVG files stored in `docs/tutorial/assets/`; reference
  via relative path `![alt](../assets/filename.png)`; use only when Mermaid cannot represent
  the visual (e.g. packet layout diagrams)

---

## Reference Material

### Upstream Aeron Implementation
| Resource | URL |
|----------|-----|
| Main repo (C++ driver + Java client) | https://github.com/aeron-io/aeron |
| UDP protocol headers (C) | `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h` |
| LogBuffer descriptor (Java) | `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java` |
| TermAppender (Java) | `aeron-client/src/main/java/io/aeron/logbuffer/TermAppender.java` |
| TermReader (Java) | `aeron-client/src/main/java/io/aeron/logbuffer/TermReader.java` |
| ManyToOneRingBuffer (Java) | `aeron-driver/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java` |
| BroadcastTransmitter (Java) | `aeron-driver/src/main/java/org/agrona/concurrent/broadcast/BroadcastTransmitter.java` |
| DriverConductor (Java) | `aeron-driver/src/main/java/io/aeron/driver/DriverConductor.java` |
| Sender (Java) | `aeron-driver/src/main/java/io/aeron/driver/Sender.java` |
| Receiver (Java) | `aeron-driver/src/main/java/io/aeron/driver/Receiver.java` |
| Archive (Java) | `aeron-archive/src/main/java/io/aeron/archive/` |
| Cluster / Election (Java) | `aeron-cluster/src/main/java/io/aeron/cluster/Election.java` |

### Zig References
| Resource | URL |
|----------|-----|
| Zig 0.15.2 std docs | https://ziglang.org/documentation/0.15.2/ |
| Zig stdlib source | https://codeberg.org/ziglang/zig/src/tag/0.15.2/lib/std |
| Zig atomics | `std.atomic` — `@atomicLoad`, `@atomicStore`, `@cmpxchgStrong` |

### Course Design Inspiration
| Resource | Notes |
|----------|-------|
| mini-lsm (skyzh) | Pattern C source: `src/` reference + `tutorial/` stubs + chapter git tags |
| rustlings | Pattern A reference: parallel `exercises/` + `solutions/` |
| ziglings | Pattern A in Zig; good chapter slug naming conventions |

---

## Agent Context

Any agent working on this project should know:

- **Two code trees**: `src/` = reference (always green), `tutorial/` = learner stubs (compile-only check)
- **Chapter tags**: `chapter-NN-slug` git tags are the checkpoint story — tag after every chapter merges
- **LESSON format**: `// LESSON(chapter-slug): why. See docs/tutorial/part/chapter.md`
- **Exercise format**: stub body is `@panic("TODO: implement")`, test is pre-written, both committed to `main`
- **CI**: `make check` tests `src/`; `make tutorial-check` compile-checks `tutorial/`
- **Tutorial chapters written last**: implement `src/` first, write `docs/tutorial/` chapter after
- **Build flag**: `zig build -Dchapter=N` scopes tutorial test activation
- **Spec location**: `docs/specs/2026-03-17-tutorial-course-design.md`
- **Implementation plan**: `docs/plan.md` (Phase 1–3 tasks with full task specs)

---

## What This Is NOT

- Not a beginner programming course — assumes fluency in at least one systems language
- Not a reference manual — the Aeron Java/C++ docs fill that role
- Not a performance tuning guide — the focus is understanding, not optimizing

---

## Implementation Notes for Authors

- All LESSON blocks use the slug of the chapter they link to
- Source files come first; tutorial chapters are written after the implementation is complete
- Chapters should be written as if speaking to the reader: "notice how...", "you might wonder..."
- Each chapter's "Zig Concept" section must show a standalone example before the Aeron-specific one
- After each chapter merges to `main`, tag it `chapter-NN-slug` immediately — tags are the checkpoint story
- `tutorial/` stubs must always compile even unsolved; `@panic("TODO: implement")` not `undefined`
