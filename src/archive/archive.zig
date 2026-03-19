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

// =============================================================================
// Archive — Main Context
// =============================================================================

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
    pub fn init(allocator: std.mem.Allocator, ctx: ArchiveContext) Archive {
        return Archive{
            .allocator = allocator,
            .ctx = ctx,
            .conductor = conductor_mod.ArchiveConductor.init(allocator),
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

    const ctx = ArchiveContext{};
    var archive = Archive.init(allocator, ctx);
    defer archive.deinit();

    try std.testing.expect(!archive.isRunning());
}

test "Archive start and stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ArchiveContext{};
    var archive = Archive.init(allocator, ctx);
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

    const ctx = ArchiveContext{};
    var archive = Archive.init(allocator, ctx);
    defer archive.deinit();

    const work_count = try archive.doWork();
    try std.testing.expectEqual(@as(i32, 0), work_count);
}

test "Archive end-to-end: start recording, write data, replay" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create and start archive
    const ctx = ArchiveContext{};
    var archive = Archive.init(allocator, ctx);
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

    // Use a fixed recording_id for the rest of the test
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
