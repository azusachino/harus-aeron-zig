# 5.4 Replayer

The Recorder captures live streams. The Replayer reads them back. To a subscriber, a replayed stream looks identical to a live stream — same fragmentation, same flow control, same publication semantics. The only difference is the data comes from disk instead of the network.

## What You'll Build

A ReplaySession that reads from a recorded segment file and publishes chunks to an Aeron Publication. A Replayer agent that manages multiple concurrent replay sessions and advances them via a duty cycle.

## Why It Works This Way (Aeron Concept)

Replaying a recording is just re-publishing the same bytes the archive captured. By feeding the recorded data into a standard Aeron Publication, you reuse all the infrastructure: fragmentation, retransmission (if configured), back-pressure, flow control. Subscribers to the replay stream don't know (or care) that the data is from disk rather than live.

This design also naturally throttles replay speed. If a Publication's back-buffer fills up, `offer()` returns a back-pressure code. The Replayer sees that and retries the chunk in the next duty cycle. Net result: replay speed never exceeds what subscribers can consume.

### Replay Flow

```
┌────────────────────────────┐
│ Recording File (disk)      │
│ bytes 0–N                  │
└────────┬───────────────────┘
         │
    ┌────┴────────┐
    │ ReplaySession
    │  (reads)
    └────┬────────┐
         │        │
   Buffer│        │ on back-pressure:
   Chunk │        │ retry next cycle
         │        │
    ┌────▼────────▼──┐
    │ Publication    │
    │ (offers data)  │
    └────┬───────────┘
         │
    ┌────▼───────────────────┐
    │ Subscribers see a      │
    │ normal Aeron stream    │
    └───────────────────────┘
```

## Zig Concept: File I/O and Retry Loops

Replaying is the inverse of recording. Instead of append-only writes, you read chunks in order and offer them to a Publication. Back-pressure means you need a retry loop.

### ReplaySession Structure

```zig
pub const ReplaySession = struct {
    allocator: std.mem.Allocator,
    recording_id: i64,
    replay_session_id: i64,
    publication: *Publication,      // Where replayed data goes
    file: std.fs.File,              // Recording segment file
    start_position: i64,            // Byte offset to start reading
    stop_position: i64,             // Byte offset to stop
    current_position: i64,          // Where we are in the file
    buffer: [8192]u8,              // Chunk buffer for reading

    /// Read next chunk and offer to publication.
    /// Returns true if done, false if still replaying.
    pub fn doWork(self: *ReplaySession) !bool {
        // If we've reached the end, stop
        if (self.current_position >= self.stop_position) {
            return true;  // EOS (End of Stream)
        }

        // Read next chunk
        const to_read = @min(self.buffer.len, self.stop_position - self.current_position);
        const bytes_read = try self.file.read(self.buffer[0..to_read]);
        if (bytes_read == 0) {
            return true;  // EOF
        }

        // Try to offer to publication
        const result = self.publication.offer(self.buffer[0..bytes_read]);
        switch (result) {
            .ok => {
                // Successfully published; advance position
                self.current_position += @as(i64, @intCast(bytes_read));
                return false;  // Still replaying (may have more chunks)
            },
            .back_pressure => {
                // Publication buffer full; retry next cycle
                return false;
            },
            .error => return error.PublicationError,
        }
    }
};
```

The key detail is the `switch` on the publication result:
- **`.ok`**: bytes were published, advance position.
- **`.back_pressure`**: the publication's buffer is full; leave position unchanged so we retry the same chunk next cycle.
- **`.error`**: something went wrong; propagate the error.

### Replayer Agent

```zig
pub const Replayer = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(ReplaySession),
    next_session_id: i64,

    /// Advance all active replay sessions by one poll cycle
    pub fn doWork(self: *Replayer) !i32 {
        var total_work: i32 = 0;
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const done = try self.sessions.items[i].doWork();
            total_work += 1;
            if (done) {
                // Replay finished; close and remove session
                self.sessions.items[i].file.close();
                self.allocator.free(self.sessions.items[i].buffer);
                _ = self.sessions.swapRemove(i);
            } else {
                i += 1;
            }
        }
        return total_work;
    }

    /// Start a new replay session
    pub fn startReplay(self: *Replayer, cmd: ReplayCmd, pub: *Publication) !i64 {
        const file = try std.fs.cwd().openFile(
            try segmentPath(cmd.recording_id),
            .{}
        );

        const session_id = self.next_session_id;
        self.next_session_id += 1;

        try self.sessions.append(self.allocator, ReplaySession{
            .recording_id = cmd.recording_id,
            .replay_session_id = session_id,
            .publication = pub,
            .file = file,
            .start_position = cmd.position,
            .stop_position = cmd.position + cmd.length,
            .current_position = cmd.position,
            .buffer = undefined,
        });

        return session_id;
    }

    /// Stop a replay session
    pub fn stopReplay(self: *Replayer, session_id: i64) !void {
        for (self.sessions.items, 0..) |session, i| {
            if (session.replay_session_id == session_id) {
                session.file.close();
                _ = self.sessions.swapRemove(i);
                return;
            }
        }
        return error.SessionNotFound;
    }
};
```

The back-pressure handling is implicit: if `offer()` returns `.back_pressure`, we simply don't advance `current_position`, so the next `doWork()` call retries the same chunk. No explicit retry queue needed.

## The Code

Open `src/archive/replayer.zig` and look at:

- `ReplaySession.doWork()` — read chunk, handle back-pressure
- `ReplaySession.isEos()` — check if we've reached `stop_position`
- `Replayer.doWork()` — iterate sessions, remove finished ones
- `Replayer.startReplay()` — allocate session, open file
- `Replayer.stopReplay()` — find session, close file, free resources

The essential pattern is:
1. Open the recording file (or segment files if it spans multiple segments).
2. Seek to `start_position`.
3. Read chunks and offer to publication until `current_position >= stop_position`.
4. If `offer()` succeeds, advance position.
5. If `offer()` returns back-pressure, retry next cycle.
6. When done, close the file and remove the session.

## Exercise

**Implement the back-pressure retry loop in `ReplaySession.doWork()`.**

Your task:
1. Read a chunk from the file (up to `buffer.len` bytes, but not past `stop_position`).
2. Call `publication.offer(chunk)`.
3. If result is `.ok`, advance `current_position` and return false (still replaying).
4. If result is `.back_pressure`, return false (retry next cycle, don't advance position).
5. If we've read all bytes (position >= stop_position), return true (done).

**Acceptance criteria:**
- Chunks are offered in order, without skipping bytes.
- Back-pressure is handled by not advancing position; the same chunk is retried.
- When all bytes have been offered successfully, return true (EOS).
- The session stops at exactly `stop_position`, not before or after.

**Hint:** Use `@min(buffer.len, stop_position - current_position)` to avoid reading past the end.

## Check Your Work

```bash
cd /Users/azusachino/Projects/project-github/harus-aeron-zig
make test-unit
```

Test scenario: write 1000 bytes to a recording, then replay it with a Publication that sometimes returns back-pressure. Verify all 1000 bytes are published in order.

## Key Takeaways

1. **Replay is re-publication**: recorded bytes go through the same Publication pipeline as live data.
2. **Back-pressure throttles replay**: if subscribers are slow, the Publication buffer fills and `offer()` returns back-pressure, naturally slowing replay.
3. **No copying**: read from file → offer to Publication → subscriber sees the bytes. Same chunks, moved once.
4. **Duty cycle pattern**: `doWork()` returns true when a session is done (EOS), allowing the Replayer to clean up and remove it.
5. **Segment handling**: if a recording spans multiple segment files, open each one in order and seek to the right offset within each.
