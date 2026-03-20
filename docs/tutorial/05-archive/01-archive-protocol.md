# 5.1 Archive Protocol

## What you'll learn

- How archive control commands are encoded as fixed-size `extern struct` messages
- The request/response pattern: clients send commands, archive replies with correlation IDs
- Variable-length channel encoding with length-prefixed strings

## Background

Aeron Archive adds persistent recording and replay on top of the media driver.
The archive runs as a separate process (or embedded) and communicates with clients
via dedicated Aeron streams — not raw UDP, but Aeron publications/subscriptions.

The control protocol defines two message families:

| Direction | Examples | MSG_TYPE_ID range |
|-----------|----------|-------------------|
| Client → Archive | StartRecording, StopRecording, Replay, ListRecordings | 1–99 |
| Archive → Client | ControlResponse, RecordingStarted, RecordingProgress, RecordingDescriptor | 100–199 |

Real Aeron uses SBE (Simple Binary Encoding) for these. We use `extern struct`
with the same field layout — simpler, equally wire-compatible for our purposes.

## Key types

| Struct | Size | Purpose |
|--------|------|---------|
| `StartRecordingRequest` | 24 bytes | Begin recording a channel/stream |
| `StopRecordingRequest` | 16 bytes | Stop an active recording |
| `ReplayRequest` | 40 bytes | Replay a recording to a channel |
| `ControlResponse` | 16 bytes | Generic ok/error response |
| `RecordingDescriptor` | 72 bytes | Full metadata for a recording |

## Exercise

Open `tutorial/archive/protocol.zig` and implement:

1. All request structs with correct field layouts and `MSG_TYPE_ID` constants
2. All response structs
3. `encodeChannel` / `decodeChannel` helpers
4. Comptime size assertions

Run `make tutorial-check` to verify.

## Reference

- `src/archive/protocol.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/codecs/` — upstream Java SBE codecs
