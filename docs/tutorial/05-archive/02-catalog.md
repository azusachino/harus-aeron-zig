# 5.2 Recording Catalog

## What you'll learn

- How recordings are tracked in a persistent flat-file catalog
- Fixed-size record layout for O(1) lookup by recording ID
- Atomic updates for stop position and timestamp

## Background

Every recording gets a `RecordingDescriptor` entry in `archive/catalog.dat`.
The catalog is a flat binary file with fixed-size records (1024 bytes each).
Recording IDs are sequential — the Nth record lives at offset `N * 1024`.

This design gives O(1) lookup by ID and sequential scan for listing.
The catalog is mmap'd for reads, written sequentially for new entries.

## Key operations

| Method | What it does |
|--------|-------------|
| `addNewRecording(...)` | Append a new descriptor, return recording_id |
| `updateStopPosition(id, pos)` | Atomic update of stop position |
| `recordingDescriptor(id)` | O(1) lookup by recording ID |
| `listRecordings(from, count, handler)` | Sequential scan with callback |
| `findLastMatchingRecording(...)` | Reverse scan by channel + stream |

## Exercise

Open `tutorial/archive/catalog.zig` and implement the `Catalog` struct.

Run `make tutorial-check` to verify.

## Reference

- `src/archive/catalog.zig` — reference implementation
- `aeron-archive/src/main/java/io/aeron/archive/Catalog.java`
