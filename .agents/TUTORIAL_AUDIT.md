# Tutorial Completeness Audit

**Date**: 2026-03-25
**Auditor**: Research-only pass
**Repository**: harus-aeron-zig

---

## Course Spec Chapters (planned)

From `/Users/azusachino/Projects/project-github/harus-aeron-zig/docs/specs/2026-03-17-tutorial-course-design.md`:

### Part 0 — Orientation (4 chapters)
- 00-01: What is Aeron
- 00-02: What is Zig
- 00-03: System Tour
- 00-04: First Pub/Sub Demo

### Part 1 — Foundations (5 chapters)
- 01-01: Frame Codec (UDP wire framing + extern struct + comptime assertions)
- 01-02: Ring Buffer (client→driver IPC + atomics + lock-free)
- 01-03: Broadcast (driver→client notifications + function pointers)
- 01-04: Counters (flow control positions + cache-line alignment)
- 01-05: Log Buffer (three-term ring + mmap + slice views)

### Part 2 — Data Path (3 chapters)
- 02-01: Term Appender (CAS tail advance + compare-and-swap)
- 02-02: Term Reader (fragment scanning + *anyopaque callbacks)
- 02-03: UDP Transport (unicast + multicast + std.posix sockets)

### Part 3 — Driver (4 chapters)
- 03-01: Sender (duty-cycle pattern + std.Thread + busy-spin)
- 03-02: Receiver (NAK + flow control + !T error handling)
- 03-03: Conductor (command/control + tagged unions + state machines)
- 03-04: Media Driver (agent orchestration + comptime interfaces)

### Part 4 — Client (3 chapters)
- 04-01: Publications (offer + back-pressure + enum return types)
- 04-02: Subscriptions (polling + fragment reassembly + std.ArrayList)
- 04-03: Integration Tests (wire compatibility against real Java Aeron)

### Part 5 — Archive (7 chapters)
- 05-01: Archive Protocol (P2-1: recording control protocol + SBE encoding)
- 05-02: Catalog (P2-2: persistent recording catalog + flat binary)
- 05-03: Recorder (P2-3: recording sessions + file I/O + segment rotation)
- 05-04: Replayer (P2-4: replay sessions + publication from file)
- 05-05: Archive Conductor (P2-5: archive command/control loop)
- 05-06: Archive Main (P2-6: ArchiveContext + standalone binary)
- 05-07: Parity (P2-7: audit hardening + test coverage)

### Part 6 — Cluster (5 chapters)
- 06-01: Cluster Protocol (P3-1: session + consensus messages)
- 06-02: Election (P3-2: Raft leader election state machine)
- 06-03: Log Replication (P3-3: append/commit log + follower ACK)
- 06-04: Cluster Conductor (P3-4: client sessions + service interface)
- 06-05: Cluster Main (P3-5: ClusterContext + ConsensusModule + binary)

**Total planned chapters: 31**

---

## Tutorial Stubs (tutorial/)

Directory structure with completion status:

### File: tutorial/protocol/frame.zig
- **Status**: STUB (2 TODO panics)
- **Functions**: `alignedLength`, `computeMaxPayload`
- **Exercise**: Chapter 1.1 — Frame Codec
- **Tests**: Pre-written test cases present

### File: tutorial/driver/conductor.zig
- **Status**: STUB (2 TODO panics)
- **Functions**: `doWork`, `handleAddPublication`
- **Exercise**: Chapter 3.3 — Conductor
- **Tests**: Stub test placeholder present

### File: tutorial/driver/cnc.zig
- **Status**: STUB (1 TODO panic)
- **Functions**: `CncFile.create`
- **Exercise**: Chapter 3.3 — CnC
- **Tests**: Stub test placeholder present

### File: tutorial/cnc.zig
- **Status**: STUB (3 TODO panics)
- **Functions**: `cncFilePath`, `errorLogPath`, `lossReportPath`
- **Exercise**: Chapter 3.3 — CnC Descriptor
- **Tests**: Stub test placeholder present

### File: tutorial/transport/endpoint.zig
- **Status**: STUB (8 TODO panics)
- **Functions**: `SendChannelEndpoint.open`, `.send`, `.close`, `ReceiveChannelEndpoint.open`, `.bind`, `.joinMulticast`, `.recv`, `.close`
- **Exercise**: Chapter 2.3 (or 3.4) — UDP Transport Endpoints
- **Tests**: None pre-written

### File: tutorial/transport/poller.zig
- **Status**: STUB (6 TODO panics)
- **Functions**: `Poller.init`, `.deinit`, `.add`, `.remove`, `.poll`, `.readyFds`
- **Exercise**: Chapter 2.3 (or 3.4) — Socket Polling
- **Tests**: None pre-written

### File: tutorial/transport/udp_channel.zig
- **Status**: STUB (3 TODO panics)
- **Functions**: `UdpChannel.parse`, `.deinit`, `.isMulticast`
- **Exercise**: Chapter 2.3 (or 3.4) — UDP Channel Parsing
- **Tests**: None pre-written

### File: tutorial/transport/uri.zig
- **Status**: STUB (15 TODO panics)
- **Functions**: `AeronUri.parse`, `.deinit`, `.endpoint`, `.controlEndpoint`, `.controlMode`, `.interfaceName`, `.mtu`, `.ttl`, `.termLength`, `.initialTermId`, `.sessionId`, `.reliable`, `.sparse`, `.get`, `ControlMode.fromString`
- **Exercise**: Chapter 2.3 (or 3.4) — Aeron URI Parsing
- **Tests**: None pre-written

**Summary**: 8 tutorial stub files with 40 total TODO panics across all exercise functions.

---

## Chapter Docs (docs/tutorial/)

### Part 0 — Orientation
- ✅ 00-01-what-is-aeron.md (5.4 KB)
- ✅ 00-02-what-is-zig.md (5.9 KB)
- ✅ 00-03-system-tour.md (8.7 KB)
- ✅ 00-04-first-pubsub.md (6.1 KB)

### Part 1 — Foundations
- ✅ 01-01-frame-codec.md (5.9 KB)
- ✅ 01-02-ring-buffer.md (5.7 KB)
- ✅ 01-03-broadcast.md (6.0 KB)
- ✅ 01-04-counters.md (5.6 KB)
- ✅ 01-05-log-buffer.md (6.4 KB)

### Part 2 — Data Path
- ✅ 02-01-term-appender.md (6.5 KB)
- ✅ 02-02-term-reader.md (5.9 KB)
- ✅ 02-03-udp-transport.md (4.0 KB)

### Part 3 — Driver
- ✅ 03-01-sender.md (6.2 KB)
- ✅ 03-02-receiver.md (6.7 KB)
- ✅ 03-03-conductor.md (3.8 KB)
- ✅ 03-04-media-driver.md (6.4 KB)

### Part 4 — Client
- ✅ 04-01-publications.md (5.7 KB)
- ✅ 04-02-subscriptions.md (6.1 KB)
- ✅ 04-03-integration-tests.md (7.7 KB)
- ✅ 04-04-interop.md (3.2 KB) — bonus chapter beyond spec

### Part 5 — Archive
- ⚠️ 05-01-archive-protocol.md (3.1 KB) — **INCOMPLETE** (stub level)
- ⚠️ 05-02-catalog.md (1.3 KB) — **INCOMPLETE** (stub level)
- ⚠️ 05-03-recorder.md (1.3 KB) — **INCOMPLETE** (stub level)
- ⚠️ 05-04-replayer.md (1.2 KB) — **INCOMPLETE** (stub level)
- ⚠️ 05-05-archive-conductor.md (1.4 KB) — **INCOMPLETE** (stub level)
- ⚠️ 05-06-archive-main.md (1.3 KB) — **INCOMPLETE** (stub level)
- ✅ 05-07-parity.md (1.6 KB) — partial

### Part 6 — Cluster
- ⚠️ 06-01-cluster-protocol.md (2.8 KB) — **INCOMPLETE** (stub level)
- ⚠️ 06-02-election.md (2.0 KB) — **INCOMPLETE** (stub level)
- ⚠️ 06-03-log-replication.md (1.9 KB) — **INCOMPLETE** (stub level)
- ⚠️ 06-04-cluster-conductor.md (2.0 KB) — **INCOMPLETE** (stub level)
- ⚠️ 06-05-cluster-main.md (1.5 KB) — **INCOMPLETE** (stub level)

### Navigation
- ✅ README.md (5.4 KB) — entry point and chapter navigation

**Summary**:
- **Complete chapters**: 17/31 (Parts 0–4 + parity audit)
- **Incomplete chapters**: 13/31 (Parts 5–6 at stub-level only)
- **Total coverage**: ~55%

---

## LESSON Annotations

### Count and Distribution

**Total LESSON annotations in src/**: 87 (good coverage)

#### By chapter (base slug):
```
  7 — transport/aeron
  6 — conductor/aeron
  4 — sender/aeron
  4 — publication/aeron
  4 — media-driver/aeron
  4 — archive/aeron
  4 — cluster/aeron
  4 — transport/zig
  4 — conductor/zig
  4 — media-driver/zig
  3 — counters/aeron
  3 — ring-buffer/aeron
  3 — term-reader/zig
  3 — term-appender/zig
  3 — ring-buffer/zig
  3 — counters/zig
  3 — cluster/zig
  3 — archive/zig
  2 — term-reader/aeron
  2 — term-appender/aeron
  2 — sender/zig
  2 — publication/zig
  2 — subscription/aeron
  2 — subscription/zig
  2 — aeron/aeron
  2 — aeron/zig
  1 — receiver/aeron
  1 — receiver/zig
  1 — frame-codec/aeron
  1 — frame-codec (unqualified)
```

### LESSON Annotation Issues

#### Unmapped LESSON slugs (reference non-existent chapters):
- `aeron/aeron` and `aeron/zig` — these are generic orientation annotations; no corresponding chapter file (intended?)
- `archive/aeron` and `archive/zig` — archive chapters exist but LESSON format uses top-level prefix, not chapter-specific
- `cluster/aeron` and `cluster/zig` — same: cluster chapters exist but LESSON uses prefix
- `transport/aeron` and `transport/zig` — same: 02-03-udp-transport.md exists but LESSON uses transport prefix

**Root cause**: Many LESSON annotations use a parent prefix (e.g. `transport/`) instead of the exact chapter slug (e.g. `udp-transport/`). This works functionally (the reference is still useful), but violates the spec's requirement: *"all LESSON blocks use the slug of the chapter they link to"* (see spec line 277).

#### Chapters in spec with NO LESSON annotations:
```
  ❌ archive-protocol      (05-01) — 0 annotations
  ❌ catalog               (05-02) — 0 annotations
  ❌ recorder              (05-03) — 0 annotations
  ❌ replayer             (05-04) — 0 annotations
  ❌ archive-conductor    (05-05) — 0 annotations
  ❌ cluster-protocol     (06-01) — 0 annotations (has generic cluster/ annotations instead)
  ❌ election             (06-02) — 0 annotations
  ❌ log-replication      (06-03) — 0 annotations
  ❌ cluster-conductor    (06-04) — 0 annotations (has generic cluster/ annotations instead)
  ❌ log-buffer           (01-05) — 0 annotations (chapter exists but no source links)
  ❌ udp-transport        (02-03) — 0 annotations (has transport/ prefix instead)
```

#### Matched annotations (chapters with LESSON coverage):
```
  ✅ frame-codec          (01-01) — 2 annotations
  ✅ ring-buffer          (01-02) — 3 annotations
  ✅ broadcast            (01-03) — 0 direct (none in code)
  ✅ counters             (01-04) — 3 annotations
  ✅ term-appender        (02-01) — 3 annotations
  ✅ term-reader          (02-02) — 3 annotations
  ✅ sender               (03-01) — 6 annotations
  ✅ receiver             (03-02) — 2 annotations
  ✅ conductor            (03-03) — 6 annotations
  ✅ media-driver         (03-04) — 6 annotations
  ✅ publications         (04-01) — 7 annotations
  ✅ subscriptions        (04-02) — 2 annotations
```

---

## Git Tags

```bash
$ git tag | grep chapter
```

**Result**: No chapter-NN-slug tags found.

The spec requires:
> After each chapter's reference implementation lands in `src/`, tag `main` as `chapter-NN-slug` (e.g. `chapter-01-frame-codec`). Learners can: `git diff chapter-01-frame-codec chapter-02-ring-buffer`.

**Current state**: No checkpoint tags exist yet. This is a gap if learners are expected to use `git diff` between chapters to see what changed.

---

## Summary: Gaps

### Critical Gaps (Spec vs. Implementation)

1. **Archive Part (05) chapters: Stubs only**
   - 05-01 through 05-06 are placeholder-level (1–3 KB, minimal content)
   - No narrative walkthrough of archive design, catalog format, recorder/replayer logic
   - No code examples or diagrams
   - Archive features are implemented in `src/` but tutorial is not written yet

2. **Cluster Part (06) chapters: Stubs only**
   - 06-01 through 06-05 are placeholder-level (1.5–2.8 KB)
   - Consensus protocol, Raft election, replication logic completely missing narrative
   - Cluster features are implemented in `src/` but tutorial is not written yet

3. **LESSON annotation coverage gaps**
   - 10 archive/cluster chapter files have NO corresponding LESSON annotations pointing to them
   - Annotations use parent prefixes (`archive/`, `cluster/`, `transport/`) instead of exact chapter slugs
   - Violates spec requirement: "all LESSON blocks use the slug of the chapter they link to"
   - Creates dead links if learners follow LESSON comments to `docs/tutorial/`

4. **Git checkpoint tags missing**
   - No `chapter-NN-slug` tags on main
   - Learners cannot use `git diff chapter-01-frame-codec chapter-02-ring-buffer` to see deltas
   - Breaks the "checkpoint story" mentioned in spec

5. **Tutorial stubs missing reference documentation**
   - `tutorial/transport/` files (uri.zig, udp_channel.zig, poller.zig, endpoint.zig) are heavily stubbed (40 TODO panics)
   - Referenced exercises are for "Chapter 2.3 (or 3.4)" — ambiguous chapter mapping
   - No pre-written test cases for transport stubs (only frame/conductor have them)
   - Hard to know what learner is supposed to implement without reading src/

6. **Broadcast chapter (01-03) missing LESSON annotations**
   - Chapter doc exists but no LESSON comments in src/ipc/broadcast.zig
   - Spec calls out "medium density" annotations; broadcast is skipped entirely

7. **Log-Buffer chapter (01-05) missing LESSON annotations**
   - Chapter doc exists but no LESSON comments in src/logbuffer/ modules
   - Critical foundational chapter completely unannotated in source

### Non-Critical Issues

- **Extra chapter in Part 4**: 04-04-interop.md is not in spec (bonus, OK)
- **Archive/Cluster slug inconsistency**: LESSON uses `archive/`, `cluster/` prefixes; chapters use full names like `archive-protocol`, `cluster-protocol`. Should normalize.
- **Transport chapter reference format**: Tutorial exercises say "Chapter C-5" instead of "Chapter 2.3" (C-N is internal naming, breaks consistency)

---

## Recommendations (by priority)

### Immediate (blocks learner use)
1. **Tag all completed chapters** — run `git tag chapter-01-frame-codec` through `chapter-04-integration-tests` to create checkpoint story
2. **Normalize LESSON slugs** — update src/ annotations to match exact chapter slugs (e.g. `transport/` → `udp-transport/transport/`)
3. **Add missing LESSON annotations** — broadcast (01-03), log-buffer (01-05), and all archive/cluster chapter modules
4. **Fix transport exercise mappings** — clarify whether endpoint/poller/uri are Chapter 2.3 or 3.4; add pre-written tests

### Short-term (fills narrative gaps)
5. **Expand archive chapters (05-01 through 05-06)** — write full walkthrough-style docs with code examples and diagrams
6. **Expand cluster chapters (06-01 through 06-05)** — write Raft consensus and leader election explanations
7. **Write missing chapter docs** — any chapter > 2 KB shortfall

### Long-term (polish)
8. **Audit chapter-to-exercise alignment** — ensure every tutorial stub maps to exactly one chapter doc
9. **Create CI check** — lint LESSON slugs against docs/tutorial/ file names to catch future drift
10. **Validate interop tests** — 04-03-integration-tests.md references wire compatibility but unclear if tests are passing against real Aeron Java client

