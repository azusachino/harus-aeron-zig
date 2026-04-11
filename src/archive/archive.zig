// Aeron Archive — top-level Archive owning Conductor and running duty cycles
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/Archive.java

const std = @import("std");
const conductor_mod = @import("conductor.zig");

// =============================================================================
// ArchiveContext — Configuration
// =============================================================================

/// Configuration for the Aeron Archive.
/// Controls channel endpoints, storage paths, and segment sizing.
pub const ArchiveContext = struct {
    /// Channel for archive control requests/responses (client ↔ archive).
    /// Clients send control commands on this channel; archive sends responses.
    control_channel: []const u8 = "aeron:udp?endpoint=localhost:8010",
    /// Stream ID for the control channel.
    control_stream_id: i32 = 10,
    /// Channel for recording event notifications broadcast to subscribers.
    /// Archive sends notifications about recording state changes to this channel.
    recording_events_channel: []const u8 = "aeron:udp?endpoint=localhost:8011",
    /// Stream ID for recording events.
    recording_events_stream_id: i32 = 11,
    /// Filesystem path where recordings and catalog are stored.
    /// This directory is created if it does not exist and holds all persisted data.
    archive_dir: []const u8 = "/tmp/aeron-archive",
    /// Maximum size of each recording segment file (default 128MB).
    /// Recordings are split into segments of this size for manageable file sizes.
    segment_file_length: i64 = 128 * 1024 * 1024,
};

/// ArchiveProxy — proxy to send control commands to the Archive.
pub const ArchiveProxy = struct {
    archive: *Archive,

    pub fn init(archive: *Archive) ArchiveProxy {
        return .{ .archive = archive };
    }

    pub fn startRecording(self: *ArchiveProxy, correlation_id: i64, session_id: i32, stream_id: i32, channel: []const u8, source_identity: []const u8) !void {
        try self.archive.enqueueCommand(.{
            .start_recording = .{
                .correlation_id = correlation_id,
                .session_id = session_id,
                .stream_id = stream_id,
                .channel = try self.archive.allocator.dupe(u8, channel),
                .source_identity = try self.archive.allocator.dupe(u8, source_identity),
                .initial_term_id = 0,
                .term_buffer_length = 0,
                .mtu_length = 0,
                .start_position = 0,
                .start_timestamp = 0,
            },
        });
    }
};


/// Archive — top-level context owning the ArchiveConductor.
/// Manages the lifecycle (start/stop) and runs duty cycles by delegating to the conductor
/// and its recorder/replayer components. Clients interact with the Archive by:
/// 1. Enqueueing commands via enqueueCommand()
/// 2. Polling responses via pollResponses()
/// 3. Calling doWork() regularly to advance the state machine
pub const Archive = struct {
    /// Allocator for all Archive allocations
    allocator: std.mem.Allocator,
    /// Configuration context (channels, paths, segment size)
    ctx: ArchiveContext,
    /// The ArchiveConductor that manages Catalog, Recorder, and Replayer
    conductor: conductor_mod.ArchiveConductor,
    /// Whether the archive is currently running and processing duty cycles
    is_running: bool = false,

    /// Initialize a new Archive with the given allocator and context.
    /// The conductor is created but not started; call start() to begin processing.
    pub fn init(allocator: std.mem.Allocator, ctx: ArchiveContext) !Archive {
        var conductor = try conductor_mod.ArchiveConductor.initWithArchiveDir(allocator, ctx.archive_dir);
        conductor.default_segment_file_length = @intCast(ctx.segment_file_length);
        return Archive{
            .allocator = allocator,
            .ctx = ctx,
            .conductor = conductor,
            .is_running = false,
        };
    }

    /// Free all Archive resources, including the conductor and all its sub-components.
    /// The Archive must not be running when deinit() is called.
    pub fn deinit(self: *Archive) void {
        self.conductor.deinit();
    }

    /// Start the archive, allowing it to process incoming commands and run duty cycles.
    /// After start() is called, doWork() will begin delegating to the conductor.
    pub fn start(self: *Archive) void {
        self.is_running = true;
    }

    /// Stop the archive, preventing further command processing and duty cycles.
    /// Existing queued commands and responses are preserved but not processed.
    pub fn stop(self: *Archive) void {
        self.is_running = false;
    }

    /// Check if the archive is currently running.
    pub fn isRunning(self: *const Archive) bool {
        return self.is_running;
    }

    /// Run one duty cycle of the archive.
    /// If running, delegates to conductor.doWork() and returns total work count.
    /// If not running, returns 0.
    /// Errors from the conductor propagate to the caller.
    pub fn doWork(self: *Archive) !i32 {
        if (!self.is_running) {
            return 0;
        }
        // Delegate to conductor's doWork, which processes pending commands
        // and manages recorder/replayer state machines.
        return try self.conductor.doWork();
    }

    /// Enqueue a control command for processing.
    /// The command will be handled on the next doWork() call.
    /// Returns an error if the queue is full or allocation fails.
    pub fn enqueueCommand(self: *Archive, cmd: conductor_mod.Command) !void {
        try self.conductor.enqueueCommand(cmd);
    }

    /// Poll and deliver all queued responses to the given handler.
    /// Calls handler for each response, then clears the response queue.
    /// Returns the number of responses delivered.
    pub fn pollResponses(self: *Archive, handler: *const fn (response: *const conductor_mod.Response) void) i32 {
        return self.conductor.pollResponses(handler);
    }

    /// Return a copy of the archive's configuration context.
    pub fn context(self: *const Archive) ArchiveContext {
        return self.ctx;
    }
};

// =============================================================================
// Re-exports for convenience
// =============================================================================

pub const Command = conductor_mod.Command;
pub const Response = conductor_mod.Response;
pub const StartRecordingCmd = conductor_mod.StartRecordingCmd;
pub const StopRecordingCmd = conductor_mod.StopRecordingCmd;
pub const ReplayCmd = conductor_mod.ReplayCmd;
pub const StopReplayCmd = conductor_mod.StopReplayCmd;
pub const ListRecordingsCmd = conductor_mod.ListRecordingsCmd;

// =============================================================================
// Tests
// =============================================================================

fn makeTempArchiveDir(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/harus-aeron-archive-{d}", .{std.time.nanoTimestamp()});
}

test "ArchiveContext has sensible defaults" {
    const ctx = ArchiveContext{};
    try std.testing.expectEqualStrings("aeron:udp?endpoint=localhost:8010", ctx.control_channel);
    try std.testing.expectEqual(@as(i32, 10), ctx.control_stream_id);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=localhost:8011", ctx.recording_events_channel);
    try std.testing.expectEqual(@as(i32, 11), ctx.recording_events_stream_id);
    try std.testing.expectEqualStrings("/tmp/aeron-archive", ctx.archive_dir);
    try std.testing.expectEqual(@as(i64, 128 * 1024 * 1024), ctx.segment_file_length);
}

test "Archive init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try makeTempArchiveDir(allocator);
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    const ctx = ArchiveContext{ .archive_dir = archive_dir };
    var archive = try Archive.init(allocator, ctx);
    defer archive.deinit();

    try std.testing.expect(!archive.isRunning());
}

test "Archive start and stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try makeTempArchiveDir(allocator);
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    const ctx = ArchiveContext{ .archive_dir = archive_dir };
    var archive = try Archive.init(allocator, ctx);
    defer archive.deinit();

    try std.testing.expect(!archive.isRunning());

    archive.start();
    try std.testing.expect(archive.isRunning());

    archive.stop();
    try std.testing.expect(!archive.isRunning());
}

test "Archive doWork returns 0 when not running" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try makeTempArchiveDir(allocator);
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    const ctx = ArchiveContext{ .archive_dir = archive_dir };
    var archive = try Archive.init(allocator, ctx);
    defer archive.deinit();

    const work_count = try archive.doWork();
    try std.testing.expectEqual(@as(i32, 0), work_count);
}

test "Archive end-to-end: start recording, write data, replay" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create and start archive
    const archive_dir = try makeTempArchiveDir(allocator);
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    const ctx = ArchiveContext{ .archive_dir = archive_dir };
    var archive = try Archive.init(allocator, ctx);
    defer archive.deinit();

    archive.start();
    try std.testing.expect(archive.isRunning());

    // Enqueue start_recording command
    const channel = try allocator.dupe(u8, "aeron:udp?endpoint=localhost:40123");
    defer allocator.free(channel);
    const source_identity = try allocator.dupe(u8, "test-source");
    defer allocator.free(source_identity);

    const start_cmd = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 100,
            .session_id = 1,
            .stream_id = 2,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    try archive.enqueueCommand(start_cmd);

    // Process the command
    _ = try archive.doWork();

    // Verify response count
    const dummy_handler = struct {
        pub fn handle(_: *const Response) void {}
    }.handle;

    const response_count = archive.pollResponses(&dummy_handler);
    try std.testing.expectEqual(@as(i32, 1), response_count);

    // Write a couple of fragments through the live recorder session.
    try std.testing.expect(archive.conductor.recorder != null);
    const recorder = archive.conductor.recorder.?;
    const session = recorder.findSession(1) orelse unreachable;
    try session.onFragment("frame-one");
    try session.onFragment("frame-two");
    try session.writer.flush();

    // Use a fixed recording_id for the rest of the test.
    const recording_id: i64 = 1;

    // Enqueue stop_recording command
    const stop_cmd = Command{
        .stop_recording = StopRecordingCmd{
            .correlation_id = 101,
            .recording_id = recording_id,
        },
    };

    try archive.enqueueCommand(stop_cmd);
    _ = try archive.doWork();

    const stop_response_count = archive.pollResponses(&dummy_handler);
    try std.testing.expectEqual(@as(i32, 1), stop_response_count);

    // Enqueue replay command
    const replay_cmd = Command{
        .replay = ReplayCmd{
            .correlation_id = 102,
            .recording_id = recording_id,
            .position = 0,
            .length = 1000,
        },
    };

    try archive.enqueueCommand(replay_cmd);
    _ = try archive.doWork();

    const replay_response_count = archive.pollResponses(&dummy_handler);
    try std.testing.expectEqual(@as(i32, 1), replay_response_count);

    const replay_session = archive.conductor.replayer.findSession(1) orelse unreachable;
    try std.testing.expectEqualSlices(u8, "frame-oneframe-two", replay_session.source_data);

    // Enqueue stop_replay command
    const stop_replay_cmd = Command{
        .stop_replay = StopReplayCmd{
            .correlation_id = 103,
            .replay_session_id = 1,
        },
    };

    try archive.enqueueCommand(stop_replay_cmd);
    _ = try archive.doWork();

    const stop_replay_response_count = archive.pollResponses(&dummy_handler);
    try std.testing.expectEqual(@as(i32, 1), stop_replay_response_count);

    // Stop archive and verify doWork returns 0
    archive.stop();
    const no_work = try archive.doWork();
    try std.testing.expectEqual(@as(i32, 0), no_work);
}

test "Archive survives restart for listing and replay" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try makeTempArchiveDir(allocator);
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    const ctx = ArchiveContext{ .archive_dir = archive_dir };

    {
        var archive = try Archive.init(allocator, ctx);
        defer archive.deinit();
        archive.start();

        const channel = try allocator.dupe(u8, "aeron:udp?endpoint=localhost:40123");
        defer allocator.free(channel);
        const source_identity = try allocator.dupe(u8, "test-source");
        defer allocator.free(source_identity);

        try archive.enqueueCommand(.{
            .start_recording = .{
                .correlation_id = 1,
                .session_id = 7,
                .stream_id = 8,
                .channel = channel,
                .source_identity = source_identity,
                .initial_term_id = 21,
                .term_buffer_length = 256 * 1024,
                .mtu_length = 4096,
                .start_position = 64,
                .start_timestamp = 999,
            },
        });
        _ = try archive.doWork();
        _ = archive.pollResponses(&struct {
            fn handle(_: *const Response) void {}
        }.handle);

        const recorder = archive.conductor.recorder.?;
        const session = recorder.findSession(1).?;
        try session.onFragment("persisted-frame");
        try session.writer.flush();

        try archive.enqueueCommand(.{
            .stop_recording = .{
                .correlation_id = 2,
                .recording_id = 1,
            },
        });
        _ = try archive.doWork();
        _ = archive.pollResponses(&struct {
            fn handle(_: *const Response) void {}
        }.handle);
    }

    {
        var archive = try Archive.init(allocator, ctx);
        defer archive.deinit();
        archive.start();

        try archive.enqueueCommand(.{
            .list_recordings = .{
                .correlation_id = 3,
                .from_recording_id = 1,
                .record_count = 10,
            },
        });
        _ = try archive.doWork();
        const Capture = struct {
            pub var listed_count: i64 = -1;
        };
        Capture.listed_count = -1;
        _ = archive.pollResponses(&struct {
            fn handle(response: *const Response) void {
                Capture.listed_count = response.recording_id;
            }
        }.handle);

        try std.testing.expectEqual(@as(i64, 1), Capture.listed_count);
        const descriptor = archive.conductor.catalog.recordingDescriptor(1).?;
        try std.testing.expectEqual(@as(i32, 21), descriptor.initial_term_id);
        try std.testing.expectEqual(@as(i32, @intCast(ctx.segment_file_length)), descriptor.segment_file_length);
        try std.testing.expectEqual(@as(i32, 256 * 1024), descriptor.term_buffer_length);
        try std.testing.expectEqual(@as(i32, 4096), descriptor.mtu_length);
        try std.testing.expectEqual(@as(i64, 64), descriptor.start_position);
        try std.testing.expectEqual(@as(i64, 999), descriptor.start_timestamp);

        try archive.enqueueCommand(.{
            .replay = .{
                .correlation_id = 4,
                .recording_id = 1,
                .position = 0,
                .length = 0,
            },
        });
        _ = try archive.doWork();
        _ = archive.pollResponses(&struct {
            fn handle(_: *const Response) void {}
        }.handle);

        const replay_session = archive.conductor.replayer.findSession(1).?;
        try std.testing.expectEqualSlices(u8, "persisted-frame", replay_session.source_data);
    }
}
