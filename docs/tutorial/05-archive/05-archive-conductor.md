# 5.5 Archive Conductor

## What you'll learn

- How the archive conductor routes control commands to Recorder and Replayer
- The command queue / response queue pattern
- Correlation ID tracking for request/response matching

## Background

The `ArchiveConductor` is the central command processor for the archive.
It subscribes to the archive control channel, decodes incoming commands,
and routes them to the appropriate handler (Recorder or Replayer).

Responses are sent back via a per-request reply channel, matched by
`correlation_id`. This is the same pattern used by the media driver's
`DriverConductor`, but for archive-specific operations.

## Command flow

```
Client                    ArchiveConductor              Recorder/Replayer
  |                              |                              |
  |--- StartRecordingRequest --->|                              |
  |                              |--- onStartRecording() ------>|
  |                              |<-- RecordingStarted ---------|
  |<--- ControlResponse(ok) ----|                              |
```

## Exercise

Open `tutorial/archive/conductor.zig` and implement the command routing loop.

Run `make tutorial-check` to verify.

## Reference

- `src/archive/conductor.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/ArchiveConductor.java`
