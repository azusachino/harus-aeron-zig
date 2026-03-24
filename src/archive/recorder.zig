// Aeron Archive Recorder — manages active recording sessions
// Writes incoming media frames to on-disk recordings and catalogs metadata
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/Archive.java

const std = @import("std");
const catalog_mod = @import("catalog.zig");
const protocol = @import("protocol.zig");

/// RecordingWriter — buffers raw frame data for a single recording and mirrors it to disk.
pub const RecordingWriter = struct {
    allocator: std.mem.Allocator,
    recording_id: i64,
    archive_dir: []const u8,
    path: []u8,
    file: ?std.fs.File,
    /// Position of first byte in this recording (from media context)
    start_position: i64,
    /// Current write position (start_position + bytes_written)
    stop_position: i64,
    /// In-memory buffer for raw frame data
    buffer: std.ArrayList(u8),

    /// Initialize a new recording writer.
    /// allocator: memory allocator for the buffer
    /// recording_id: unique identifier for this recording
    /// start_position: position of first frame in media context (usually 0 or from media state)
    /// archive_dir: directory that stores recording segments
    pub fn init(
        allocator: std.mem.Allocator,
        recording_id: i64,
        start_position: i64,
    ) !RecordingWriter {
        return RecordingWriter.initWithArchiveDir(allocator, recording_id, start_position, "/tmp/aeron-archive");
    }

    pub fn initWithArchiveDir(
        allocator: std.mem.Allocator,
        recording_id: i64,
        start_position: i64,
        archive_dir: []const u8,
    ) !RecordingWriter {
        try std.fs.cwd().makePath(archive_dir);

        const path = try std.fmt.allocPrint(allocator, "{s}/{d}.dat", .{ archive_dir, recording_id });
        errdefer allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });

        return RecordingWriter{
            .allocator = allocator,
            .recording_id = recording_id,
            .archive_dir = archive_dir,
            .path = path,
            .file = file,
            .start_position = start_position,
            .stop_position = start_position,
            .buffer = .{},
        };
    }

    /// Free recording writer resources.
    pub fn deinit(self: *RecordingWriter) void {
        if (self.file) |file| file.close();
        self.allocator.free(self.path);
        self.buffer.deinit(self.allocator);
    }

    /// Write raw frame data to the buffer and advance stop_position.
    /// data: frame bytes to append (frame header + payload)
    pub fn write(self: *RecordingWriter, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
        if (self.file) |*file| {
            try file.writeAll(data);
        }
        self.stop_position += @as(i64, @intCast(data.len));
    }

    /// Read the full recording payload back from disk.
    pub fn readAll(self: *RecordingWriter, allocator: std.mem.Allocator) ![]u8 {
        const file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();

        return file.readToEndAlloc(allocator, 1024 * 1024);
    }

    /// Return the recording's start position.
    pub fn startPosition(self: *const RecordingWriter) i64 {
        return self.start_position;
    }

    /// Return the recording's current stop position (start + bytes written).
    pub fn stopPosition(self: *const RecordingWriter) i64 {
        return self.stop_position;
    }

    /// Return total bytes written to this recording's buffer.
    pub fn bytesWritten(self: *const RecordingWriter) usize {
        return self.buffer.items.len;
    }

    /// Flush buffered data to disk.
    pub fn flush(self: *RecordingWriter) !void {
        if (self.file) |*file| {
            try file.sync();
        }
    }
};

/// RecordingSession — ties a recording ID to active session metadata.
/// Receives fragments (frames) and forwards them to the RecordingWriter.
pub const RecordingSession = struct {
    allocator: std.mem.Allocator,
    /// Unique recording identifier assigned by catalog
    recording_id: i64,
    /// Session ID from media context (identifies subscription source)
    session_id: i32,
    /// Stream ID being recorded (identifies channel)
    stream_id: i32,
    /// Channel URI string (allocated copy)
    channel: []const u8,
    /// True if recording is currently active
    active: bool,
    /// Underlying writer that buffers frame data
    writer: RecordingWriter,

    /// Initialize a new recording session.
    /// allocator: memory allocator
    /// recording_id: unique recording identifier
    /// session_id: media session ID for matching incoming frames
    /// stream_id: media stream ID for matching
    /// channel: channel URI (will be copied)
    /// start_position: initial position in media context
    pub fn init(
        allocator: std.mem.Allocator,
        recording_id: i64,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        start_position: i64,
    ) !RecordingSession {
        return RecordingSession.initWithArchiveDir(allocator, recording_id, session_id, stream_id, channel, start_position, "/tmp/aeron-archive");
    }

    pub fn initWithArchiveDir(
        allocator: std.mem.Allocator,
        recording_id: i64,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        start_position: i64,
        archive_dir: []const u8,
    ) !RecordingSession {
        return RecordingSession{
            .allocator = allocator,
            .recording_id = recording_id,
            .session_id = session_id,
            .stream_id = stream_id,
            .channel = try allocator.dupe(u8, channel),
            .active = true,
            .writer = try RecordingWriter.initWithArchiveDir(allocator, recording_id, start_position, archive_dir),
        };
    }

    /// Free session resources (channel string and writer buffer).
    pub fn deinit(self: *RecordingSession) void {
        self.allocator.free(self.channel);
        self.writer.deinit();
    }

    /// Write a media frame fragment to the recording.
    /// data: raw frame bytes (header + payload)
    pub fn onFragment(self: *RecordingSession, data: []const u8) !void {
        if (self.active) {
            try self.writer.write(data);
        }
    }

    /// Read back the persisted recording payload for replay.
    pub fn snapshot(self: *RecordingSession, allocator: std.mem.Allocator) ![]u8 {
        return self.writer.readAll(allocator);
    }

    /// Mark this session as inactive and close it.
    pub fn close(self: *RecordingSession) void {
        self.active = false;
    }

    /// Check if this session is currently recording.
    pub fn isActive(self: *const RecordingSession) bool {
        return self.active;
    }
};

/// Recorder — duty agent managing all active recording sessions.
/// - Creates new sessions when StartRecordingRequest arrives
/// - Stops sessions when StopRecordingRequest arrives
/// - Catalogs all recordings
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    archive_dir: []const u8,
    /// Active recording sessions
    sessions: std.ArrayList(RecordingSession),
    /// Shared catalog for metadata persistence
    catalog: *catalog_mod.Catalog,

    /// Initialize the recorder duty agent.
    /// allocator: memory allocator for session list
    /// cat: reference to the shared catalog (not owned)
    pub fn init(
        allocator: std.mem.Allocator,
        cat: *catalog_mod.Catalog,
    ) Recorder {
        return Recorder.initWithArchiveDir(allocator, cat, "/tmp/aeron-archive");
    }

    pub fn initWithArchiveDir(
        allocator: std.mem.Allocator,
        cat: *catalog_mod.Catalog,
        archive_dir: []const u8,
    ) Recorder {
        return Recorder{
            .allocator = allocator,
            .archive_dir = archive_dir,
            .sessions = .{},
            .catalog = cat,
        };
    }

    /// Free recorder resources (sessions and session list).
    pub fn deinit(self: *Recorder) void {
        for (self.sessions.items) |*session| {
            session.deinit();
        }
        self.sessions.deinit(self.allocator);
    }

    /// Start a new recording.
    /// Creates a RecordingSession, adds entry to catalog, and returns recording_id.
    /// session_id: media session ID to match
    /// stream_id: media stream ID to match
    /// channel: channel URI string
    /// source_identity: identifier of the recording source
    /// start_position: initial position in media context
    /// start_timestamp: wall-clock time when recording started
    pub fn onStartRecording(
        self: *Recorder,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        source_identity: []const u8,
        start_position: i64,
        start_timestamp: i64,
    ) !i64 {
        // Allocate catalog entry (next_recording_id is auto-incremented)
        const recording_id = try self.catalog.addNewRecording(
            session_id,
            stream_id,
            channel,
            source_identity,
            0, // initial_term_id (TODO: capture from media)
            0, // segment_file_length (TODO: configurable)
            0, // term_buffer_length (TODO: from media)
            0, // mtu_length (TODO: from media)
            start_position,
            start_timestamp,
        );

        // Create and store the session
        const session = try RecordingSession.initWithArchiveDir(
            self.allocator,
            recording_id,
            session_id,
            stream_id,
            channel,
            start_position,
            self.archive_dir,
        );
        try self.sessions.append(self.allocator, session);

        return recording_id;
    }

    /// Stop an active recording.
    /// Closes the session and updates catalog with final position and timestamp.
    /// recording_id: ID of recording to stop
    /// stop_timestamp: wall-clock time when recording stopped
    pub fn onStopRecording(self: *Recorder, recording_id: i64, stop_timestamp: i64) void {
        // Find and close the matching session
        for (self.sessions.items) |*session| {
            if (session.recording_id == recording_id) {
                session.close();
                // Update catalog with final state
                self.catalog.updateStopPosition(recording_id, session.writer.stopPosition());
                self.catalog.updateStopTimestamp(recording_id, stop_timestamp);
                return;
            }
        }
    }

    /// Poll all active sessions and return count of active recordings.
    /// Currently placeholder for real poll logic (reading from media).
    pub fn doWork(self: *const Recorder) i32 {
        var count: i32 = 0;
        for (self.sessions.items) |session| {
            if (session.isActive()) {
                count += 1;
            }
        }
        return count;
    }

    /// Return count of currently active recording sessions.
    pub fn activeSessions(self: *const Recorder) usize {
        var count: usize = 0;
        for (self.sessions.items) |session| {
            if (session.isActive()) {
                count += 1;
            }
        }
        return count;
    }

    /// Find a recording session by recording ID.
    /// Returns pointer to session or null if not found.
    pub fn findSession(self: *Recorder, recording_id: i64) ?*RecordingSession {
        for (self.sessions.items) |*session| {
            if (session.recording_id == recording_id) {
                return session;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RecordingWriter tracks positions correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try RecordingWriter.init(allocator, 1, 1000);
    defer writer.deinit();

    try std.testing.expectEqual(1000, writer.startPosition());
    try std.testing.expectEqual(1000, writer.stopPosition());
    try std.testing.expectEqual(0, writer.bytesWritten());

    try writer.write("hello");
    try std.testing.expectEqual(1000, writer.startPosition());
    try std.testing.expectEqual(1005, writer.stopPosition());
    try std.testing.expectEqual(5, writer.bytesWritten());

    try writer.write(" world");
    try std.testing.expectEqual(1011, writer.stopPosition());
    try std.testing.expectEqual(11, writer.bytesWritten());
}

test "RecordingSession writes fragments and tracks state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var session = try RecordingSession.init(allocator, 1, 100, 200, "aeron:udp://localhost:40123", 0);
    defer session.deinit();

    try std.testing.expect(session.isActive());
    try std.testing.expectEqual(1, session.recording_id);
    try std.testing.expectEqual(100, session.session_id);
    try std.testing.expectEqual(200, session.stream_id);

    try session.onFragment("frame1");
    try std.testing.expectEqual(6, session.writer.bytesWritten());

    try session.onFragment("frame2");
    try std.testing.expectEqual(12, session.writer.bytesWritten());

    session.close();
    try std.testing.expect(!session.isActive());
    // After close, onFragment should not write (but no error)
    try session.onFragment("frame3");
    try std.testing.expectEqual(12, session.writer.bytesWritten());
}

test "Recorder onStartRecording creates session and catalog entry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const recording_id = try recorder.onStartRecording(
        123,
        456,
        "aeron:udp://localhost:40123",
        "test-source",
        0,
        1000,
    );

    try std.testing.expectEqual(1, recording_id);
    try std.testing.expectEqual(1, recorder.activeSessions());

    const session = recorder.findSession(recording_id);
    try std.testing.expect(session != null);
    try std.testing.expectEqual(123, session.?.session_id);
    try std.testing.expectEqual(456, session.?.stream_id);

    const cat_entry = catalog.recordingDescriptor(recording_id);
    try std.testing.expect(cat_entry != null);
    try std.testing.expectEqual(123, cat_entry.?.session_id);
    try std.testing.expectEqual(456, cat_entry.?.stream_id);
    try std.testing.expectEqual(1000, cat_entry.?.start_timestamp);
}

test "RecordingWriter persists payload to disk" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try RecordingWriter.init(allocator, 7, 0);
    defer writer.deinit();

    try writer.write("abc");
    try writer.write("def");
    try writer.flush();

    const contents = try writer.readAll(allocator);
    defer allocator.free(contents);

    try std.testing.expectEqualSlices(u8, "abcdef", contents);
}

test "Recorder onStopRecording closes session and updates catalog" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const recording_id = try recorder.onStartRecording(
        111,
        222,
        "ch1",
        "src1",
        100,
        5000,
    );

    // Write some data
    var session = recorder.findSession(recording_id).?;
    try session.onFragment("data1");
    try session.onFragment("data2");

    // Stop recording
    recorder.onStopRecording(recording_id, 6000);

    try std.testing.expect(!session.isActive());

    const cat_entry = catalog.recordingDescriptor(recording_id).?;
    try std.testing.expectEqual(6000, cat_entry.stop_timestamp);
    try std.testing.expectEqual(110, cat_entry.stop_position); // 100 + 10 bytes written
}

test "Recorder doWork returns active session count" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    try std.testing.expectEqual(0, recorder.doWork());

    _ = try recorder.onStartRecording(1, 1, "ch1", "src1", 0, 100);
    try std.testing.expectEqual(1, recorder.doWork());

    _ = try recorder.onStartRecording(2, 2, "ch2", "src2", 0, 100);
    try std.testing.expectEqual(2, recorder.doWork());

    const id1 = 1;
    recorder.onStopRecording(id1, 200);
    try std.testing.expectEqual(1, recorder.doWork());

    const id2 = 2;
    recorder.onStopRecording(id2, 200);
    try std.testing.expectEqual(0, recorder.doWork());
}

test "Recorder findSession returns correct session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const id1 = try recorder.onStartRecording(10, 20, "ch1", "src1", 0, 100);
    const id2 = try recorder.onStartRecording(30, 40, "ch2", "src2", 0, 100);
    const id3 = try recorder.onStartRecording(50, 60, "ch3", "src3", 0, 100);

    const found1 = recorder.findSession(id1);
    try std.testing.expect(found1 != null);
    try std.testing.expectEqual(10, found1.?.session_id);

    const found2 = recorder.findSession(id2);
    try std.testing.expect(found2 != null);
    try std.testing.expectEqual(30, found2.?.session_id);

    const found3 = recorder.findSession(id3);
    try std.testing.expect(found3 != null);
    try std.testing.expectEqual(50, found3.?.session_id);

    const not_found = recorder.findSession(999);
    try std.testing.expect(not_found == null);
}
