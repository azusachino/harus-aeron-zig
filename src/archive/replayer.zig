/// Aeron Archive Replayer — manages replay sessions that read from recorded data.
/// A ReplaySession wraps a reference to recorded data and tracks playback progress.
/// The Replayer agent multiplexes multiple concurrent replay sessions, advancing
/// them all on each call to doWork().
///
/// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/Replayer.java
const std = @import("std");

/// RecordingProgressInfo — plain Zig struct holding replay progress for a session.
/// Not a wire type; used internally to report current playback state.
pub const RecordingProgressInfo = struct {
    /// The recording being replayed.
    recording_id: i64,
    /// The position where replay began (from the ReplayRequest).
    start_position: i64,
    /// Current playback position within the recording.
    current_position: i64,
};

/// ReplaySession — represents a single active replay of a recording.
/// Tracks where we are in the recorded data and offers a window to advance through it.
/// Each session has a unique replay_session_id that clients use to stop/query it.
pub const ReplaySession = struct {
    /// Unique identifier for this replay session, used by client to reference it.
    replay_session_id: i64,
    /// Recording being replayed (for progress reporting and validation).
    recording_id: i64,
    /// Current read position within the source_data buffer.
    current_position: i64,
    /// Position at which to stop replay; 0 means replay to end of data.
    /// When current_position >= replay_limit and replay_limit != 0, session is complete.
    replay_limit: i64,
    /// Reference to the recorded data buffer (caller retains ownership).
    /// This is immutable and must remain valid for the lifetime of this session.
    source_data: []const u8,
    /// Whether this session is actively replaying (not closed by client).
    active: bool,
    /// Initial position where replay started (for progress tracking).
    start_position: i64,

    /// Initialize a new ReplaySession.
    /// `position` is the byte offset in the recording to begin replay from.
    /// `length` is the maximum bytes to replay; 0 means replay all remaining data.
    pub fn init(
        replay_session_id: i64,
        recording_id: i64,
        position: i64,
        length: i64,
        source_data: []const u8,
    ) ReplaySession {
        return ReplaySession{
            .replay_session_id = replay_session_id,
            .recording_id = recording_id,
            .current_position = position,
            .replay_limit = if (length == 0) @intCast(source_data.len) else position + length,
            .source_data = source_data,
            .active = true,
            .start_position = position,
        };
    }

    /// Read the next chunk of data from current position in the recording.
    /// Advances current_position by chunk size on each call.
    /// Returns a slice to the next chunk of recorded data, or null if at end.
    /// Chunk size is adaptive: returns up to `max_length` bytes, or less if near end.
    pub fn readChunk(self: *ReplaySession, max_length: usize) ?[]const u8 {
        if (!self.active or self.isComplete()) {
            return null;
        }

        const source_len = @as(i64, @intCast(self.source_data.len));
        const effective_limit = if (self.replay_limit > 0)
            @min(self.replay_limit, source_len)
        else
            source_len;

        const start_position = if (self.current_position < 0) 0 else @min(self.current_position, effective_limit);
        if (start_position >= effective_limit) {
            return null;
        }

        const bytes_available = effective_limit - start_position;

        if (bytes_available <= 0) {
            return null;
        }

        const chunk_size = @min(
            @as(usize, @intCast(bytes_available)),
            max_length,
        );

        if (chunk_size == 0) {
            return null;
        }

        const start = @as(usize, @intCast(start_position));
        const chunk = self.source_data[start .. start + chunk_size];
        self.current_position += @as(i64, @intCast(chunk_size));

        return chunk;
    }

    /// Perform one unit of replay work.
    /// In a real system, this would send a frame to the replay channel.
    /// For now, it advances by a nominal chunk and returns 1 if there was work,
    /// or 0 if the session is inactive or complete.
    pub fn doWork(self: *ReplaySession) i32 {
        if (!self.active or self.isComplete()) {
            return 0;
        }

        // Nominal chunk size for testing and basic operation.
        const nominal_chunk = 1024;
        _ = self.readChunk(nominal_chunk);
        return 1;
    }

    /// Close this replay session and mark it inactive.
    /// After this, further reads and work will return nothing.
    pub fn close(self: *ReplaySession) void {
        self.active = false;
    }

    /// Check if this session is currently active (not closed by client).
    pub fn isActive(self: *const ReplaySession) bool {
        return self.active;
    }

    /// Check if replay is complete.
    /// Complete when:
    ///   - current_position >= replay_limit (if limit is set), OR
    ///   - current_position >= source_data.len (if no limit)
    pub fn isComplete(self: *const ReplaySession) bool {
        const source_len = @as(i64, @intCast(self.source_data.len));
        const effective_limit = if (self.replay_limit > 0)
            @min(self.replay_limit, source_len)
        else
            source_len;
        return self.current_position >= effective_limit;
    }

    /// Get current replay progress as a RecordingProgressInfo struct.
    /// Includes recording_id, start position, and current position.
    pub fn progress(self: *const ReplaySession) RecordingProgressInfo {
        return RecordingProgressInfo{
            .recording_id = self.recording_id,
            .start_position = self.start_position,
            .current_position = self.current_position,
        };
    }
};

/// Replayer — duty agent responsible for managing all active replay sessions.
/// Maintains a list of ReplaySession instances and orchestrates their advancement.
/// Sessions are created on ReplayRequest and destroyed on StopReplayRequest or completion.
pub const Replayer = struct {
    /// List of active replay sessions (may include completed sessions until removed).
    sessions: std.ArrayList(ReplaySession),
    /// Monotonically increasing counter for next session ID.
    /// Ensures each session gets a unique replay_session_id.
    next_replay_session_id: i64,
    /// Allocator for managing the sessions list.
    allocator: std.mem.Allocator,

    /// Initialize a new Replayer agent.
    pub fn init(allocator: std.mem.Allocator) Replayer {
        return Replayer{
            .allocator = allocator,
            .sessions = .{},
            .next_replay_session_id = 1,
        };
    }

    /// Free all resources associated with the Replayer.
    /// Must be called before dropping the Replayer instance.
    pub fn deinit(self: *Replayer) void {
        self.sessions.deinit(self.allocator);
    }

    /// Handle an incoming ReplayRequest: create a new ReplaySession and return its ID.
    /// `source_data` is a reference to the recorded data buffer.
    /// Returns the unique replay_session_id that identifies this session.
    /// This ID is used in StopReplayRequest messages from the client.
    pub fn onReplayRequest(
        self: *Replayer,
        recording_id: i64,
        position: i64,
        length: i64,
        source_data: []const u8,
    ) !i64 {
        const session_id = self.next_replay_session_id;
        self.next_replay_session_id += 1;

        const session = ReplaySession.init(session_id, recording_id, position, length, source_data);
        try self.sessions.append(self.allocator, session);

        return session_id;
    }

    /// Handle a StopReplayRequest: close the session with the given ID.
    /// If the session doesn't exist, this is a no-op.
    pub fn onStopReplay(self: *Replayer, replay_session_id: i64) void {
        if (self.findSession(replay_session_id)) |session| {
            session.close();
        }
    }

    /// Advance all active replay sessions by one unit of work each.
    /// Returns the sum of work counts from all sessions.
    /// In a live system, this orchestrates sending frames to clients.
    pub fn doWork(self: *Replayer) i32 {
        var total_work: i32 = 0;
        for (self.sessions.items) |*session| {
            total_work += session.doWork();
        }
        return total_work;
    }

    /// Count the number of currently active (non-closed) replay sessions.
    pub fn activeSessions(self: *const Replayer) usize {
        var count: usize = 0;
        for (self.sessions.items) |session| {
            if (session.isActive()) {
                count += 1;
            }
        }
        return count;
    }

    /// Find a ReplaySession by replay_session_id.
    /// Returns a pointer to the session if found, null otherwise.
    pub fn findSession(self: *Replayer, replay_session_id: i64) ?*ReplaySession {
        for (self.sessions.items) |*session| {
            if (session.replay_session_id == replay_session_id) {
                return session;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ReplaySession reads chunks sequentially" {
    const data = "Hello, World! This is test data.";
    var session = ReplaySession.init(1, 1, 0, 0, data);

    // Read first chunk
    const chunk1 = session.readChunk(5);
    try std.testing.expect(chunk1 != null);
    try std.testing.expectEqualSlices(u8, "Hello", chunk1.?);
    try std.testing.expectEqual(@as(i64, 5), session.current_position);

    // Read second chunk
    const chunk2 = session.readChunk(7);
    try std.testing.expect(chunk2 != null);
    try std.testing.expectEqualSlices(u8, ", World", chunk2.?);
    try std.testing.expectEqual(@as(i64, 12), session.current_position);

    // Read final chunk
    const chunk3 = session.readChunk(100);
    try std.testing.expect(chunk3 != null);
    try std.testing.expectEqualSlices(u8, "! This is test data.", chunk3.?);
}

test "ReplaySession respects replay_limit" {
    const data = "0123456789ABCDEFGHIJ";
    var session = ReplaySession.init(1, 1, 0, 10, data);

    const chunk1 = session.readChunk(20);
    try std.testing.expect(chunk1 != null);
    try std.testing.expectEqual(@as(usize, 10), chunk1.?.len);
    try std.testing.expectEqualSlices(u8, "0123456789", chunk1.?);

    // No more data available (hit limit)
    const chunk2 = session.readChunk(5);
    try std.testing.expect(chunk2 == null);
}

test "ReplaySession detects completion" {
    const data = "short";
    var session = ReplaySession.init(1, 1, 0, 0, data);

    try std.testing.expect(!session.isComplete());
    _ = session.readChunk(100);
    try std.testing.expect(session.isComplete());
}

test "ReplaySession close marks inactive" {
    const data = "test data";
    var session = ReplaySession.init(1, 1, 0, 0, data);

    try std.testing.expect(session.isActive());
    session.close();
    try std.testing.expect(!session.isActive());

    // Further reads should return null
    const chunk = session.readChunk(100);
    try std.testing.expect(chunk == null);
}

test "ReplaySession doWork returns 1 when active" {
    const data = "data";
    var session = ReplaySession.init(1, 1, 0, 0, data);

    const work = session.doWork();
    try std.testing.expectEqual(@as(i32, 1), work);
}

test "ReplaySession doWork returns 0 when inactive" {
    const data = "data";
    var session = ReplaySession.init(1, 1, 0, 0, data);
    session.close();

    const work = session.doWork();
    try std.testing.expectEqual(@as(i32, 0), work);
}

test "ReplaySession progress tracking" {
    const data = "0123456789";
    var session = ReplaySession.init(1, 42, 2, 0, data);

    var prog = session.progress();
    try std.testing.expectEqual(@as(i64, 42), prog.recording_id);
    try std.testing.expectEqual(@as(i64, 2), prog.start_position);
    try std.testing.expectEqual(@as(i64, 2), prog.current_position);

    _ = session.readChunk(3);
    prog = session.progress();
    try std.testing.expectEqual(@as(i64, 5), prog.current_position);
}

test "Replayer onReplayRequest creates session with unique ID" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const data1 = "data1";
    const session_id1 = try replayer.onReplayRequest(1, 0, 0, data1);
    try std.testing.expectEqual(@as(i64, 1), session_id1);

    const data2 = "data2";
    const session_id2 = try replayer.onReplayRequest(2, 0, 0, data2);
    try std.testing.expectEqual(@as(i64, 2), session_id2);

    try std.testing.expectEqual(@as(usize, 2), replayer.sessions.items.len);
}

test "Replayer onStopReplay closes correct session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const data = "test data";
    const session_id = try replayer.onReplayRequest(1, 0, 0, data);

    try std.testing.expect(replayer.findSession(session_id) != null);
    try std.testing.expect(replayer.findSession(session_id).?.isActive());

    replayer.onStopReplay(session_id);

    try std.testing.expect(replayer.findSession(session_id) != null);
    try std.testing.expect(!replayer.findSession(session_id).?.isActive());
}

test "Replayer doWork advances all active sessions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const data1 = "data1";
    _ = try replayer.onReplayRequest(1, 0, 0, data1);

    const data2 = "data2";
    _ = try replayer.onReplayRequest(2, 0, 0, data2);

    const work = replayer.doWork();
    try std.testing.expectEqual(@as(i32, 2), work);
}

test "Replayer doWork returns 0 when no active sessions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const work = replayer.doWork();
    try std.testing.expectEqual(@as(i32, 0), work);
}

test "Replayer findSession returns correct session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const data1 = "data1";
    const session_id1 = try replayer.onReplayRequest(1, 0, 0, data1);

    const data2 = "data2";
    const session_id2 = try replayer.onReplayRequest(2, 0, 0, data2);

    const found1 = replayer.findSession(session_id1);
    try std.testing.expect(found1 != null);
    try std.testing.expectEqual(session_id1, found1.?.replay_session_id);

    const found2 = replayer.findSession(session_id2);
    try std.testing.expect(found2 != null);
    try std.testing.expectEqual(session_id2, found2.?.replay_session_id);

    const not_found = replayer.findSession(999);
    try std.testing.expect(not_found == null);
}

test "Replayer activeSessions counts correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    try std.testing.expectEqual(@as(usize, 0), replayer.activeSessions());

    const data1 = "data1";
    const session_id1 = try replayer.onReplayRequest(1, 0, 0, data1);
    try std.testing.expectEqual(@as(usize, 1), replayer.activeSessions());

    const data2 = "data2";
    _ = try replayer.onReplayRequest(2, 0, 0, data2);
    try std.testing.expectEqual(@as(usize, 2), replayer.activeSessions());

    replayer.onStopReplay(session_id1);
    try std.testing.expectEqual(@as(usize, 1), replayer.activeSessions());
}

test "Replayer handles multiple sessions reaching completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var replayer = Replayer.init(allocator);
    defer replayer.deinit();

    const data = "ab";
    const sid1 = try replayer.onReplayRequest(1, 0, 0, data);
    const sid2 = try replayer.onReplayRequest(2, 0, 0, data);

    // Each session has 2 bytes of data, so doWork() twice should complete both
    var total_work: i32 = 0;
    for (0..3) |_| {
        total_work += replayer.doWork();
    }

    try std.testing.expect(replayer.findSession(sid1).?.isComplete());
    try std.testing.expect(replayer.findSession(sid2).?.isComplete());
    // After completion, doWork should return 0
    try std.testing.expectEqual(@as(i32, 0), replayer.doWork());
}
