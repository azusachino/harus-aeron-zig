# Correctness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four highest-priority correctness issues: debug prints in hot paths, publication ref-counting, CLIENT_KEEPALIVE in client lib, and dynamic NAK gap list.

**Architecture:** Surgical fixes to existing modules — no new subsystems. Each task is a standalone commit touching 1-2 files.

**Tech Stack:** Zig 0.15.2, `make check` for verification.

---

### Task 1: Replace `std.debug.print` with EventLog in receiver hot paths

**Files:**
- Modify: `src/driver/receiver.zig` (lines 319, 339, 374, 383, 397, 446)

The receiver already has an `event_log` field (line 227) and uses it in one place (lines 344-346). Six other `std.debug.print` calls in `processDatagram()` and `doWork()` bypass it.

- [ ] **Step 1: Replace DATA frame debug print with event_log**

In `src/driver/receiver.zig`, line 319 inside `processDatagram()`:

Replace:
```zig
std.debug.print("[RECEIVER] DATA frame #{d}: pkt_len={d} term_id={d} term_offset={d} frame_len={d} session={d} stream={d}\n", .{
    self.total_frames, pkt_len, data_header.term_id, data_header.term_offset, frame_length, data_header.session_id, data_header.stream_id,
});
```

With:
```zig
if (self.event_log) |log| {
    log.logFrameIn(frame_length, data_header.session_id, data_header.stream_id, data_header.term_id, data_header.term_offset);
}
```

If `logFrameIn` does not exist on EventLog, use the existing logging pattern from lines 344-346 as the template. If no suitable method exists, gate the print behind a comptime or runtime debug flag:
```zig
if (builtin.mode == .Debug) {
    std.debug.print("[RECEIVER] DATA frame ...\n", .{ ... });
}
```

- [ ] **Step 2: Replace remaining 5 debug prints in receiver**

Apply the same pattern to lines 339, 374, 383, 397, 446:
- Line 339 (insertFrame failure): gate behind `event_log` or `builtin.mode == .Debug`
- Line 374 (unknown session): gate behind `event_log` or `builtin.mode == .Debug`
- Line 383 (sending STATUS): gate behind `event_log` or `builtin.mode == .Debug`
- Line 397 (SETUP frame): gate behind `event_log` or `builtin.mode == .Debug`
- Line 446 (recv error): gate behind `event_log` or `builtin.mode == .Debug`

For each: if EventLog has a matching method, use it. Otherwise use `if (builtin.mode == .Debug)` guard.

- [ ] **Step 3: Run tests**

```bash
make check
```

Expected: all tests pass, no compilation errors.

- [ ] **Step 4: Commit**

```bash
git add src/driver/receiver.zig
git commit -m "fix: gate receiver debug prints behind event_log or Debug mode"
```

---

### Task 2: Replace `std.debug.print` with structured logging in conductor

**Files:**
- Modify: `src/driver/conductor.zig` (lines 177, 198, 208, 212, 308, 623, 786)

Conductor has no `event_log` field. These prints are in setup/command processing (not per-frame hot paths) but still shouldn't be unconditional in production.

- [ ] **Step 1: Add log import and gate all conductor debug prints**

At the top of `src/driver/conductor.zig`, ensure `builtin` is imported:
```zig
const builtin = @import("builtin");
```

Then wrap each `std.debug.print` call in `if (builtin.mode == .Debug)`:

Line 177 (`checkClientLiveness`):
```zig
if (builtin.mode == .Debug) {
    std.debug.print("[CONDUCTOR] Evicting timed-out client_id={d}\n", .{entry.client_id});
}
```

Apply the same pattern to lines 198, 208, 212, 308, 623, 786.

- [ ] **Step 2: Run tests**

```bash
make check
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/driver/conductor.zig
git commit -m "fix: gate conductor debug prints behind Debug mode"
```

---

### Task 3: Replace `std.debug.print` in media_driver.zig

**Files:**
- Modify: `src/driver/media_driver.zig` (lines 142, 145)

These are startup-only prints (socket bind result). Lower priority but should be consistent.

- [ ] **Step 1: Gate media_driver prints behind Debug mode**

```zig
if (builtin.mode == .Debug) {
    std.debug.print("[DRIVER] Failed to bind to port {d}: {any}\n", .{ port, err });
}
```

Same for line 145 (bind success).

- [ ] **Step 2: Run tests and commit**

```bash
make check
git add src/driver/media_driver.zig
git commit -m "fix: gate media driver startup prints behind Debug mode"
```

---

### Task 4: Fix publication ref-counting in conductor

**Files:**
- Modify: `src/driver/conductor.zig` — `handleAddPublication` (~line 548), `handleRemovePublication` (~line 579)

Currently `ref_count` is initialized to 1 but never incremented on duplicate add or decremented/checked on remove. Resources are freed on first remove regardless.

- [ ] **Step 1: Write failing test**

Create or extend `test/driver/conductor_test.zig` (or the existing test file) with:

```zig
test "publication ref-counting: second add increments, first remove does not free" {
    // Setup: create a conductor with test allocator
    // 1. Send ADD_PUBLICATION for stream 1001 → expect ON_PUBLICATION_READY
    // 2. Send ADD_PUBLICATION for same channel+stream → expect ON_PUBLICATION_READY (ref_count=2)
    // 3. Send REMOVE_PUBLICATION with first correlation_id → resources NOT freed (ref_count=1)
    // 4. Send REMOVE_PUBLICATION with second correlation_id → resources freed (ref_count=0)
    // Verify: after step 3, publication entry still exists; after step 4, it's gone
}
```

Adapt this to the existing test harness patterns — check `test/driver/` for how conductor tests are structured.

- [ ] **Step 2: Run test to verify it fails**

```bash
make test-unit
```

Expected: FAIL — second add doesn't increment ref_count, first remove frees everything.

- [ ] **Step 3: Fix handleAddPublication — increment ref_count on duplicate**

In `handleAddPublication`, when a matching publication already exists (same channel + stream_id), increment `ref_count` instead of creating a new entry:

```zig
// Check if publication already exists for this channel+stream
for (self.publications.items) |*entry| {
    if (entry.stream_id == stream_id and std.mem.eql(u8, entry.channel, channel)) {
        entry.ref_count += 1;
        // Send ON_PUBLICATION_READY with existing entry's details
        self.sendPublicationReady(entry, correlation_id);
        return;
    }
}
// ... existing new-publication creation with ref_count = 1
```

- [ ] **Step 4: Fix handleRemovePublication — decrement and check ref_count**

In `handleRemovePublication`, decrement ref_count first. Only free resources when it reaches 0:

```zig
fn handleRemovePublication(self: *DriverConductor, data: []const u8) void {
    const correlation_id = // parse from data

    for (self.publications.items, 0..) |*entry, i| {
        if (entry.registration_id == correlation_id) {
            entry.ref_count -= 1;
            if (entry.ref_count <= 0) {
                // Free log buffer, counters, network publication
                self.freePublicationResources(entry);
                _ = self.publications.swapRemove(i);
            }
            return;
        }
    }
}
```

- [ ] **Step 5: Run tests**

```bash
make check
```

Expected: all tests pass including the new ref-counting test.

- [ ] **Step 6: Commit**

```bash
git add src/driver/conductor.zig test/driver/conductor_test.zig
git commit -m "fix: implement publication ref-counting (increment on dup add, decrement on remove)"
```

---

### Task 5: Add CLIENT_KEEPALIVE heartbeat to client library

**Files:**
- Modify: `src/aeron.zig` — add periodic keepalive in the client's poll/idle loop

The driver already handles `CMD_CLIENT_KEEPALIVE` (conductor.zig line 866) and evicts clients after 5s of no keepalive. But the client library never sends keepalives — it relies on implicit IPC activity.

- [ ] **Step 1: Write failing test**

In the client test file (find via `test/` for aeron client tests):

```zig
test "client sends keepalive within liveness timeout" {
    // Setup: create Aeron client connected to a test conductor
    // 1. Connect client
    // 2. Wait idle (no pub/sub activity) for 2 seconds
    // 3. Verify client sent at least one CMD_CLIENT_KEEPALIVE via ring buffer
    // The conductor should NOT have evicted the client
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test-unit
```

Expected: FAIL — client sends no keepalive during idle.

- [ ] **Step 3: Implement keepalive in client**

In `src/aeron.zig`, add a keepalive timer to the client struct:

```zig
const KEEPALIVE_INTERVAL_MS: i64 = 1_000; // Send every 1s (well within 5s timeout)

last_keepalive_ms: i64 = 0,
```

In the client's `doWork()` or `poll()` method (wherever the client's duty cycle runs):

```zig
fn sendKeepaliveIfDue(self: *Aeron) void {
    const now_ms = std.time.milliTimestamp();
    if (now_ms - self.last_keepalive_ms >= KEEPALIVE_INTERVAL_MS) {
        self.last_keepalive_ms = now_ms;
        // Write CMD_CLIENT_KEEPALIVE to the to-driver ring buffer
        // Message format: [correlation_id: i64, client_id: i64]
        var buf: [16]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], self.client_id, .little);
        std.mem.writeInt(i64, buf[8..16], self.client_id, .little);
        _ = self.to_driver.write(CMD_CLIENT_KEEPALIVE, &buf);
    }
}
```

Call `sendKeepaliveIfDue()` from the client's duty cycle method.

- [ ] **Step 4: Run tests**

```bash
make check
```

Expected: all tests pass including the new keepalive test.

- [ ] **Step 5: Commit**

```bash
git add src/aeron.zig test/aeron_test.zig
git commit -m "feat: add periodic CLIENT_KEEPALIVE heartbeat to client library"
```

---

### Task 6: Dynamic NAK gap list in receiver

**Files:**
- Modify: `src/driver/receiver.zig` — `NakState` struct (~line 171)

Currently `gap_list: [16]GapRange` is a fixed array. When full, new gaps are silently dropped. Replace with a dynamically growable list.

- [ ] **Step 1: Write failing test**

In the receiver test file:

```zig
test "NakState handles more than 16 gaps" {
    var nak = NakState{ .stream_id = 1 };
    // Add 20 non-overlapping gaps
    for (0..20) |i| {
        const offset: i32 = @intCast(i * 1000);
        nak.addGap(offset, 100);
    }
    // All 20 gaps should be recorded
    try std.testing.expectEqual(@as(usize, 20), nak.gap_list_len);
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test-unit
```

Expected: FAIL — gap_list_len capped at 16.

- [ ] **Step 3: Replace fixed array with ArrayList**

In `NakState`:

```zig
const std = @import("std");

pub const NakState = struct {
    stream_id: i32,
    gap_list: std.ArrayList(GapRange),
    first_gap_ns: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, stream_id: i32) NakState {
        return .{
            .stream_id = stream_id,
            .gap_list = std.ArrayList(GapRange).init(allocator),
        };
    }

    pub fn deinit(self: *NakState) void {
        self.gap_list.deinit();
    }

    pub fn addGap(self: *NakState, offset: i32, length: i32) void {
        // Try to merge with existing gaps first
        for (self.gap_list.items) |*gap| {
            if (gap.offset + gap.length >= offset and offset + length >= gap.offset) {
                const new_offset = @min(gap.offset, offset);
                const new_end = @max(gap.offset + gap.length, offset + length);
                gap.offset = new_offset;
                gap.length = new_end - new_offset;
                return;
            }
        }
        // No merge — append
        self.gap_list.append(.{ .offset = offset, .length = length }) catch return;
    }

    // ... rest of methods updated to use self.gap_list.items and self.gap_list.items.len
};
```

Update all call sites that reference `gap_list_len` to use `gap_list.items.len`.
Update all call sites that create `NakState` to pass an allocator and call `init()`.
Update all cleanup paths to call `deinit()`.

- [ ] **Step 4: Update NakState creation sites in receiver.zig**

Find where `NakState` is created (likely in Image init or receiver setup) and pass the allocator. Add `deinit()` calls in the corresponding cleanup/destroy paths.

- [ ] **Step 5: Run tests**

```bash
make check
```

Expected: all tests pass including the new 20-gap test.

- [ ] **Step 6: Commit**

```bash
git add src/driver/receiver.zig test/driver/receiver_test.zig
git commit -m "fix: replace fixed NAK gap list with dynamic ArrayList"
```
