# Interop Investigation — java-pub→zig-sub (2/100)

## Status

| Direction | Result | Notes |
|-----------|--------|-------|
| zig-pub → java-sub | **PASS 100/100** | Fixed in this session |
| java-pub → zig-sub | **FAIL 2/100** | Active investigation |

Branch: `feat/phase8-uri-fidelity` — PR #11

## Bugs Fixed This Session

### 1. Image.poll() wrong partition (`src/image.zig`)

**Was:** Read `meta.activeTermCount()` for partition — always 0 because receiver never updates log metadata.

**Fix:** Compute partition from `subscriber_position / term_length % 3`.

### 2. Missing initial_term_id in IMAGE_READY (`conductor.zig` + `aeron.zig`)

**Was:** `sendImageReady` sent 16 bytes (registration_id, session_id, stream_id). Client Image always got `initial_term_id = 0`.

**Fix:** Extended to 20 bytes, added `initial_term_id`. Client reads it from buffer[16..20].

### 3. Sender SETUP chicken-and-egg (`sender.zig`)

**Was:** `processPublication` returned immediately when `sender_pos >= pub_limit` (both start at 0), so SETUP was never sent. Without SETUP → no subscriber Image → no STATUS → publisher_limit stays 0.

**Fix:** Moved SETUP send before the `sender_pos >= pub_limit` check. SETUP is now sent unconditionally every 50ms.

### 4. Receiver frame_length overwrite (`receiver.zig`)

**Was:** `insertFrame` overwrote wire `frame_length` with `aligned_len`, causing TermReader to include padding bytes in payload.

**Fix:** Write `total_frame_len` (matches wire value) instead of `aligned_len`. TermReader and `advanceRebuildPosition` both align at read time.

### 5. ConfigMap BasicPublisher.java stale (`java-apps-configmap.yaml`)

**Was:** ConfigMap version didn't call `isConnected()` — sent 100 messages immediately, before Zig Image existed.

**Fix:** Added `isConnected()` wait loop (15s deadline) + 1.5s warmup delay.

## Remaining Bug: java-pub→zig-sub 2/100

### Observed Behavior

```
[CONDUCTOR] Processing 1 setups
[CONDUCTOR] Found subscription for stream 1001, creating image...
[IMAGE] poll: partition=0 term_offset=0 fragments=2 read_bytes=128 new_pos=128
[ZIG] ERROR: Timeout waiting for messages (received 2/100).
```

- Java publisher waits for `isConnected()`, gets STATUS, does 1.5s warmup, sends 100 messages. All succeed.
- Zig receiver creates Image from SETUP (correct `initial_term_id`).
- Client Image.poll reads **exactly 2 frames** from partition 0, offsets 0-127, then sees `frame_length = 0` at offset 128.
- No `[RECEIVER] insertFrame FAILED` or `[RECEIVER] DATA for unknown session` messages printed.

### Diagnostic Logging In Place

| Location | Print prefix | What it shows |
|----------|-------------|---------------|
| `receiver.zig` insertFrame failure | `[RECEIVER] insertFrame FAILED` | Bounds check or duplicate rejection |
| `receiver.zig` unknown session | `[RECEIVER] DATA for unknown` | Frame arrived before Image created |
| `image.zig` poll success | `[IMAGE] poll:` | Partition, offset, fragments read, new position |

### Hypotheses (ordered by likelihood)

#### H1: Receiver thread only processes ~2 DATA frames before Java finishes

The receiver reads **one UDP packet per `doWork()` call**. The receiver thread loops freely, but:
- Java sends 100 frames in a tight loop (~ms total)
- Zig receiver thread also handles SETUP/STATUS on the same socket
- The receiver might process SETUP + 2 DATA frames, then Java's driver closes the socket before more arrive

**Test:** Add a frame counter to `processDatagram` that prints total DATA frames received at session end.

#### H2: Java Sender batches multiple frames into one UDP packet

Java Aeron's Sender may coalesce multiple small frames into a single MTU-sized UDP packet. The Zig receiver's `processDatagram` only processes **one frame per call** — it reads the first DataHeader and ignores the rest of the packet.

**Test:** Print `data.len` in `processDatagram` for DATA frames. If `data.len >> frame_length`, frames are batched.

**Fix if confirmed:** Loop within `processDatagram` to process all frames in the packet.

#### H3: Socket contention between sender and receiver threads

Both threads share the same `fd`. The sender sends STATUS/SETUP responses while the receiver reads incoming packets. On Linux/aarch64 (Colima), concurrent `sendto`/`recvfrom` on the same UDP socket should be safe, but worth verifying.

**Test:** Unlikely root cause — deprioritize.

#### H4: Term buffer position mismatch

The Java publisher may use a non-zero `active_term_id` in SETUP, meaning DATA frames start with `term_offset` > 0 within that term. The Zig client Image starts at `subscriber_position = 0`, reading from offset 0, which might not be where the first frame actually lives.

**Test:** Print `header.term_id`, `header.term_offset` for each received DATA frame. Compare with Image's read position.

### Recommended Next Steps

1. **Run `make interop` and capture full `kubectl logs`** — diagnostic prints are already in place
2. **Add frame counter** to `processDatagram` — count total DATA frames received per session
3. **Print `data.len`** for each DATA packet — check for frame batching (H2)
4. **If H2 confirmed:** Add a loop in `processDatagram` to walk all frames in the UDP packet
5. **If all 100 frames received:** The issue is in log buffer write offsets — print `header.term_id` and `header.term_offset` for each frame

### Architecture Reference

```
java-pub-zig-sub pod (shared /dev/shm, loopback):

  Java Container                          Zig Container
  ┌─────────────────┐                    ┌─────────────────┐
  │ BasicPublisher   │                    │ basic_subscriber │
  │   └─ Publication │                    │   └─ Subscription│
  │       └─ offer() │                    │       └─ poll()  │
  ├─────────────────┤                    ├─────────────────┤
  │ Java MediaDriver │                    │ Zig MediaDriver  │
  │ /dev/shm/java    │                    │ /dev/shm/zig     │
  │ Sender ──SETUP──►│─── UDP:40124 ────►│ Receiver         │
  │        ──DATA───►│                    │  └─ Image.insert │
  │ Receiver◄─STATUS─│◄────────────────── │  └─ sendStatus() │
  └─────────────────┘                    └─────────────────┘
```

Channel: `aeron:udp?endpoint=127.0.0.1:40124`, Stream ID: 1001
