# 5.6 Archive Main

## What you'll learn

- How to compose Conductor + Recorder + Replayer into a top-level Archive
- Configuration via `ArchiveContext`
- The standalone archive binary

## Background

The `Archive` struct is the top-level owner of all archive components.
It holds the `ArchiveConductor` and drives its duty cycle via `doWork()`.

`ArchiveContext` provides all configuration: control channel, recording
events channel, archive directory path, and segment file length.

## Configuration defaults

| Field | Default | Purpose |
|-------|---------|---------|
| `control_channel` | `aeron:udp?endpoint=localhost:8010` | Client command channel |
| `control_stream_id` | 10 | Stream for control messages |
| `archive_dir` | `/tmp/aeron-archive` | Recording storage path |
| `segment_file_length` | 128 MB | Max segment file size |

## Exercise

Open `tutorial/archive/archive.zig` and implement:

1. `ArchiveContext` with sensible defaults
2. `Archive` struct with init/deinit/start/stop/doWork
3. End-to-end test: start recording → write data → replay → verify

Run `make tutorial-check` to verify.

## Reference

- `src/archive/archive.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/Archive.java`
