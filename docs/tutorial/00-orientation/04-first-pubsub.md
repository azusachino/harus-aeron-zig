# Your First Pub/Sub

This chapter walks through a concrete pub/sub exchange — not just the API, but what
happens at every layer from the function call to the UDP socket. By the end you will
have a map you can cross-reference as you implement each component in later chapters.

## Running the Demo

Start the media driver in one terminal:

```bash
make run
```

The driver creates its IPC directory (defaults to `/dev/shm/aeron`), starts the
Conductor, Sender, and Receiver threads, and begins polling for client connections.

In a second terminal, run the built-in loopback example (publisher and subscriber in
the same process, communicating via the driver):

```bash
zig build run-example -- --channel aeron:udp?endpoint=localhost:20121 --stream 1001
```

You should see throughput metrics printed every second.

## What Happens When You Call offer()

Assume the channel and stream have already been negotiated with the driver and the
`Publication` object holds a memory-mapped view of the log buffer.

### Step 1 — Claim space in the term

```zig
// Inside Publication.offer()
const result = try self.term_appender.appendFrame(self.term_buffer, msg);
```

`TermAppender.appendFrame` atomically increments the tail counter by
`alignedLength(header_size + msg.len)`. The return value is the offset the publisher
claimed. If the offset would exceed the term length, the publisher wraps to the next
term and returns `ADMIN_ACTION`.

### Step 2 — Write the frame

The header is written first (`term_offset`, `session_id`, `stream_id`, `term_id`,
`flags`). Then the payload is copied into the term at `offset + DataHeader.LENGTH`.
Finally, the `frame_length` field (first 4 bytes) is written with a release store,
which signals to the Sender that the frame is complete.

```
Log Buffer — term[active]
offset →  ┌──────────────────────────────────────┐
          │ DataHeader (32 bytes)                │
          │   frame_length (i32) ← written last  │
          │   flags, frame_type, term_offset     │
          │   session_id, stream_id, term_id     │
          ├──────────────────────────────────────┤
          │ payload (msg.len bytes)              │
          ├──────────────────────────────────────┤
          │ padding to 32-byte alignment         │
          └──────────────────────────────────────┘
```

### Step 3 — Sender transmits

On the Sender's next duty cycle, it scans the active term from the last-sent position
to the current tail. For each frame where `frame_length > 0` (meaning the publisher
finished writing it), the Sender calls `sendmsg()` with the log buffer memory directly
as the scatter-gather I/O vector. This is the zero-copy path: the kernel reads from
shared memory without an intermediate copy.

### Step 4 — Receiver writes to the image

The remote Receiver's `recvmsg()` call returns the frame. The Receiver validates the
header (version, frame type, checksum), looks up the matching `Image` by session ID,
and writes the frame into the image's log buffer at the term offset indicated by the
DATA frame header. It then advances the receiver position counter.

### Step 5 — poll() delivers the message

```zig
// Inside Subscription.poll()
const fragments = try self.image.poll(handler, max_fragments);
```

`TermReader.read` scans the image log buffer from the subscriber's current position.
For each complete frame (where `frame_length > 0`), it calls the handler and advances
the position. The handler receives a slice pointing directly into the image log buffer —
another zero-copy hand-off.

## The Log Buffer Before and After

Before `offer()`, the tail counter sits at offset 0 and all frame_length fields are 0:

```
term[0]:  [ 0 0 0 0 | ... zeroes ... ]
tail:     0
```

After `offer("hello")` (5 bytes, padded to 64 bytes total):

```
term[0]:  [ 64 0 0 0 | ver flags type | offset | session | stream | term | h e l l o ... pad ]
           ^^^                                                                first 4 bytes = frame_length
tail:     64
```

The `frame_length` field being 0 is the sentinel the Sender uses to detect a frame that
is still being written. The publisher writes it last, with a release store. The Sender
reads it with an acquire load. This is the only synchronization point between publisher
and Sender on the hot path.

## How to Use the Chapter Checkpoints

Each chapter in Parts 1–4 has a corresponding git tag:

```
chapter-1.1-frame-codec
chapter-1.2-ring-buffer
...
chapter-4.3-integration-tests
```

If you are stuck on an implementation, check out the reference solution:

```bash
git diff chapter-1.1-frame-codec -- src/protocol/frame.zig
```

This shows the difference between your current working tree and the reference for that
chapter's target file. You can check out the full reference solution with:

```bash
git checkout chapter-1.1-frame-codec -- src/protocol/frame.zig
```

Reset to your own working state with:

```bash
git checkout HEAD -- src/protocol/frame.zig
```

## What You Will Build, Part by Part

| Part | What you build | Milestone |
|------|---------------|-----------|
| 0 | Orientation (this) | Mental model |
| 1 | Frame codec, ring buffer, broadcast, counters, log buffer | All primitives pass tests |
| 2 | TermAppender, TermReader, fragment assembly | Messages flow through log buffer |
| 3 | Sender, Receiver, Conductor, MediaDriver | Driver boots and sends real UDP |
| 4 | Publication, Subscription, Aeron client | Full pub/sub in Zig, wire-compatible with Java Aeron |

At the end of Part 4, your implementation will exchange messages with an unmodified
Java Aeron client over UDP. That is the definition of "done" for Phase 1.

Continue to Part 1, Chapter 1: [Frame Codec](../01-foundations/01-frame-codec.md).
