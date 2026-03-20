# 5.3 Recorder

## What you'll learn

- How recording sessions subscribe to live Aeron streams and write to disk
- Term-boundary flushing and segment file rotation
- The Recorder duty agent pattern

## Background

When a client sends `StartRecordingRequest`, the archive creates a
`RecordingSession` that subscribes to the specified channel/stream.
Incoming fragments are written sequentially to recording files:
`archive/<recording_id>.dat`.

The `Recorder` is a duty agent — its `doWork()` polls active recording
sessions, each of which calls `sub.poll(handler, limit)` to consume
fragments and write them to disk.

## Key types

| Type | Role |
|------|------|
| `RecordingWriter` | Writes raw log buffer segments to file |
| `RecordingSession` | Owns a subscription + writer for one recording |
| `Recorder` | Duty agent managing all active sessions |

## Exercise

Open `tutorial/archive/recorder.zig` and implement:

1. `RecordingWriter` with sequential write and flush
2. `RecordingSession` with subscription polling
3. `Recorder` duty agent with start/stop session management

Run `make tutorial-check` to verify.

## Reference

- `src/archive/recorder.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/RecordingSession.java`
