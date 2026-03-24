# 5.7 Archive Parity

## What you'll learn

- How the archive threads configuration down into recorder and replay components
- How recordings persist to disk and feed replay from recorded bytes
- How archive tests can validate the control path and the stored payload together

## Background

The archive starts to feel real once the recording path is no longer just an
in-memory scratch buffer. In this chapter, the recorder writes each recording to
`archive/<recording_id>.dat`, and replay reads those recorded bytes back through
the conductor.

That gives the archive a stable source of truth for replay and a better match
for the upstream Aeron archive service, even though the control surface is still
intentionally smaller than the Java implementation.

## Key changes

| Area | Behavior |
|------|----------|
| `ArchiveConductor` | Carries the archive directory into recorder initialization |
| `RecordingWriter` | Writes fragments to disk and can read them back for replay |
| `RecordingSession` | Owns recording state and can snapshot persisted bytes |
| `Replayer` | Owns replay session data instead of borrowing from the recorder |

## Exercise

Open `src/archive/` and trace one recording end to end:

1. Start a recording through the conductor
2. Write one or more fragments to the active recording session
3. Stop the recording
4. Start a replay and verify the replay session sees the stored payload

Run `make check` to verify the implementation.

## Reference

- `src/archive/archive.zig`
- `src/archive/conductor.zig`
- `src/archive/recorder.zig`
- `src/archive/replayer.zig`
