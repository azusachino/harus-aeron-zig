# 5.4 Replayer

## What you'll learn

- How replay sessions read recording files and republish as live streams
- Position tracking and EOS detection
- The Replayer duty agent pattern

## Background

When a client sends `ReplayRequest`, the archive creates a `ReplaySession`
that reads from the recording file at `start_position` and publishes frames
on `replay_channel:replay_stream_id`. The subscriber sees it as a normal
Aeron stream.

Replay speed is "as fast as possible" by default — the publication's
back-pressure mechanism naturally throttles delivery.

## Key operations

| Method | What it does |
|--------|-------------|
| `ReplaySession.doWork()` | Read next chunk from file, offer to publication |
| `Replayer.onReplayRequest(req)` | Create new ReplaySession |
| `Replayer.onStopReplay(req)` | Close session by replay_session_id |
| `Replayer.doWork()` | Advance all active replay sessions |

## Exercise

Open `tutorial/archive/replayer.zig` and implement the ReplaySession and Replayer.

Run `make tutorial-check` to verify.

## Reference

- `src/archive/replayer.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/ReplaySession.java`
