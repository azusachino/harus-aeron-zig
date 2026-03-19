# 3.1 The Sender

The Sender is a duty-cycle agent: once per scheduler tick it wakes up, scans every active publication, drains frames from the log buffer into UDP datagrams, and goes back to sleep. It never blocks on I/O. It has no locks. It does not read from the network.

## Role and Responsibilities

- Read committed frames from each `NetworkPublication`'s term buffer.
- Send `DATA` frames over UDP to the subscriber's address.
- Emit `SETUP` frames periodically so new subscribers can learn stream geometry.
- Drain a retransmit queue to satisfy `NAK`-requested re-sends.

## NetworkPublication

`NetworkPublication` is the Sender's view of one active stream. It holds everything needed to drain and transmit frames:

```zig
pub const NetworkPublication = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    log_buffer: *logbuffer.LogBuffer,
    sender_position: counters.CounterHandle,  // how far the sender has read
    publisher_limit: counters.CounterHandle,  // how far the client has written
    send_channel: *endpoint.SendChannelEndpoint,
    dest_address: std.net.Address,
    mtu: i32,
    last_setup_time_ms: i64,
};
```

`sender_position` and `publisher_limit` are indices into a shared counter array — a memory-mapped slab visible to both the media driver and the client library. The client advances `publisher_limit` as it writes frames; the Sender advances `sender_position` as it reads and transmits them.

## The doWork Loop

```zig
pub fn doWork(self: *Sender) i32 {
    var work_count: i32 = 0;
    for (self.publications.items) |publication| {
        work_count += self.processPublication(publication);
    }
    work_count += self.processRetransmits();
    return work_count;
}
```

`doWork` returns the number of work items completed. Returning 0 signals to the outer busy-spin that the system is idle and the thread may yield. A non-zero return means "I did something — call me again immediately."

### Inside processPublication

```
sender_pos = counters.get(publication.sender_position)
pub_limit  = counters.get(publication.publisher_limit)

if sender_pos >= pub_limit → return 0   // nothing to send

if now_ms - last_setup_time_ms >= 50 → sendSetupFrame()

sendDataFrames(sender_pos, pub_limit)
```

The range `[sender_pos, pub_limit)` is the window of bytes that have been committed by the client but not yet placed on the wire. The Sender iterates that window in frame-aligned steps.

## DATA Frame Transmission

`sendDataFrames` reads raw bytes out of the active term buffer at the current offset, checks the `frame_length` field (a little-endian `i32` at offset 0), aligns it to `FRAME_ALIGNMENT` (32 bytes), and calls `send_channel.send`. The data is already in Aeron wire format — no serialization step is needed.

```
term_offset = sender_pos % term_length
frame_length = readInt(i32, term_buffer[term_offset..], .little)
aligned_len  = roundUp(frame_length, FRAME_ALIGNMENT)
send(dest_address, term_buffer[term_offset..term_offset+aligned_len])
sender_pos  += aligned_len
```

After all frames in the window are sent, the counter is updated atomically:

```zig
if (current_pos > sender_pos) {
    self.counters_map.set(publication.sender_position.counter_id, current_pos);
}
```

## SETUP Frames

A `SETUP` frame carries stream geometry — `session_id`, `stream_id`, `initial_term_id`, `term_length`, `mtu` — so that a receiver can allocate the correct log buffer before any `DATA` arrives. The Sender retransmits `SETUP` every 50 ms for the lifetime of the publication, ensuring late-joining subscribers can synchronise.

```zig
header.type          = @intFromEnum(protocol.FrameType.setup);
header.initial_term_id = publication.initial_term_id;
header.active_term_id  = current_term_id;
header.term_length     = publication.log_buffer.term_length;
header.mtu             = publication.mtu;
```

## The Retransmit Queue

When a receiver detects a gap, it sends a `NAK` frame. The `Receiver` agent decodes the `NAK` and calls `sender.onRetransmit(session_id, stream_id, term_id, term_offset, length)`, which appends a `RetransmitRequest` to the queue:

```zig
pub const RetransmitRequest = struct {
    session_id: i32,
    stream_id:  i32,
    term_id:    i32,
    term_offset: i32,
    length:     i32,
    timestamp_ms: i64,
};
```

`processRetransmits` drains this queue each duty cycle. It locates the matching publication, reads the requested bytes from the correct term buffer, and sends them. Stale entries (older than the retransmit timeout) are discarded without sending.

## Managing Publications

```zig
pub fn onAddPublication(self: *Sender, publication: *NetworkPublication) void
pub fn onRemovePublication(self: *Sender, session_id: i32, stream_id: i32) void
```

The `Conductor` calls these when clients register or deregister streams. `onRemovePublication` uses `swapRemove` — O(1) deletion that does not preserve order, acceptable because the list is iterated in full each cycle.

## The Busy-Spin Pattern in Zig

In standalone mode the Sender runs on its own OS thread:

```zig
fn senderThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        _ = md.sender_agent.doWork();
    }
}
```

This is a pure busy-spin: no sleep, no condition variable, no epoll. Aeron's design trades CPU for latency. On production deployments the thread is pinned to an isolated core with `pthread_setaffinity_np`. The `running` flag is a `std.atomic.Value(bool)`, ensuring the stop signal crosses the memory model boundary correctly.

## Function Reference

| Function | Purpose |
|---|---|
| `init` | Allocate `publications` and `retransmit_queue` ArrayLists |
| `deinit` | Free both lists |
| `doWork` | Outer duty cycle; returns work count |
| `processPublication` | Per-publication: check window, send SETUP, drain DATA |
| `sendSetupFrame` | Build and transmit a SETUP header |
| `sendDataFrames` | Walk term buffer window, transmit aligned frames |
| `processRetransmits` | Drain retransmit queue |
| `onAddPublication` | Append publication to active list |
| `onRemovePublication` | Remove publication by (session, stream) |
| `onRetransmit` | Enqueue a NAK-requested retransmit |
