# Phase 6 — Wire Compatibility + Course Quality — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all structural bugs blocking Zig-only pub/sub, achieve Java `Aeron.connect()` interop, and ship a dual-track (Zig + Aeron) annotated course alongside every code milestone.

**Architecture:** Two sequential sub-agent lanes (interop, course) gate on three milestones (M1: structural fixes, M2: Zig-only driver + CnC.dat, M3: Java interop). Each task is one sub-agent session. Both lanes must pass `make check` before advancing past a milestone.

**Tech Stack:** Zig 0.14, `std.posix` (mmap, sockets), `@cmpxchgStrong`/`@atomicLoad` for lock-free primitives, Docker Compose for Java interop smoke test.

**Reference docs:** `docs/audits/2026-03-23-wire-compatibility.md` (bug details), `docs/specs/2026-03-23-phase6-interop-course-design.md` (approved design).

---

## Execution Tracking

Update the `Status` column as tasks complete. Valid values: `pending`, `in_progress`, `done`.

| ID | Lane | Milestone | Status | Files |
|----|------|-----------|--------|-------|
| C-1 | course | pre-M1 | done | `docs/course/lesson-gap-report.md` |
| I-1 | interop | M1 | done | `src/publication.zig` |
| I-2 | interop | M1 | done | `src/ipc/broadcast.zig` |
| I-3 | interop | M1 | done | `src/protocol/frame.zig` |
| I-4 | interop | M1 | done | `src/driver/receiver.zig`, `src/driver/conductor.zig` |
| I-5 | interop | M1 | done | `src/driver/receiver.zig` |
| **M1** | merge | — | done | `make check` full tree |
| C-2 | course | M2 | pending | `src/protocol/frame.zig`, `docs/tutorial/part/frame-codec.md` |
| C-3 | course | M2 | pending | `src/logbuffer/`, `docs/tutorial/part/logbuffer.md` |
| C-4 | course | M2 | pending | `src/ipc/`, `docs/tutorial/part/ipc.md` |
| I-6 | interop | M2 | done | `src/logbuffer/log_buffer.zig` |
| I-7 | interop | M2 | done | `src/driver/cnc.zig` (new), `src/driver/media_driver.zig` |
| I-8 | interop | M2 | done | `src/aeron.zig` |
| **M2** | merge | — | done | `make check` + integration test |
| C-5 | course | M3 | pending | `src/transport/`, `docs/tutorial/part/transport.md` |
| C-6 | course | M3 | pending | `src/driver/`, `docs/tutorial/part/conductor-cnc.md` |
| C-7 | course | M3 | pending | `examples/*.zig` |
| I-9 | interop | M3 | pending | `test/interop/` (new) |
| **M3** | merge | — | pending | `AERON_INTEROP=1 make test-interop` |
| C-8 | course | post-M3 | pending | `docs/tutorial/part/interop.md` |
| C-9 | course | post-M3 | pending | `docs/tutorial/README.md` |

---

## File Map

### New files
- `src/driver/cnc.zig` — CnC.dat layout struct + mmap open/create helpers
- `test/interop/docker-compose.yml` — Java + Zig driver containers
- `test/interop/BasicPublisher.java` — Java publisher for smoke test
- `test/interop/BasicSubscriber.java` — Java subscriber for smoke test
- `test/interop/run.sh` — smoke test entry point
- `docs/course/lesson-gap-report.md` — C-1 output
- `docs/tutorial/part/frame-codec.md` — C-2 output
- `docs/tutorial/part/logbuffer.md` — C-3 output
- `docs/tutorial/part/ipc.md` — C-4 output
- `docs/tutorial/part/transport.md` — C-5 output
- `docs/tutorial/part/conductor-cnc.md` — C-6 output
- `docs/tutorial/part/interop.md` — C-8 output
- `docs/tutorial/README.md` — C-9 output

### Modified files
- `src/publication.zig` — fix `publisher_limit` init (I-1)
- `src/ipc/broadcast.zig` — fix `HEADER_LENGTH` 12→8 (I-2)
- `src/protocol/frame.zig` — add `RttMeasurement.receiver_id` (I-3)
- `src/driver/receiver.zig` — SETUP→Image path (I-4), NAK coalescing (I-5)
- `src/driver/conductor.zig` — Image creation on SETUP signal (I-4)
- `src/logbuffer/log_buffer.zig` — mmap-backed buffers (I-6)
- `src/driver/media_driver.zig` — create CnC.dat on init (I-7)
- `src/aeron.zig` — real doWork() conductor polling (I-8)
- `examples/*.zig` — dual annotation comments (C-7)

---

## C-1: Audit LESSON Comment Gaps (pre-M1, can run alongside I-1)

**Files:**
- Create: `docs/course/lesson-gap-report.md`
- Read: all `src/**/*.zig`, `docs/tutorial/`

- [ ] **Step 1: Scan all source files for existing LESSON comments**

```bash
grep -rn "LESSON(" src/ --include="*.zig" | sort
```

Note every module that has at least one `LESSON(...)` comment.

- [ ] **Step 2: List all modules and cross-reference**

For each module below, record: has Zig-angle lesson? has Aeron-angle lesson? has tutorial chapter in `docs/tutorial/part/`?

Modules to check:
- `src/protocol/frame.zig`
- `src/logbuffer/log_buffer.zig`, `term_appender.zig`, `term_reader.zig`, `metadata.zig`
- `src/ipc/ring_buffer.zig`, `broadcast.zig`, `counters.zig`
- `src/transport/udp_channel.zig`, `endpoint.zig`, `poller.zig`, `uri.zig`
- `src/driver/sender.zig`, `receiver.zig`, `conductor.zig`, `media_driver.zig`
- `src/publication.zig`, `subscription.zig`, `image.zig`, `src/aeron.zig`
- `src/archive/` (all files)
- `src/cluster/` (all files)

- [ ] **Step 3: Write gap report**

Write `docs/course/lesson-gap-report.md` with this format:

```markdown
# LESSON Comment Gap Report — 2026-03-23

| Module | Zig lesson | Aeron lesson | Tutorial chapter |
|--------|-----------|--------------|-----------------|
| protocol/frame.zig | yes | partial | missing |
| logbuffer/log_buffer.zig | no | no | missing |
...

## Priority gaps (needed for M2 course tasks)
[list modules C-2/C-3/C-4 will touch, with specific missing annotations]
```

- [ ] **Step 4: Commit**

```bash
git add docs/course/lesson-gap-report.md
git commit -m "docs: add LESSON comment gap report for phase 6 course track"
```

---

## I-1: Fix `publisher_limit` Init

**Files:**
- Modify: `src/publication.zig`

- [ ] **Step 1: Read the file**

```bash
cat src/publication.zig
```

Find the `ExclusivePublication.init()` function and the `offer()` guard.

- [ ] **Step 2: Write the failing test**

Add to `src/publication.zig` inside the test block:

```zig
test "offer: first message succeeds when publisher_limit is term_length" {
    const allocator = std.testing.allocator;
    var log_buf = try @import("logbuffer/log_buffer.zig").LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit(allocator);

    var pub = ExclusivePublication.init(1, 1001, 0, 64 * 1024, 1408, &log_buf);
    const result = pub.offer("hello");
    try std.testing.expect(result == .ok);
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-unit 2>&1 | grep -A5 "publisher_limit"
```

Expected: test fails — `offer` returns `.back_pressure`.

- [ ] **Step 4: Fix the init function**

In `src/publication.zig`, change `publisher_limit: 0` to `publisher_limit: @as(i64, term_length)` in the `init` return literal:

```zig
// Before:
.publisher_limit = 0,

// After:
.publisher_limit = @as(i64, term_length),
```

- [ ] **Step 5: Run test to verify it passes**

```bash
make test-unit
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/publication.zig
git commit -m "fix: init publisher_limit to term_length so first offer succeeds"
```

---

## I-2: Fix Broadcast `HEADER_LENGTH` (12→8 bytes)

**Files:**
- Modify: `src/ipc/broadcast.zig`

- [ ] **Step 1: Read the file**

```bash
cat src/ipc/broadcast.zig
```

Find `HEADER_LENGTH`, the `transmit()` write loop, and all offset arithmetic that depends on it.

- [ ] **Step 2: Write the failing test**

Add to `src/ipc/broadcast.zig`:

```zig
test "broadcast: header is 8 bytes (type i32 + length i32)" {
    // Verify HEADER_LENGTH constant is exactly 8
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.HEADER_LENGTH);
}

test "broadcast: transmit and receive roundtrip" {
    const allocator = std.testing.allocator;
    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    const msg = "hello aeron";
    tx.transmit(42, msg);

    var rx = BroadcastReceiver.init(tx.buffer, tx.tail);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 42), rx.typeId());
    try std.testing.expectEqualSlices(u8, msg, rx.buffer()[0..rx.length()]);
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
make test-unit 2>&1 | grep -A5 "broadcast"
```

- [ ] **Step 4: Fix HEADER_LENGTH and transmit()**

```zig
// In RecordDescriptor:
pub const HEADER_LENGTH = 8; // type(i32=4) + length(i32=4)

// In transmit(), replace the 12-byte header write with:
var header_bytes: [RecordDescriptor.HEADER_LENGTH]u8 = undefined;
std.mem.writeInt(i32, header_bytes[0..4], msg_type_id, .little);
std.mem.writeInt(i32, header_bytes[4..8], record_length, .little);
@memcpy(header_ptr[0..RecordDescriptor.HEADER_LENGTH], &header_bytes);
```

Also update `BroadcastReceiver` read offsets: `typeId()` reads bytes 0..4, `length()` reads bytes 4..8, payload starts at byte 8.

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test-unit
```

- [ ] **Step 6: Commit**

```bash
git add src/ipc/broadcast.zig
git commit -m "fix: broadcast HEADER_LENGTH 12->8 bytes to match agrona wire format"
```

---

## I-3: Fix `RttMeasurement` Frame Size (24→32 bytes)

**Files:**
- Modify: `src/protocol/frame.zig`

- [ ] **Step 1: Read the relevant section**

```bash
grep -n "RttMeasurement" src/protocol/frame.zig
```

- [ ] **Step 2: Write the failing test**

Add to `src/protocol/frame.zig`:

```zig
test "RttMeasurement is exactly 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RttMeasurement));
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-unit 2>&1 | grep -A5 "RttMeasurement"
```

Expected: test fails — actual size is 24.

- [ ] **Step 4: Add receiver_id field and update comment**

```zig
pub const RttMeasurement = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    echo_timestamp: i64 align(4),
    reception_delta: i64 align(4),
    // LESSON(frame-codec/aeron): receiver_id was present from the start in C header
    // (aeron_udp_protocol.h). Total frame size = 32 bytes.
    receiver_id: i64 align(4),

    pub const LENGTH = @sizeOf(RttMeasurement);
};

comptime {
    std.debug.assert(@sizeOf(RttMeasurement) == 32);
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test-unit
```

- [ ] **Step 6: Commit**

```bash
git add src/protocol/frame.zig
git commit -m "fix: add RttMeasurement.receiver_id to match 32-byte upstream frame"
```

---

## I-4: SETUP→Image Creation Path

**Files:**
- Modify: `src/driver/receiver.zig`
- Modify: `src/driver/conductor.zig`
- Modify: `test/harness.zig` (add `injectSetupFrame` and `doConductorWork` helpers)
- Modify: `test/integration_test.zig`

- [ ] **Step 1: Read all four files**

```bash
cat src/driver/receiver.zig
cat src/driver/conductor.zig
cat test/harness.zig
cat test/integration_test.zig
```

Find where SETUP frames are currently discarded in `receiver.zig`, where `conductor.zig` handles `ADD_SUBSCRIPTION`, and what helpers `TestHarness` already exposes.

- [ ] **Step 2: Extend TestHarness with required helpers**

Add to `test/harness.zig` (inside `TestHarness`):

```zig
// Drive conductor duty cycle n times
pub fn doConductorWork(self: *TestHarness, n: usize) void {
    for (0..n) |_| {
        _ = self.driver.conductor.doWork();
    }
}

// Inject a synthetic SETUP frame directly into the receiver's pending_setups queue
pub fn injectSetupFrame(self: *TestHarness, sig: @import("aeron").driver.receiver.SetupSignal) !void {
    try self.driver.receiver.pending_setups.append(self.allocator, sig);
}
```

Run `make test-unit` to verify the harness extension compiles before adding the new integration test.

- [ ] **Step 3: Write the failing integration test**

Add to `test/integration_test.zig`:

```zig
test "subscriber receives data after SETUP handshake" {
    const allocator = std.testing.allocator;
    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    var sub = try h.createSubscription(1001, "aeron:ipc");
    defer sub.deinit();

    // Inject a synthetic SETUP signal directly into the receiver queue
    const aeron_pkg = @import("aeron");
    try h.injectSetupFrame(aeron_pkg.driver.receiver.SetupSignal{
        .session_id = 42,
        .stream_id = 1001,
        .initial_term_id = 0,
        .active_term_id = 0,
        .term_length = 64 * 1024,
        .mtu = 1408,
        .source_address = std.net.Address.initIp4(.{127, 0, 0, 1}, 40123),
    });

    // Allow conductor duty cycle to process the signal
    h.doConductorWork(10);

    // Subscription should now have an Image
    try std.testing.expectEqual(@as(usize, 1), sub.images().len);
}
```

- [ ] **Step 4: Run test to verify it fails**

```bash
make test-integration 2>&1 | grep -A10 "SETUP handshake"
```

- [ ] **Step 4: Add SetupSignal type to receiver**

In `src/driver/receiver.zig`, add a pending setup queue:

```zig
pub const SetupSignal = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    active_term_id: i32,
    term_length: i32,
    mtu: i32,
    source_address: std.net.Address,
};

// In Receiver struct, add:
pending_setups: std.ArrayListUnmanaged(SetupSignal) = .{},
```

In the SETUP frame dispatch branch (currently `return 1`), replace with:

```zig
} else if (frame_type_raw == @intFromEnum(protocol.FrameType.setup)) {
    const setup = @as(*const protocol.SetupHeader, @ptrCast(@alignCast(buf.ptr)));
    try self.pending_setups.append(self.allocator, .{
        .session_id = setup.session_id,
        .stream_id = setup.stream_id,
        .initial_term_id = setup.initial_term_id,
        .active_term_id = setup.active_term_id,
        .term_length = setup.term_length,
        .mtu = setup.mtu,
        .source_address = src_addr,
    });
    return 1;
}
```

Add `drainPendingSetups(self: *Receiver) []SetupSignal` that returns and clears the queue.

- [ ] **Step 5: Handle SetupSignal in conductor**

In `src/driver/conductor.zig`, in `doWork()`, after reading ring buffer commands:

```zig
// Drain receiver SETUP signals
for (self.receiver.drainPendingSetups()) |sig| {
    // Find matching subscription
    for (self.subscriptions.items) |*sub| {
        if (sub.stream_id == sig.stream_id) {
            // Create Image
            const image = try self.allocator.create(Image);
            image.* = Image.init(
                sig.session_id,
                sig.stream_id,
                sig.initial_term_id,
                sig.term_length,
                sig.source_address,
            );
            try sub.addImage(image);
            try self.receiver.onAddSubscription(image);
            // Send STATUS back
            try self.sendStatus(image, sig.source_address);
            break;
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
make test-integration
```

- [ ] **Step 7: Commit**

```bash
git add src/driver/receiver.zig src/driver/conductor.zig test/harness.zig test/integration_test.zig
git commit -m "fix: wire SETUP frame to Image creation and STATUS reply"
```

---

## I-5: NAK Timer Coalescing

**Files:**
- Modify: `src/driver/receiver.zig`

- [ ] **Step 1: Read the sendNak section**

```bash
grep -n "sendNak\|gap\|nak" src/driver/receiver.zig
```

- [ ] **Step 2: Write the failing test**

Add to `src/driver/receiver.zig`:

```zig
test "NAK: adjacent gaps produce one coalesced NAK" {
    // Create two adjacent gap records for the same Image
    var nak_state = NakState.init(1001);
    nak_state.recordGap(100, 64);   // gap at offset 100, length 64
    nak_state.recordGap(164, 128);  // adjacent gap at 164, length 128

    // Should coalesce into one gap: offset=100, length=192
    const gaps = nak_state.gaps();
    try std.testing.expectEqual(@as(usize, 1), gaps.len);
    try std.testing.expectEqual(@as(i32, 100), gaps[0].offset);
    try std.testing.expectEqual(@as(i32, 192), gaps[0].length);
}

test "NAK: no NAK sent within delay window" {
    // Use an injectable base_time to avoid non-determinism from std.time.nanoTimestamp().
    // NakState.initWithTime(stream_id, first_gap_ns) sets first_gap_ns directly.
    var nak_state = NakState.initWithTime(1001, 0);
    nak_state.gap_list.append(.{ .offset = 100, .length = 64 }) catch unreachable;

    // Before delay elapses: should not send
    try std.testing.expect(!nak_state.shouldSend(NAK_DELAY_NS - 1));
    // After delay: should send
    try std.testing.expect(nak_state.shouldSend(NAK_DELAY_NS));
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
make test-unit 2>&1 | grep -A5 "NAK:"
```

- [ ] **Step 4: Add NakState struct**

Add to `src/driver/receiver.zig`:

```zig
const NAK_DELAY_NS: i64 = 1_000_000; // 1ms

pub const GapRange = struct { offset: i32, length: i32 };

pub const NakState = struct {
    stream_id: i32,
    gap_list: std.BoundedArray(GapRange, 16) = .{},
    first_gap_ns: i64 = 0,

    pub fn init(stream_id: i32) NakState {
        return .{ .stream_id = stream_id };
    }

    /// For tests: inject a known first_gap_ns instead of using the real clock.
    pub fn initWithTime(stream_id: i32, first_gap_ns: i64) NakState {
        return .{ .stream_id = stream_id, .first_gap_ns = first_gap_ns };
    }

    pub fn recordGap(self: *NakState, offset: i32, length: i32) void {
        const end = offset + length;
        // Try to merge with existing gap
        for (self.gap_list.slice()) |*g| {
            if (offset <= g.offset + g.length and end >= g.offset) {
                g.offset = @min(g.offset, offset);
                g.length = @max(g.offset + g.length, end) - g.offset;
                return;
            }
        }
        if (self.gap_list.len == 0) self.first_gap_ns = std.time.nanoTimestamp();
        self.gap_list.append(.{ .offset = offset, .length = length }) catch {};
    }

    pub fn shouldSend(self: *const NakState, now_ns: i64) bool {
        return self.gap_list.len > 0 and (now_ns - self.first_gap_ns) >= NAK_DELAY_NS;
    }

    pub fn gaps(self: *const NakState) []const GapRange {
        return self.gap_list.constSlice();
    }

    pub fn clear(self: *NakState) void {
        self.gap_list.len = 0;
        self.first_gap_ns = 0;
    }
};
```

Update `sendNak()` to iterate `NakState.gaps()` and send one NAK per gap range with the exact length.

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test-unit
```

- [ ] **Step 6: Commit**

```bash
git add src/driver/receiver.zig
git commit -m "fix: coalesce NAK gaps with 1ms delay timer"
```

---

## Milestone 1 Merge

- [ ] **Step 1: Run full check**

```bash
make check
```

Expected: fmt-check passes, build succeeds, all tests pass.

- [ ] **Step 2: Update tracking table**

In `docs/plans/phase6.md`, set M1 status to `done` and all I-1 through I-5, C-1 rows to `done`.

- [ ] **Step 3: Commit**

```bash
git add docs/plans/phase6.md
git commit -m "chore: milestone M1 — structural fixes complete"
```

---

## C-2: Dual-annotate Frame Codec Chapter

**Files:**
- Modify: `src/protocol/frame.zig` (add/enrich LESSON comments)
- Create: `docs/tutorial/part/frame-codec.md`

- [ ] **Step 1: Read gap report and frame.zig**

```bash
cat docs/course/lesson-gap-report.md
cat src/protocol/frame.zig
```

- [ ] **Step 2: Add missing LESSON comments to frame.zig**

For every struct and helper function, add dual annotation:

```zig
// LESSON(frame-codec/zig): extern struct guarantees C-compatible memory layout.
// Without `extern`, Zig may reorder or pad fields for its own alignment. We need
// exact byte positions to match the wire format.
pub const DataHeader = extern struct { ... };

// LESSON(frame-codec/aeron): The DataHeader is 32 bytes. The first 8 bytes (frame_length,
// version, flags, type) are shared by every Aeron frame — the "base header". The remaining
// 24 bytes carry stream identity (session_id, stream_id, term_id) and the reserved_value
// field used for CRC or timestamps in some Aeron profiles.
```

Cover: `extern struct`, `comptime assert`, `align(4)` explanation, `FrameType` enum values.

- [ ] **Step 3: Write tutorial chapter**

Write `docs/tutorial/part/frame-codec.md` with sections:

```markdown
# Chapter: Aeron Wire Frames

## Zig track: extern struct and wire layout
[explain extern, comptime assert, align(4)]

## Aeron track: the frame format
[explain why Aeron uses fixed-size headers, what each field means]

## Both tracks: the alignment puzzle
[explain #pragma pack(4) equivalence — where Zig and C meet]

## Exercises
1. Add a new hypothetical frame type with a 64-bit timestamp field. What alignment is needed?
2. Write a comptime function that verifies all frame types share the same first 8 bytes.
```

- [ ] **Step 4: Verify chapter compiles (tutorial-check)**

```bash
make tutorial-check
```

- [ ] **Step 5: Commit**

```bash
git add src/protocol/frame.zig docs/tutorial/part/frame-codec.md
git commit -m "docs: dual-annotate frame codec chapter (Zig + Aeron tracks)"
```

---

## C-3: Dual-annotate Logbuffer Chapter

**Files:**
- Modify: `src/logbuffer/*.zig` (add LESSON comments)
- Create: `docs/tutorial/part/logbuffer.md`

- [ ] **Step 1: Read logbuffer files**

```bash
cat src/logbuffer/log_buffer.zig src/logbuffer/metadata.zig src/logbuffer/term_appender.zig src/logbuffer/term_reader.zig
```

- [ ] **Step 2: Add LESSON comments to each file**

`term_appender.zig` key annotations:

```zig
// LESSON(logbuffer/zig): packTail encodes two i32 values into one i64 using bit
// manipulation. This lets us CAS both term_id and term_offset atomically — a single
// 64-bit @cmpxchgStrong instead of two separate atomic operations that could race.

// LESSON(logbuffer/aeron): The 3-partition design solves the "active term full" transition
// problem. While the publisher writes the PADDING frame into the old term and rotates to
// the new term, a subscriber may still be reading the old term. The third partition is always
// clean, so the rotation never overwrites live data.
```

- [ ] **Step 3: Write tutorial chapter**

`docs/tutorial/part/logbuffer.md` sections:
- Zig track: `@cmpxchgStrong`, memory ordering, `@atomicLoad` acquire/release
- Aeron track: zero-copy data path, term rotation, why 3 partitions, publisher/subscriber position relationship
- Both tracks: the `packTail` bit trick — why combining two values into one enables atomic rotation

- [ ] **Step 4: Verify tutorial compile-check passes**

```bash
make tutorial-check
```

- [ ] **Step 5: Commit**

```bash
git add src/logbuffer/ docs/tutorial/part/logbuffer.md
git commit -m "docs: dual-annotate logbuffer chapter (Zig + Aeron tracks)"
```

---

## C-4: Dual-annotate IPC Chapter

**Files:**
- Modify: `src/ipc/*.zig` (add LESSON comments)
- Create: `docs/tutorial/part/ipc.md`

- [ ] **Step 1: Read IPC files**

```bash
cat src/ipc/ring_buffer.zig src/ipc/broadcast.zig src/ipc/counters.zig
```

- [ ] **Step 2: Add LESSON comments**

`ring_buffer.zig` key annotations:

```zig
// LESSON(ipc/zig): The head cache avoids reading the authoritative head on every write.
// Writers check the cached head first; only if the buffer appears full do they re-read
// the real head. This reduces false cache-line contention between the reader (which
// advances head) and the many writers (which read head to check capacity).

// LESSON(ipc/aeron): This ring buffer is one-directional: clients write commands
// (ADD_PUBLICATION, ADD_SUBSCRIPTION, etc.) and the driver conductor reads them.
// The broadcast buffer goes the other direction: driver writes notifications
// (ON_PUBLICATION_READY, ON_IMAGE_READY) and all clients read them independently.
// Two separate buffers, two separate access patterns.
```

- [ ] **Step 3: Write tutorial chapter**

`docs/tutorial/part/ipc.md` sections:
- Zig track: `@atomicLoad`/`@atomicStore` memory ordering, CAS retry loops, why `@cmpxchgStrong` vs `Weak`
- Aeron track: client→driver command protocol (ring buffer), driver→client notification protocol (broadcast), correlation IDs, client liveness
- Both tracks: the head-cache optimization — a case study in cache-line design

- [ ] **Step 4: Verify tutorial compile-check passes**

```bash
make tutorial-check
```

- [ ] **Step 5: Commit**

```bash
git add src/ipc/ docs/tutorial/part/ipc.md
git commit -m "docs: dual-annotate IPC chapter (Zig + Aeron tracks)"
```

---

## I-6: mmap-backed Log Buffers

**Files:**
- Modify: `src/logbuffer/log_buffer.zig`

- [ ] **Step 1: Read the file**

```bash
cat src/logbuffer/log_buffer.zig
```

Find `init()` — locate the `allocator.alloc` call for the backing buffer.

- [ ] **Step 2: Write the failing test**

Add to `src/logbuffer/log_buffer.zig`:

```zig
test "LogBuffer: mmap file created on disk" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-logbuf.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    var lb = try LogBuffer.initMapped(allocator, 64 * 1024, path);
    defer lb.deinit(allocator);

    // File must exist and have correct size
    const stat = try std.fs.cwd().statFile(path);
    const expected_size = 3 * 64 * 1024 + @import("metadata.zig").LOG_META_DATA_LENGTH;
    try std.testing.expectEqual(expected_size, stat.size);
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-unit 2>&1 | grep -A5 "mmap file"
```

- [ ] **Step 4: Add initMapped()**

Add to `LogBuffer`:

```zig
pub fn initMapped(allocator: std.mem.Allocator, term_length: i32, path: []const u8) !LogBuffer {
    _ = allocator;
    const total = @as(usize, @intCast(term_length)) * PARTITION_COUNT +
        @import("metadata.zig").LOG_META_DATA_LENGTH;

    // Create or open file and extend to required size
    const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.setEndPos(total);

    const ptr = try std.posix.mmap(
        null,
        total,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    const buffer = @as([*]u8, @ptrCast(ptr))[0..total];

    return LogBuffer{
        .buffer = buffer,
        .term_length = term_length,
        .is_mapped = true,
    };
}
```

Update `deinit()` to call `std.posix.munmap()` when `is_mapped` is true.

Keep existing `init()` (heap-backed) for tests that don't need a file path.

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test-unit
```

- [ ] **Step 6: Commit**

```bash
git add src/logbuffer/log_buffer.zig
git commit -m "feat: add mmap-backed LogBuffer.initMapped for file-backed log buffers"
```

---

## I-7: `CnC.dat` File Layout

**Files:**
- Create: `src/driver/cnc.zig`
- Modify: `src/driver/media_driver.zig`

- [ ] **Step 1: Read media_driver.zig**

```bash
cat src/driver/media_driver.zig
```

Find the `init()` function — note where resources are currently set up.

- [ ] **Step 2: Write the failing test**

Create `src/driver/cnc_test.zig` (or add to `cnc.zig`):

```zig
test "CnC: file created with correct magic, version, and buffer sizes" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-CnC.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const cfg = CncConfig{
        .to_driver_buffer_length = 1024 * 1024,
        .to_clients_buffer_length = 1024 * 1024,
        .counters_metadata_buffer_length = 1024 * 1024,
        .counters_values_buffer_length = 4 * 1024 * 1024,
        .client_liveness_timeout_ns = 5_000_000_000,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    // CNC_MAGIC at offset 0 (4 bytes: 0x4e445253 LE = "SRDN")
    try std.testing.expectEqual(CNC_MAGIC, cnc.magic());
    // CNC_VERSION at offset 4
    try std.testing.expectEqual(@as(i32, CNC_VERSION), cnc.version());
    // Buffer lengths readable
    try std.testing.expectEqual(cfg.to_driver_buffer_length, cnc.toDriverBufferLength());
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-unit 2>&1 | grep -A5 "CnC:"
```

- [ ] **Step 4: Implement cnc.zig**

```zig
// src/driver/cnc.zig
// CnC.dat (Command 'n' Control) file — the rendezvous point between Aeron clients and driver.
// LESSON(conductor/zig): We mmap a file and cast a pointer to our header struct. The file
// acts as shared memory between processes without needing SysV IPC or POSIX shm_open.
// LESSON(conductor/aeron): CnC.dat has a fixed header (4096 bytes) followed immediately by
// the to-driver ring buffer and to-clients broadcast buffer. Java clients find these by
// reading the length fields from the header and computing byte offsets.

// Magic bytes at offset 0 — "SRDN" in little-endian (matches CncFileDescriptor.CNC_FILE_MAGIC in Java)
pub const CNC_MAGIC: i32 = 0x4e445253;
// Version number at offset 4 — matches CncFileDescriptor.CNC_VERSION
pub const CNC_VERSION: i32 = 207;

pub const CncConfig = struct {
    to_driver_buffer_length: i32,
    to_clients_buffer_length: i32,
    counters_metadata_buffer_length: i32,
    counters_values_buffer_length: i32,
    client_liveness_timeout_ns: i64,
};

// Header layout — matches io.aeron.CncFileDescriptor offsets exactly
const CNC_HEADER_SIZE = 4096; // padded to page boundary
const MAGIC_OFFSET = 0;                 // i32 — 0x4e445253
const VERSION_OFFSET = 4;              // i32 — CNC_VERSION
const TO_DRIVER_BUF_LEN_OFFSET = 8;   // i32
const TO_CLIENTS_BUF_LEN_OFFSET = 12;  // i32
const COUNTERS_META_BUF_LEN_OFFSET = 16; // i32
const COUNTERS_VAL_BUF_LEN_OFFSET = 20;  // i32
const CLIENT_LIVENESS_TIMEOUT_OFFSET = 32; // i64 (aligned to 8)

pub const CncFile = struct {
    mapped: []u8,
    path: []const u8,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, cfg: CncConfig) !CncFile {
        _ = allocator;
        const total = CNC_HEADER_SIZE +
            @as(usize, @intCast(cfg.to_driver_buffer_length)) +
            @as(usize, @intCast(cfg.to_clients_buffer_length)) +
            @as(usize, @intCast(cfg.counters_metadata_buffer_length)) +
            @as(usize, @intCast(cfg.counters_values_buffer_length));

        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        defer file.close();
        try file.setEndPos(total);

        const ptr = try std.posix.mmap(null, total,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED }, file.handle, 0);
        const mapped = @as([*]u8, @ptrCast(ptr))[0..total];

        // Write header fields
        std.mem.writeInt(i32, mapped[MAGIC_OFFSET..][0..4], CNC_MAGIC, .little);
        std.mem.writeInt(i32, mapped[VERSION_OFFSET..][0..4], CNC_VERSION, .little);
        std.mem.writeInt(i32, mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], cfg.to_driver_buffer_length, .little);
        std.mem.writeInt(i32, mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], cfg.to_clients_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], cfg.counters_metadata_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_VAL_BUF_LEN_OFFSET..][0..4], cfg.counters_values_buffer_length, .little);
        std.mem.writeInt(i64, mapped[CLIENT_LIVENESS_TIMEOUT_OFFSET..][0..8], cfg.client_liveness_timeout_ns, .little);

        return CncFile{ .mapped = mapped, .path = path };
    }

    pub fn deinit(self: *CncFile) void {
        std.posix.munmap(@alignCast(self.mapped));
    }

    pub fn magic(self: *const CncFile) i32 {
        return std.mem.readInt(i32, self.mapped[MAGIC_OFFSET..][0..4], .little);
    }

    pub fn version(self: *const CncFile) i32 {
        return std.mem.readInt(i32, self.mapped[VERSION_OFFSET..][0..4], .little);
    }

    pub fn toDriverBufferLength(self: *const CncFile) i32 {
        return std.mem.readInt(i32, self.mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], .little);
    }

    pub fn toDriverBuffer(self: *CncFile) []u8 {
        const len = @as(usize, @intCast(self.toDriverBufferLength()));
        return self.mapped[CNC_HEADER_SIZE..][0..len];
    }

    pub fn toClientsBuffer(self: *CncFile) []u8 {
        const off = CNC_HEADER_SIZE + @as(usize, @intCast(self.toDriverBufferLength()));
        const len = @as(usize, @intCast(
            std.mem.readInt(i32, self.mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], .little)));
        return self.mapped[off..][0..len];
    }
};
```

- [ ] **Step 5: Wire into MediaDriver.init()**

In `src/driver/media_driver.zig`, in `MediaDriver.init()`, after creating `aeron_dir`:

```zig
const cnc_path = try std.fmt.allocPrint(allocator, "{s}/CnC.dat", .{ctx.aeron_dir});
defer allocator.free(cnc_path);
self.cnc = try CncFile.create(allocator, cnc_path, .{
    .to_driver_buffer_length = 1024 * 1024,
    .to_clients_buffer_length = 1024 * 1024,
    .counters_metadata_buffer_length = 1024 * 1024,
    .counters_values_buffer_length = 4 * 1024 * 1024,
    .client_liveness_timeout_ns = ctx.client_liveness_timeout_ns,
});
```

- [ ] **Step 6: Run all tests**

```bash
make check
```

- [ ] **Step 7: Commit**

```bash
git add src/driver/cnc.zig src/driver/media_driver.zig
git commit -m "feat: implement CnC.dat file with version magic and buffer layout (I-7)"
```

---

## I-8: `Aeron.doWork()` Real Conductor Polling

**Files:**
- Modify: `src/aeron.zig`
- Modify: `test/harness.zig` (expose `aeron_dir` field and `doConductorWork` if not already added by I-4)
- Modify: `test/integration_test.zig`

- [ ] **Step 1: Read aeron.zig**

```bash
cat src/aeron.zig
```

Find the stub `doWork()` and `AeronContext`.

- [ ] **Step 2: Write the failing integration test**

Add to `test/integration_test.zig`:

```zig
test "Aeron client: addPublication writes command, doWork receives ready response" {
    const allocator = std.testing.allocator;
    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    var client = try @import("aeron").Aeron.init(allocator, .{ .aeron_dir = h.aeron_dir });
    defer client.deinit();

    _ = try client.addPublication("aeron:ipc", 1001);

    // Drive conductor and client until publication ready
    // doConductorWork added to harness in I-4; if I-4 is not yet merged, add it here too.
    var ready = false;
    for (0..1000) |_| {
        h.doConductorWork(1);
        if (client.doWork() > 0) { ready = true; break; }
    }
    try std.testing.expect(ready);
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-integration 2>&1 | grep -A10 "addPublication writes"
```

- [ ] **Step 4: Implement real doWork()**

Expand `Aeron` struct to hold a CnC mapping:

```zig
pub const Aeron = struct {
    ctx: AeronContext,
    allocator: std.mem.Allocator,
    cnc: ?*@import("driver/cnc.zig").CncFile = null,
    ring_buf: ?@import("ipc/ring_buffer.zig").ManyToOneRingBuffer = null,
    broadcast_rx: ?@import("ipc/broadcast.zig").BroadcastReceiver = null,
    correlation_counter: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, ctx: AeronContext) !Aeron {
        // Open existing CnC.dat (driver must already be running)
        const cnc_path = try std.fmt.allocPrint(allocator, "{s}/CnC.dat", .{ctx.aeron_dir});
        defer allocator.free(cnc_path);
        // ... open and mmap CnC.dat, locate ring buffer and broadcast buffer slices
        // ... init ManyToOneRingBuffer on toDriverBuffer slice
        // ... init BroadcastReceiver on toClientsBuffer slice
        return .{ .ctx = ctx, .allocator = allocator };
    }

    pub fn doWork(self: *Aeron) i32 {
        var work: i32 = 0;
        if (self.broadcast_rx) |*rx| {
            while (rx.receiveNext()) {
                // Dispatch by message type: ON_PUBLICATION_READY, ON_SUBSCRIPTION_READY, etc.
                work += 1;
            }
        }
        return work;
    }

    pub fn addPublication(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        self.correlation_counter += 1;
        const correlation_id = self.correlation_counter;
        // Encode ADD_PUBLICATION command into ring buffer so conductor can process it.
        // Message layout: correlation_id(i64) + stream_id(i32) + channel_length(i32) + channel bytes
        if (self.ring_buf) |*rb| {
            var buf: [512]u8 = undefined;
            std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
            std.mem.writeInt(i32, buf[8..12], stream_id, .little);
            std.mem.writeInt(i32, buf[12..16], @as(i32, @intCast(channel.len)), .little);
            @memcpy(buf[16..][0..channel.len], channel);
            _ = rb.write(1, buf[0..16 + channel.len]); // msg_type 1 = ADD_PUBLICATION
        }
        return correlation_id;
    }
};
```

- [ ] **Step 5: Run tests**

```bash
make test-integration
```

- [ ] **Step 6: Commit**

```bash
git add src/aeron.zig
git commit -m "feat: real Aeron.doWork() reads broadcast buffer from CnC.dat (I-8)"
```

---

## Milestone 2 Merge

- [ ] **Step 1: Run full check**

```bash
make check
```

- [ ] **Step 2: Run the end-to-end Zig-only round-trip test**

```bash
make test-integration 2>&1 | grep -E "PASS|FAIL"
```

Expected: `round-trip 1 message` passes, `addPublication writes command` passes.

- [ ] **Step 3: Update tracking table and commit**

```bash
git add docs/plans/phase6.md
git commit -m "chore: milestone M2 — Zig-only driver working end-to-end"
```

---

## C-5: Write Transport Chapter

**Files:**
- Modify: `src/transport/*.zig` (add LESSON comments)
- Create: `docs/tutorial/part/transport.md`

- [ ] **Step 1: Read transport files**

```bash
cat src/transport/udp_channel.zig src/transport/endpoint.zig src/transport/poller.zig src/transport/uri.zig
```

- [ ] **Step 2: Add dual LESSON comments**

Key annotations for `endpoint.zig`:

```zig
// LESSON(transport/zig): SOCK_NONBLOCK avoids a separate fcntl() call. On Linux this is
// an atomic socket + nonblock setup. On macOS it still requires FIONBIO — Zig's std.posix
// handles this transparently via the SOCK.NONBLOCK flag.

// LESSON(transport/aeron): Aeron sends two types of UDP datagrams: unicast (point-to-point)
// and multicast (one-to-many). The same SendChannelEndpoint handles both — multicast is just
// sendto() with a group address. The receiver joins the multicast group via setsockopt
// IP_ADD_MEMBERSHIP so the OS delivers those packets.
```

- [ ] **Step 3: Write tutorial chapter**

`docs/tutorial/part/transport.md` sections:
- Zig track: `std.posix` UDP API, `SOCK_NONBLOCK`, `recvfrom`/`sendto`, multicast socket options
- Aeron track: SETUP/STATUS handshake state machine, NAK flow, unicast vs multicast URI format
- Both tracks: the Aeron URI — how a single string like `aeron:udp?endpoint=224.0.1.1:40456|interface=eth0` encodes socket configuration

- [ ] **Step 4: Verify tutorial compile-check passes**

```bash
make tutorial-check
```

- [ ] **Step 5: Commit**

```bash
git add src/transport/ docs/tutorial/part/transport.md
git commit -m "docs: dual-annotate transport chapter (Zig + Aeron tracks)"
```

---

## C-6: Write Conductor + CnC Chapter

**Files:**
- Modify: `src/driver/cnc.zig`, `src/driver/conductor.zig` (add LESSON comments)
- Create: `docs/tutorial/part/conductor-cnc.md`

- [ ] **Step 1: Add LESSON comments to cnc.zig and conductor.zig**

`cnc.zig`:

```zig
// LESSON(conductor/zig): std.posix.mmap maps a file into the process's virtual address space.
// Reads and writes to the returned slice go directly to the file — no read()/write() syscalls
// in the hot path. The OS handles flushing to disk when memory pressure requires it.

// LESSON(conductor/aeron): CnC.dat is not just IPC shared memory — it's a discovery contract.
// Any process that knows the aeron.dir path can find the driver by opening CnC.dat, reading
// the version magic to verify compatibility, then computing the ring buffer offset as
// CNC_HEADER_SIZE bytes from the start of the file.
```

- [ ] **Step 2: Write tutorial chapter**

`docs/tutorial/part/conductor-cnc.md` sections:
- Zig track: `std.posix.mmap`, file-backed shared memory, pointer arithmetic into mapped slices
- Aeron track: how a Java `Aeron.connect()` call works step by step (find CnC.dat → verify version → map ring buffer → send CLIENT_KEEPALIVE)
- Both tracks: the resource lifecycle — how publications are reference-counted and what happens when a client crashes

- [ ] **Step 3: Verify tutorial compile-check passes**

```bash
make tutorial-check
```

- [ ] **Step 4: Commit**

```bash
git add src/driver/cnc.zig src/driver/conductor.zig docs/tutorial/part/conductor-cnc.md
git commit -m "docs: dual-annotate conductor+CnC chapter (Zig + Aeron tracks)"
```

---

## C-7: Annotate Example Apps

**Files:**
- Modify: `examples/basic_publisher.zig`, `examples/basic_subscriber.zig`, `examples/throughput.zig`, `examples/cluster_demo.zig`

- [ ] **Step 1: Read all example files**

```bash
cat examples/basic_publisher.zig examples/basic_subscriber.zig examples/throughput.zig examples/cluster_demo.zig
```

- [ ] **Step 2: Add inline dual comments to every non-trivial call**

Format: `// ZIG: <what this Zig construct does>` and `// AERON: <what this means in Aeron terms>`.

Example for `basic_publisher.zig`:

```zig
// ZIG: Aeron.init() mmaps CnC.dat and wraps the ring buffer + broadcast receiver.
// AERON: This is the client "connecting" to the media driver. No TCP handshake — just
// opening a shared memory file that the driver already created.
var aeron = try Aeron.init(allocator, .{ .aeron_dir = "/dev/shm/aeron" });

// ZIG: addPublication() writes one record to the ring buffer using CAS.
// AERON: The driver conductor will read this ADD_PUBLICATION command and create a log buffer
// file. We get the file path back in ON_PUBLICATION_READY.
const pub_handle = try aeron.addPublication("aeron:ipc", 1001);
```

- [ ] **Step 3: Verify all examples still compile**

```bash
make examples
```

- [ ] **Step 4: Commit**

```bash
git add examples/
git commit -m "docs: add ZIG:/AERON: dual annotations to all example apps"
```

---

## I-9: Java Interop Smoke Test

**Files:**
- Create: `test/interop/docker-compose.yml`
- Create: `test/interop/BasicPublisher.java`
- Create: `test/interop/BasicSubscriber.java`
- Create: `test/interop/run.sh`
- Create: `Dockerfile` (minimal: FROM scratch + copy zig-out/bin/aeron-subscriber)

- [ ] **Step 1: Create test/interop directory and root Dockerfile**

```bash
mkdir -p test/interop
```

Write `Dockerfile` at the repo root for the `zig-sub` service:

```dockerfile
FROM debian:bookworm-slim
COPY zig-out/bin/aeron-subscriber /usr/local/bin/aeron-subscriber
ENTRYPOINT ["/usr/local/bin/aeron-subscriber"]
```

Build the Zig subscriber binary first: `make build`.

- [ ] **Step 2: Write docker-compose.yml**

```yaml
# test/interop/docker-compose.yml
# Uses the official aeronmd Docker image which bundles aeron-all.jar at /opt/aeron/aeron-all.jar
services:
  java-pub:
    image: eclipse-temurin:21
    volumes:
      - ./BasicPublisher.java:/app/BasicPublisher.java
      - ./aeron-all.jar:/app/aeron-all.jar   # downloaded by run.sh before compose up
      - /dev/shm:/dev/shm
    working_dir: /app
    command: >
      sh -c "javac -cp aeron-all.jar BasicPublisher.java &&
             java -cp .:aeron-all.jar BasicPublisher"
    network_mode: host

  zig-sub:
    build:
      context: ../..
      dockerfile: Dockerfile
    command: ["./zig-out/bin/aeron-subscriber", "--stream-id=1001"]
    network_mode: host
    depends_on: [java-pub]
```

- [ ] **Step 3: Write BasicPublisher.java**

```java
// test/interop/BasicPublisher.java
import io.aeron.*;
import io.aeron.driver.MediaDriver;
import org.agrona.concurrent.UnsafeBuffer;
import java.nio.ByteBuffer;

public class BasicPublisher {
    public static void main(String[] args) throws Exception {
        try (MediaDriver driver = MediaDriver.launchEmbedded();
             Aeron aeron = Aeron.connect(new Aeron.Context()
                 .aeronDirectoryName(driver.aeronDirectoryName()));
             Publication pub = aeron.addPublication("aeron:ipc", 1001)) {

            UnsafeBuffer buf = new UnsafeBuffer(ByteBuffer.allocateDirect(256));
            for (int i = 0; i < 100; i++) {
                buf.putStringWithoutLengthAscii(0, "msg-" + i);
                while (pub.offer(buf, 0, 5 + String.valueOf(i).length()) < 0) {
                    Thread.onSpinWait();
                }
            }
            System.out.println("Published 100 messages");
        }
    }
}
```

- [ ] **Step 4: Write run.sh**

```bash
#!/usr/bin/env bash
# test/interop/run.sh — gated on AERON_INTEROP=1
set -euo pipefail

if [ "${AERON_INTEROP:-0}" != "1" ]; then
  echo "SKIP: set AERON_INTEROP=1 to run Java interop tests"
  exit 0
fi

# Download aeron-all.jar if not already present (version must match upstream tag)
AERON_VERSION="${AERON_VERSION:-1.44.1}"
JAR="test/interop/aeron-all.jar"
if [ ! -f "$JAR" ]; then
  echo "Downloading aeron-all-${AERON_VERSION}.jar..."
  curl -fsSL -o "$JAR" \
    "https://repo1.maven.org/maven2/io/aeron/aeron-all/${AERON_VERSION}/aeron-all-${AERON_VERSION}.jar"
fi

echo "=== Interop test 1: Java pub -> Zig sub ==="
docker compose -f test/interop/docker-compose.yml up --abort-on-container-exit
echo "=== PASS ==="
```

```bash
chmod +x test/interop/run.sh
```

- [ ] **Step 5: Add interop target to Makefile**

```makefile
test-interop:
	bash test/interop/run.sh
```

- [ ] **Step 6: Verify skip works (AERON_INTEROP not set)**

```bash
make test-interop
```

Expected: `SKIP: set AERON_INTEROP=1 to run Java interop tests`.

- [ ] **Step 7: Commit**

```bash
git add test/interop/ Makefile
git commit -m "feat: Java interop smoke test (gated on AERON_INTEROP=1)"
```

---

## Milestone 3 Merge

- [ ] **Step 1: Run full check**

```bash
make check
```

- [ ] **Step 2: (If Docker available) Run interop test**

```bash
AERON_INTEROP=1 make test-interop
```

Expected: both pub→sub directions pass.

- [ ] **Step 3: Update tracking table and commit**

```bash
git add docs/plans/phase6.md
git commit -m "chore: milestone M3 — Java interop complete"
```

---

## C-8: Write Interop Chapter

**Files:**
- Create: `docs/tutorial/part/interop.md`

- [ ] **Step 1: Write the chapter**

`docs/tutorial/part/interop.md` sections:
- Step-by-step: what happens when `java Aeron.connect()` is called against our Zig driver
  (find CnC.dat → read version → map ring buffer → send CLIENT_KEEPALIVE → wait for response)
- What still doesn't interop: archive protocol (SBE required), cluster protocol (SBE required)
- Why SBE: explain Simple Binary Encoding — schema-driven, zero-allocation, backward compatible.
  Link to `aeron-archive/src/main/resources/archive/*.xml` SBE schemas.
- How to extend: what a full SBE-compatible archive implementation would look like

- [ ] **Step 2: Commit**

```bash
git add docs/tutorial/part/interop.md
git commit -m "docs: write interop chapter with Java handshake walkthrough and SBE note"
```

---

## C-9: Write Course Index + Reading Paths

**Files:**
- Create: `docs/tutorial/README.md`

- [ ] **Step 1: Write the index**

```markdown
# Aeron in Zig — Course Index

## Two reading tracks

### Track A: "I'm learning Zig"
You want to understand how Zig handles systems programming — memory layout,
atomics, mmap, lock-free data structures. Aeron is your motivating problem.

Follow the ZIG: annotations. Recommended order:
1. frame-codec.md — extern struct, comptime, align()
2. logbuffer.md — atomics, CAS, bit packing
3. ipc.md — lock-free ring buffer, memory ordering
4. transport.md — posix sockets, non-blocking I/O
5. conductor-cnc.md — mmap, file-backed shared memory

### Track B: "I'm learning Aeron"
You want to understand how Aeron achieves low-latency reliable UDP messaging.
Zig is just the implementation language — readable and close to the metal.

Follow the AERON: annotations. Recommended order:
1. frame-codec.md — wire frame layout, the base header
2. logbuffer.md — zero-copy data path, term rotation
3. ipc.md — client↔driver protocol, CnC.dat
4. transport.md — SETUP/STATUS handshake, NAK retransmit
5. conductor-cnc.md — resource lifecycle, client liveness
6. interop.md — Java↔Zig handshake, what interop means

## Chapter list

| Chapter | Zig concepts | Aeron concepts |
|---------|-------------|----------------|
| [frame-codec.md](part/frame-codec.md) | extern struct, comptime assert, align() | Wire frame layout, frame types |
| [logbuffer.md](part/logbuffer.md) | CAS, atomic ops, bit packing | Zero-copy path, term rotation, 3 partitions |
| [ipc.md](part/ipc.md) | Lock-free ring buffer, memory ordering | Client→driver commands, driver→client notifications |
| [transport.md](part/transport.md) | posix sockets, non-blocking I/O | SETUP/STATUS, NAK flow, URI format |
| [conductor-cnc.md](part/conductor-cnc.md) | mmap, file-backed shared memory | CnC.dat, resource lifecycle |
| [interop.md](part/interop.md) | — | Java↔Zig handshake, SBE note |
```

- [ ] **Step 2: Commit**

```bash
git add docs/tutorial/README.md
git commit -m "docs: write course index with Zig-track and Aeron-track reading paths"
```

---

## Agent Prompt Template

The sub-agent prompt template is already written at `docs/templates/phase6-sub-agent-prompt.md`.
Read it before dispatching any sub-agent — it includes `Lane`, `Milestone`, and `Quick Reference`
sections required for each task.

No write step needed — the file exists and is committed.

---

## Quick Reference

```bash
make check           # fmt-check + build + all tests — must pass before every commit
make test-unit       # unit tests only (fast)
make test-integration # integration tests
make examples        # build all example binaries
make tutorial-check  # compile-check tutorial stubs
AERON_INTEROP=1 make test-interop  # Java interop smoke test (requires Docker)
```
