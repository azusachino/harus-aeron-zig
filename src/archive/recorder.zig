// Aeron Archive Recorder — manages active recording sessions
// Writes incoming media frames to on-disk recordings and catalogs metadata
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/Archive.java

const std = @import("std");
const catalog_mod = @import("catalog.zig");
const protocol = @import("protocol.zig");

pub const RecordingMetadata = struct {
    initial_term_id: i32 = 0,
    segment_file_length: i32 = 128 * 1024 * 1024,
    term_buffer_length: i32 = 64 * 1024,
    mtu_length: i32 = 1408,
    start_position: i64 = 0,
    start_timestamp: i64 = 0,
};

/// RecordingWriter — buffers raw frame data for a single recording and mirrors it to disk.
/// Supports segment rotation: when a segment fills up, the writer closes the current file
/// and opens a new one named `{recording_id}-{segment_base}.dat`.
pub const RecordingWriter = struct {
    allocator: std.mem.Allocator,
    recording_id: i64,
    archive_dir: []const u8,
    path: []u8,
    file: ?std.fs.File,
    /// Position of first byte in this recording (from media context)
    start_position: i64,
    /// Current write position (start_position + bytes_written_across_all_segments)
    stop_position: i64,
    /// Position at the start of the current segment file.
    current_segment_base: i64,
    /// Maximum bytes per segment file; 0 means no rotation.
    segment_file_length: i64,
    /// In-memory buffer for raw frame data (current segment only)
    buffer: std.ArrayList(u8),

    /// Build segment file path: `{archive_dir}/{recording_id}-{base_position}.dat`
    pub fn segmentFilePath(allocator: std.mem.Allocator, archive_dir: []const u8, recording_id: i64, base_position: i64) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{d}-{d}.dat", .{ archive_dir, recording_id, base_position });
    }

    /// Initialize a new recording writer with no segment rotation (for tests).
    pub fn init(
        allocator: std.mem.Allocator,
        recording_id: i64,
        start_position: i64,
    ) !RecordingWriter {
        return RecordingWriter.initWithSegment(allocator, recording_id, start_position, 0, "/tmp/aeron-archive");
    }

    /// Initialize a new recording writer with a configured archive directory.
    pub fn initWithArchiveDir(
        allocator: std.mem.Allocator,
        recording_id: i64,
        start_position: i64,
        archive_dir: []const u8,
    ) !RecordingWriter {
        return RecordingWriter.initWithSegment(allocator, recording_id, start_position, 0, archive_dir);
    }

    /// Initialize with explicit segment_file_length for rotation.
    /// segment_file_length == 0 disables rotation.
    pub fn initWithSegment(
        allocator: std.mem.Allocator,
        recording_id: i64,
        start_position: i64,
        segment_file_length: i64,
        archive_dir: []const u8,
    ) !RecordingWriter {
        try std.fs.cwd().makePath(archive_dir);

        const path = try segmentFilePath(allocator, archive_dir, recording_id, start_position);
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
            .current_segment_base = start_position,
            .segment_file_length = segment_file_length,
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
    /// Rotates to a new segment file when the current segment is full.
    pub fn write(self: *RecordingWriter, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
        if (self.file) |*file| {
            try file.writeAll(data);
        }
        self.stop_position += @as(i64, @intCast(data.len));

        // Rotate segment if configured and current segment is full.
        if (self.segment_file_length > 0 and
            self.stop_position - self.current_segment_base >= self.segment_file_length)
        {
            try self.rotateSegment();
        }
    }

    /// Close current segment and open a new one starting at `stop_position`.
    fn rotateSegment(self: *RecordingWriter) !void {
        if (self.file) |f| {
            try f.sync();
            f.close();
            self.file = null;
        }
        self.buffer.clearRetainingCapacity();
        self.current_segment_base = self.stop_position;

        self.allocator.free(self.path);
        self.path = try segmentFilePath(self.allocator, self.archive_dir, self.recording_id, self.current_segment_base);

        self.file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
    }

    /// Read the current segment file from disk.
    pub fn readAll(self: *RecordingWriter, allocator: std.mem.Allocator) ![]u8 {
        const file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();

        return file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    }

    /// Read and concatenate all segment files for this recording from disk.
    /// Reads from start_position up to stop_position across all segments.
    pub fn readAllSegments(self: *RecordingWriter, allocator: std.mem.Allocator) ![]u8 {
        return readAllSegmentsFromDisk(
            allocator,
            self.archive_dir,
            self.recording_id,
            self.start_position,
            self.stop_position,
            self.segment_file_length,
        );
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

/// Read and concatenate all segment files for a recording.
/// Called by ArchiveConductor.readRecordingData for multi-segment replay.
pub fn readAllSegmentsFromDisk(
    allocator: std.mem.Allocator,
    archive_dir: []const u8,
    recording_id: i64,
    start_position: i64,
    stop_position: i64,
    segment_file_length: i64,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    if (stop_position <= start_position) {
        return try allocator.alloc(u8, 0);
    }

    const end_position = stop_position;
    const eff_segment_len: i64 = if (segment_file_length > 0) segment_file_length else end_position - start_position;
    var base: i64 = start_position;
    while (base < end_position) {
        const seg_path = try RecordingWriter.segmentFilePath(allocator, archive_dir, recording_id, base);
        defer allocator.free(seg_path);

        const file = std.fs.cwd().openFile(seg_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        defer file.close();

        const file_size = (try file.stat()).size;
        const remaining = end_position - base;
        const bytes_to_read = @min(file_size, remaining);
        if (bytes_to_read > 0) {
            const old_len = result.items.len;
            const read_len: usize = @as(usize, @intCast(bytes_to_read));
            try result.resize(allocator, old_len + read_len);
            const actual = try file.readAll(result.items[old_len .. old_len + read_len]);
            if (actual < read_len) {
                try result.resize(allocator, old_len + actual);
            }
        }

        if (segment_file_length <= 0) break;
        base += eff_segment_len;
    }

    return result.toOwnedSlice(allocator);
}

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
        return RecordingSession.initWithArchiveDir(allocator, recording_id, session_id, stream_id, channel, start_position, 0, "/tmp/aeron-archive");
    }

    pub fn initWithArchiveDir(
        allocator: std.mem.Allocator,
        recording_id: i64,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        start_position: i64,
        segment_file_length: i64,
        archive_dir: []const u8,
    ) !RecordingSession {
        return RecordingSession{
            .allocator = allocator,
            .recording_id = recording_id,
            .session_id = session_id,
            .stream_id = stream_id,
            .channel = try allocator.dupe(u8, channel),
            .active = true,
            .writer = try RecordingWriter.initWithSegment(allocator, recording_id, start_position, segment_file_length, archive_dir),
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
        metadata: RecordingMetadata,
    ) !i64 {
        // Allocate catalog entry (next_recording_id is auto-incremented)
        const recording_id = try self.catalog.addNewRecording(
            session_id,
            stream_id,
            channel,
            source_identity,
            metadata.initial_term_id,
            metadata.segment_file_length,
            metadata.term_buffer_length,
            metadata.mtu_length,
            metadata.start_position,
            metadata.start_timestamp,
        );

        // Create and store the session
        const session = try RecordingSession.initWithArchiveDir(
            self.allocator,
            recording_id,
            session_id,
            stream_id,
            channel,
            metadata.start_position,
            @as(i64, metadata.segment_file_length),
            self.archive_dir,
        );
        try self.sessions.append(self.allocator, session);

        return recording_id;
    }

    /// Stop an active recording.
    /// Closes the session and updates catalog with final position and timestamp.
    /// recording_id: ID of recording to stop
    /// stop_timestamp: wall-clock time when recording stopped
    pub fn onStopRecording(self: *Recorder, recording_id: i64, stop_timestamp: i64) !void {
        // Find and close the matching session
        for (self.sessions.items) |*session| {
            if (session.recording_id == recording_id) {
                session.close();
                // Update catalog with final state
                try self.catalog.updateStopState(recording_id, session.writer.stopPosition(), stop_timestamp);
                return;
            }
        }
    }

    /// Reopen a stopped recording session so the archive can continue appending
    /// to the same logical recording_id.
    pub fn onExtendRecording(self: *Recorder, recording_id: i64) !void {
        const session = self.findSession(recording_id) orelse return error.RecordingNotFound;
        if (session.isActive()) {
            return error.RecordingActive;
        }

        session.active = true;
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

test "Recorder start recording persists descriptor metadata" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const recording_id = try recorder.onStartRecording(
        7,
        8,
        "aeron:udp?endpoint=localhost:40123",
        "source-A",
        .{
            .initial_term_id = 42,
            .segment_file_length = 64 * 1024 * 1024,
            .term_buffer_length = 256 * 1024,
            .mtu_length = 4096,
            .start_position = 128,
            .start_timestamp = 777,
        },
    );

    const entry = catalog.recordingDescriptor(recording_id).?;
    try std.testing.expectEqual(@as(i32, 42), entry.initial_term_id);
    try std.testing.expectEqual(@as(i32, 64 * 1024 * 1024), entry.segment_file_length);
    try std.testing.expectEqual(@as(i32, 256 * 1024), entry.term_buffer_length);
    try std.testing.expectEqual(@as(i32, 4096), entry.mtu_length);
    try std.testing.expectEqual(@as(i64, 128), entry.start_position);
    try std.testing.expectEqual(@as(i64, 777), entry.start_timestamp);
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
        .{
            .start_position = 0,
            .start_timestamp = 1000,
        },
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
        .{
            .start_position = 100,
            .start_timestamp = 5000,
        },
    );

    // Write some data
    var session = recorder.findSession(recording_id).?;
    try session.onFragment("data1");
    try session.onFragment("data2");

    // Stop recording
    try recorder.onStopRecording(recording_id, 6000);

    try std.testing.expect(!session.isActive());

    const cat_entry = catalog.recordingDescriptor(recording_id).?;
    try std.testing.expectEqual(6000, cat_entry.stop_timestamp);
    try std.testing.expectEqual(110, cat_entry.stop_position); // 100 + 10 bytes written
}

test "Recorder onExtendRecording reactivates stopped session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const recording_id = try recorder.onStartRecording(
        321,
        654,
        "ch-extend",
        "src-extend",
        .{
            .start_position = 0,
            .start_timestamp = 9000,
        },
    );

    var session = recorder.findSession(recording_id).?;
    try session.onFragment("abc");
    try recorder.onStopRecording(recording_id, 9100);

    try std.testing.expect(!session.isActive());
    try std.testing.expectEqual(@as(i64, 3), catalog.recordingDescriptor(recording_id).?.stop_position);

    try recorder.onExtendRecording(recording_id);
    try std.testing.expect(session.isActive());
    try std.testing.expectEqual(@as(usize, 1), recorder.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), recorder.activeSessions());

    try session.onFragment("defg");
    try recorder.onStopRecording(recording_id, 9200);

    try std.testing.expectEqual(@as(i64, 7), catalog.recordingDescriptor(recording_id).?.stop_position);
    try std.testing.expectEqual(@as(usize, 1), recorder.sessions.items.len);
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

    _ = try recorder.onStartRecording(1, 1, "ch1", "src1", .{
        .start_position = 0,
        .start_timestamp = 100,
    });
    try std.testing.expectEqual(1, recorder.doWork());

    _ = try recorder.onStartRecording(2, 2, "ch2", "src2", .{
        .start_position = 0,
        .start_timestamp = 100,
    });
    try std.testing.expectEqual(2, recorder.doWork());

    const id1 = 1;
    try recorder.onStopRecording(id1, 200);
    try std.testing.expectEqual(1, recorder.doWork());

    const id2 = 2;
    try recorder.onStopRecording(id2, 200);
    try std.testing.expectEqual(0, recorder.doWork());
}

test "RecordingWriter rotates to new segment when full" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try std.fmt.allocPrint(allocator, "/tmp/harus-seg-rotate-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    // Small segment size of 10 bytes to force rotation
    var writer = try RecordingWriter.initWithSegment(allocator, 42, 0, 10, archive_dir);
    defer writer.deinit();

    // Write 10 bytes — exactly fills segment 0 → rotation happens at end of write
    try writer.write("0123456789");
    try std.testing.expectEqual(@as(i64, 10), writer.current_segment_base);
    try std.testing.expectEqual(@as(i64, 10), writer.stop_position);

    // Second write goes into segment 10
    try writer.write("abcde");
    try std.testing.expectEqual(@as(i64, 10), writer.current_segment_base);
    try std.testing.expectEqual(@as(i64, 15), writer.stop_position);

    // Segment 0 file should exist with 10 bytes
    const seg0_path = try RecordingWriter.segmentFilePath(allocator, archive_dir, 42, 0);
    defer allocator.free(seg0_path);
    const seg0_file = try std.fs.cwd().openFile(seg0_path, .{});
    defer seg0_file.close();
    try std.testing.expectEqual(@as(u64, 10), (try seg0_file.stat()).size);

    // Segment 1 file should exist with 5 bytes
    const seg1_path = try RecordingWriter.segmentFilePath(allocator, archive_dir, 42, 10);
    defer allocator.free(seg1_path);
    const seg1_file = try std.fs.cwd().openFile(seg1_path, .{});
    defer seg1_file.close();
    try std.testing.expectEqual(@as(u64, 5), (try seg1_file.stat()).size);
}

test "readAllSegmentsFromDisk reads across multiple segments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try std.fmt.allocPrint(allocator, "/tmp/harus-seg-all-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    // Write 25 bytes across segments of size 10
    var writer = try RecordingWriter.initWithSegment(allocator, 99, 0, 10, archive_dir);
    defer writer.deinit();

    try writer.write("0123456789"); // segment 0 → full → rotate
    try writer.write("abcdefghij"); // segment 10 → full → rotate
    try writer.write("ABCDE"); // segment 20

    try writer.flush();

    const all = try writer.readAllSegments(allocator);
    defer allocator.free(all);

    try std.testing.expectEqual(@as(usize, 25), all.len);
    try std.testing.expectEqualSlices(u8, "0123456789", all[0..10]);
    try std.testing.expectEqualSlices(u8, "abcdefghij", all[10..20]);
    try std.testing.expectEqualSlices(u8, "ABCDE", all[20..25]);
}

test "readAllSegmentsFromDisk truncates final segment at stop_position" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try std.fmt.allocPrint(allocator, "/tmp/harus-seg-trunc-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    var writer = try RecordingWriter.initWithSegment(allocator, 77, 0, 10, archive_dir);
    defer writer.deinit();

    try writer.write("0123456789");
    try writer.write("abcdefghij");
    try writer.write("ABCDE");
    try writer.flush();

    const clipped = try readAllSegmentsFromDisk(allocator, archive_dir, 77, 0, 15, 10);
    defer allocator.free(clipped);

    try std.testing.expectEqual(@as(usize, 15), clipped.len);
    try std.testing.expectEqualSlices(u8, "0123456789", clipped[0..10]);
    try std.testing.expectEqualSlices(u8, "abcde", clipped[10..15]);
}

test "Recorder findSession returns correct session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();

    var recorder = Recorder.init(allocator, &catalog);
    defer recorder.deinit();

    const id1 = try recorder.onStartRecording(10, 20, "ch1", "src1", .{
        .start_position = 0,
        .start_timestamp = 100,
    });
    const id2 = try recorder.onStartRecording(30, 40, "ch2", "src2", .{
        .start_position = 0,
        .start_timestamp = 100,
    });
    const id3 = try recorder.onStartRecording(50, 60, "ch3", "src3", .{
        .start_position = 0,
        .start_timestamp = 100,
    });

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
