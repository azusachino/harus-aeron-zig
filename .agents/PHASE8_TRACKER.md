# Phase 8 Interop Tracker

Branch: `feat/phase8-uri-fidelity` — PR #11
Date started: 2026-03-24

## Legend
- [ ] pending
- [x] done
- [~] in progress
- [!] blocked

---

## Session 1 — 2026-03-24 (Phase 8 fixes)

### Completed (previous session)
- [x] URI fidelity improvements (P8-1 partial)
- [x] Fix Image.poll() wrong partition (subscriber_position / term_length % 3)
- [x] Fix missing initial_term_id in IMAGE_READY (20-byte sendImageReady)
- [x] Fix Sender SETUP chicken-and-egg (SETUP sent before pub_limit check)
- [x] Fix receiver frame_length overwrite (write total_frame_len not aligned_len)
- [x] Fix ConfigMap BasicPublisher.java (add isConnected() wait + 1.5s warmup)
- **Result**: zig-pub → java-sub: PASS 100/100

### Remaining: java-pub → zig-sub (2/100)

#### Observed Behaviour
```
[CONDUCTOR] Processing 1 setups
[CONDUCTOR] Found subscription for stream 1001, creating image...
[IMAGE] poll: partition=0 term_offset=0 fragments=2 read_bytes=128 new_pos=128
[ZIG] ERROR: Timeout waiting for messages (received 2/100).
```

#### Task T1 — Create local tracker
- [x] Write this doc

#### Task T2 — Comprehensive diagnostics in receiver.zig
- [x] Add per-datagram `data.len` print for DATA frames ([RECEIVER] DATA frame #N)
- [x] Add per-frame term_id / term_offset print
- [x] Add total DATA-frames-received atomic counter (data_frames_total)
- [x] Print STATUS destination address when sending ([RECEIVER] sending STATUS to ...)
- [x] Print count of "DATA before Image" frames (data_frames_before_image counter)
- [x] Added SETUP diagnostic print with initial_term_id / active_term_id / src

#### Task T3 — Fix H2: multi-frame loop in processDatagram
- [x] Replaced single-frame dispatch with while(offset+8<=data.len) loop
- [x] Each frame advances by align(frame_length, FRAME_ALIGNMENT)
- [x] Also enlarged recv_buf from 4096 → 65536 to handle any datagram size

#### Task T4 — Fix H4: rebuild_position initialised from active_term_id
- [x] Image.init gains active_term_id param; sets rebuild_position = (active_term_id - initial_term_id) * term_length
- [x] conductor.zig Image.init call updated to pass sig.active_term_id
- [x] All 4 internal test call sites in receiver.zig updated (active_term_id = initial_term_id for tests)

#### Task T5 — Run make interop and capture logs
- [x] Colima started, images built and imported into k3s
- [x] Both jobs completed in <10s
- [x] java-pub → zig-sub: **PASS 100/100** ("Hello Aeron 0".."Hello Aeron 99")
- [x] zig-pub → java-sub: **PASS 100/100** (still solid)
- [x] Memory leak fixed: `aeron.zig` now calls `allocator.destroy(img)` for each heap-allocated `*Image` before `sub.deinit()`. Root cause: `Subscription.deinit()` freed the ArrayList but not the `*Image` pointers inside it.
- [x] Verified: re-run shows no `error(gpa): leaked` in any container

#### Task T6 — make check green after changes
- [x] make check passes (fmt + build + all tests) — 2026-03-24

---

## Hypothesis Tracker

| ID | Hypothesis | Status | Evidence |
|----|-----------|--------|---------|
| H1 | Receiver thread only processes ~2 frames before Java finishes (timing) | OPEN | No sleep in recv thread loop; tight loop should be fast enough |
| H2 | Java batches multiple frames into one UDP packet; processDatagram only reads first | OPEN → fixing | Implementation change in T3 |
| H3 | Socket contention between sender/receiver threads | LOW | send_endpoint is separate socket from recv_endpoint |
| H4 | Term buffer position mismatch — active_term_id != initial_term_id | OPEN → fixing | Image.rebuild_position=0 even if Java starts at term N |
| H5 | STATUS sent to wrong address / wrong port — Java never sees it after frame 2 | OPEN | Adding address print diagnostic in T2 |
| H6 | 98 DATA frames arrive BEFORE Image is created; "unknown session" prints missing from log collection | OPEN | Adding pre-image counter in T2 |

---

## Phase 8 Task Map

| Task | Status | Notes |
|------|--------|-------|
| P8-1 Wire Protocol Completion | partial | URI fidelity done; more frame variants remain |
| P8-2 Driver Runtime Fidelity | not started | |
| P8-3 Archive Operational Fidelity | not started | |
| P8-4 Cluster Consensus Fidelity | not started | |
| P8-5 CnC and Tooling Fidelity | partial | CnC file descriptor skeleton exists |
| P8-6 Interop and System-Test Automation | in progress — blocked on java-pub→zig-sub | |
| P8-7 Performance and Soak Baseline | not started | |

---

## Session Log

### 2026-03-24 Session 2
- Loaded session state from last commit (7dfc076 — interop investigation writeup)
- Creating PHASE8_TRACKER.md (this file)
- Implementing T2 (diagnostics), T3 (H2 multi-frame loop), T4 (H4 active_term_id fix)
- Will run T5 (make interop) after code changes
