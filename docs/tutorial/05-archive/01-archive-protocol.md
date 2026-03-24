# Chapter 5.1: Archive Protocol

The Aeron Archive allows you to record Aeron streams to disk and replay them later. This chapter covers the control protocol used to communicate with the Archive.

## The Problem

Aeron's default behavior is "fire and forget" — data is transient in the log buffer. For many applications (like financial audit trails or state recovery), you need a persistent history of every message.

---

## Zig Track: Fixed-size `extern struct` Codecs

Archive control messages are complex, often containing many fields and variable-length strings. In Zig, we use `extern struct` to guarantee that our memory layout exactly matches the expected wire format.

### SBE-style Variable Length Strings

While the headers are fixed-size, many requests (like `StartRecording`) include a channel URI. We handle this by adding a `channel_length` field and then copying the string data immediately following the struct in the buffer.

```zig
// LESSON(archive/zig): Zig's @memcpy and @intCast make encoding variable-length SBE-style strings efficient and safe.
pub fn encodeChannel(buf: []u8, channel: []const u8) !usize {
    const channel_len: i32 = @intCast(channel.len);
    std.mem.writeInt(i32, buf[0..4], channel_len, .little);
    @memcpy(buf[4 .. 4 + channel.len], channel);
    return 4 + channel.len;
}
```

This pattern ensures that we don't need a heavy serialization library; we simply write bytes into the log buffer that other Aeron-compatible clients can read.

---

## Aeron Track: Control Streams

Unlike the Media Driver, which uses a raw shared-memory Ring Buffer for commands, the Archive is itself an Aeron client. You communicate with it using standard Aeron **Publications** and **Subscriptions**.

### Request/Response Pattern

The Archive protocol uses a classic asynchronous request/response model:

1. **Client** publishes a request (e.g., `StartRecordingRequest`) to the Archive's control channel.
2. **Archive** processes the request and publishes a `ControlResponse` or `RecordingStarted` notification on the client's response channel.
3. **Correlation IDs**: Every request includes a `correlation_id` so the client can match the asynchronous response back to the original request.

### Archive Message Families

| Family | MSG_TYPE_ID | Examples |
|--------|-------------|----------|
| Requests | 1–99 | `StartRecording`, `StopRecording`, `ListRecordings` |
| Responses | 100–199 | `ControlResponse`, `RecordingDescriptor` |

---

## Implementation Walkthrough

- **`src/archive/protocol.zig`**: Defines the `extern struct` layouts for all Archive messages.
- **`src/archive/conductor.zig`**: The Archive's brain — it polls the control stream and manages recording sessions.

## Exercise

1. Open `tutorial/archive/protocol.zig` and implement the `StartRecordingRequest` struct.
2. Implement the `encodeChannel` helper to correctly pack the length prefix and URI string.
3. Verify with `make tutorial-check`.

Further reading: [Aeron Archive Protocol](https://github.com/aeron-io/aeron/tree/master/aeron-archive)
