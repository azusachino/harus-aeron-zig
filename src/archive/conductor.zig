// Aeron Archive Conductor — command dispatcher and response aggregator
// Routes control commands from clients to Recorder/Replayer and queues responses.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/ArchiveConductor.java

const std = @import("std");
const catalog_mod = @import("catalog.zig");
const recorder_mod = @import("recorder.zig");
const replayer_mod = @import("replayer.zig");
const protocol = @import("protocol.zig");

// =============================================================================
// Command Payloads
// =============================================================================

/// StartRecordingCmd — parameters for starting a new recording.
/// Extracted from StartRecordingRequest with variable-length fields duplicated.
pub const StartRecordingCmd = struct {
    correlation_id: i64,
    session_id: i32,
    stream_id: i32,
    channel: []const u8,
    source_identity: []const u8,
};

/// StopRecordingCmd — parameters for stopping an active recording.
pub const StopRecordingCmd = struct {
    correlation_id: i64,
    recording_id: i64,
};

/// ReplayCmd — parameters for starting a replay session.
pub const ReplayCmd = struct {
    correlation_id: i64,
    recording_id: i64,
    position: i64,
    length: i64,
};

/// StopReplayCmd — parameters for stopping a replay session.
pub const StopReplayCmd = struct {
    correlation_id: i64,
    replay_session_id: i64,
};

/// ListRecordingsCmd — parameters for listing recordings in a range.
pub const ListRecordingsCmd = struct {
    correlation_id: i64,
    from_recording_id: i64,
    record_count: i32,
};

// =============================================================================
// Command Union
// =============================================================================

/// Command — union of all possible control commands.
/// Each variant carries the parameters needed to execute that operation.
pub const Command = union(enum) {
    start_recording: StartRecordingCmd,
    stop_recording: StopRecordingCmd,
    replay: ReplayCmd,
    stop_replay: StopReplayCmd,
    list_recordings: ListRecordingsCmd,
};

// =============================================================================
// Response Struct
// =============================================================================

/// Response — queued for delivery to the client.
/// Contains correlation_id to match with the original request, code indicating
/// success/error, recording_id/count for specific responses, and error_message.
pub const Response = struct {
    /// Request correlation ID for client matching
    correlation_id: i64,
    /// Response code: 0=ok, 1=err, 2=recording_unknown
    code: i32,
    /// For start/replay responses: the created recording/session ID.
    /// For list responses: the count of entries returned.
    recording_id: i64,
    /// Error message (empty string for success)
    error_message: []const u8,
};

// =============================================================================
// ArchiveConductor
// =============================================================================

/// ArchiveConductor — command dispatcher and response aggregator.
/// Owns the Catalog, Recorder, and Replayer. Routes client commands to them
/// and collects responses for delivery back to clients.
pub const ArchiveConductor = struct {
    allocator: std.mem.Allocator,
    archive_dir: []const u8,
    /// Shared catalog for recording metadata
    catalog: catalog_mod.Catalog,
    /// Recorder managing active recording sessions
    recorder: ?*recorder_mod.Recorder,
    /// Replayer managing active replay sessions
    replayer: replayer_mod.Replayer,
    /// Queue of pending commands from clients
    pending_commands: std.ArrayList(Command),
    /// Queue of outgoing responses to clients
    responses: std.ArrayList(Response),

    /// Initialize a new ArchiveConductor.
    /// Allocator is retained for all subsequent operations.
    pub fn init(allocator: std.mem.Allocator) ArchiveConductor {
        return ArchiveConductor{
            .allocator = allocator,
            .archive_dir = "/tmp/aeron-archive",
            .catalog = catalog_mod.Catalog.init(allocator),
            .recorder = null,
            .replayer = replayer_mod.Replayer.init(allocator),
            .pending_commands = .{},
            .responses = .{},
        };
    }

    pub fn initWithArchiveDir(allocator: std.mem.Allocator, archive_dir: []const u8) !ArchiveConductor {
        return ArchiveConductor{
            .allocator = allocator,
            .archive_dir = archive_dir,
            .catalog = try catalog_mod.Catalog.initWithArchiveDir(allocator, archive_dir),
            .recorder = null,
            .replayer = replayer_mod.Replayer.init(allocator),
            .pending_commands = .{},
            .responses = .{},
        };
    }

    /// Initialize recorder after creating conductor (due to borrow checker).
    /// Must be called once after init() and before doWork().
    fn initRecorder(self: *ArchiveConductor) !void {
        if (self.recorder == null) {
            const recorder = try self.allocator.create(recorder_mod.Recorder);
            recorder.* = recorder_mod.Recorder.initWithArchiveDir(self.allocator, &self.catalog, self.archive_dir);
            self.recorder = recorder;
        }
    }

    /// Free all conductor resources.
    /// Caller must have already freed any string allocations in Command payloads.
    pub fn deinit(self: *ArchiveConductor) void {
        if (self.recorder) |recorder| {
            recorder.deinit();
            self.allocator.destroy(recorder);
        }
        self.replayer.deinit();
        self.catalog.deinit();
        self.pending_commands.deinit(self.allocator);
        self.responses.deinit(self.allocator);
    }

    /// Enqueue a command for processing.
    pub fn enqueueCommand(self: *ArchiveConductor, cmd: Command) !void {
        try self.pending_commands.append(self.allocator, cmd);
    }

    /// Process all pending commands and queue responses.
    /// Returns the number of commands processed.
    pub fn doWork(self: *ArchiveConductor) !i32 {
        // Initialize recorder on first doWork (after all fields are ready).
        try self.initRecorder();

        var work_count: i32 = 0;
        while (self.pending_commands.pop()) |cmd| {
            try self.processCommand(cmd);
            work_count += 1;
        }
        return work_count;
    }

    /// Process a single command and queue its response.
    fn processCommand(self: *ArchiveConductor, cmd: Command) !void {
        switch (cmd) {
            .start_recording => |start_cmd| {
                self.handleStartRecording(start_cmd) catch |err| {
                    try self.queueErrorResponse(start_cmd.correlation_id, err);
                };
            },
            .stop_recording => |stop_cmd| {
                self.handleStopRecording(stop_cmd) catch |err| {
                    try self.queueErrorResponse(stop_cmd.correlation_id, err);
                };
            },
            .replay => |replay_cmd| {
                self.handleReplay(replay_cmd) catch |err| {
                    try self.queueErrorResponse(replay_cmd.correlation_id, err);
                };
            },
            .stop_replay => |stop_replay_cmd| {
                self.handleStopReplay(stop_replay_cmd) catch |err| {
                    try self.queueErrorResponse(stop_replay_cmd.correlation_id, err);
                };
            },
            .list_recordings => |list_cmd| {
                self.handleListRecordings(list_cmd) catch |err| {
                    try self.queueErrorResponse(list_cmd.correlation_id, err);
                };
            },
        }
    }

    /// Handle start_recording command.
    fn handleStartRecording(self: *ArchiveConductor, cmd: StartRecordingCmd) !void {
        const recorder = self.recorder orelse return error.RecorderNotInitialized;
        const recording_id = try recorder.onStartRecording(
            cmd.session_id,
            cmd.stream_id,
            cmd.channel,
            cmd.source_identity,
            0, // start_position: use 0 for now
            0, // start_timestamp: use 0 for now
        );
        try self.queueSuccessResponse(cmd.correlation_id, recording_id);
    }

    /// Handle stop_recording command.
    fn handleStopRecording(self: *ArchiveConductor, cmd: StopRecordingCmd) !void {
        const recorder = self.recorder orelse return error.RecorderNotInitialized;
        try recorder.onStopRecording(cmd.recording_id, 0); // stop_timestamp: use 0 for now
        try self.queueSuccessResponse(cmd.correlation_id, cmd.recording_id);
    }

    /// Handle replay command.
    fn handleReplay(self: *ArchiveConductor, cmd: ReplayCmd) !void {
        // Look up the recording in the catalog
        const recording = self.catalog.recordingDescriptor(cmd.recording_id);
        if (recording == null) {
            try self.queueErrorCodeResponse(
                cmd.correlation_id,
                @intFromEnum(protocol.ControlResponseCode.recording_unknown),
            );
            return;
        }

        const replay_source = try self.readRecordingData(cmd.recording_id);
        defer self.allocator.free(replay_source);

        // Start the replay session
        const replay_session_id = try self.replayer.onReplayRequest(
            cmd.recording_id,
            cmd.position,
            cmd.length,
            replay_source,
        );
        try self.queueSuccessResponse(cmd.correlation_id, replay_session_id);
    }

    /// Handle stop_replay command.
    fn handleStopReplay(self: *ArchiveConductor, cmd: StopReplayCmd) !void {
        self.replayer.onStopReplay(cmd.replay_session_id);
        try self.queueSuccessResponse(cmd.correlation_id, cmd.replay_session_id);
    }

    /// Handle list_recordings command.
    fn handleListRecordings(self: *ArchiveConductor, cmd: ListRecordingsCmd) !void {
        var count: i32 = 0;
        const handler = struct {
            pub fn handle(_: *const catalog_mod.RecordingDescriptorEntry) void {
                // Placeholder: in a real system, this would serialize the descriptor.
                // For now, just count entries.
            }
        }.handle;

        count = self.catalog.listRecordings(cmd.from_recording_id, cmd.record_count, &handler);
        try self.queueSuccessResponse(cmd.correlation_id, count);
    }

    /// Queue a success response with a result value.
    fn queueSuccessResponse(self: *ArchiveConductor, correlation_id: i64, result: i64) !void {
        const response = Response{
            .correlation_id = correlation_id,
            .code = @intFromEnum(protocol.ControlResponseCode.ok),
            .recording_id = result,
            .error_message = "",
        };
        try self.responses.append(self.allocator, response);
    }

    /// Queue an error response with ControlResponseCode.err.
    fn queueErrorResponse(self: *ArchiveConductor, correlation_id: i64, _: anytype) !void {
        const response = Response{
            .correlation_id = correlation_id,
            .code = @intFromEnum(protocol.ControlResponseCode.err),
            .recording_id = 0,
            .error_message = "",
        };
        try self.responses.append(self.allocator, response);
    }

    /// Queue an error response with a specific error code.
    fn queueErrorCodeResponse(self: *ArchiveConductor, correlation_id: i64, code: i32) !void {
        const response = Response{
            .correlation_id = correlation_id,
            .code = code,
            .recording_id = 0,
            .error_message = "",
        };
        try self.responses.append(self.allocator, response);
    }

    /// Drain and deliver all queued responses.
    /// Calls handler for each response, then clears the queue.
    /// Returns the number of responses delivered.
    pub fn pollResponses(self: *ArchiveConductor, handler: *const fn (response: *const Response) void) i32 {
        var count: i32 = 0;
        for (self.responses.items) |*response| {
            handler(response);
            count += 1;
        }
        self.responses.clearRetainingCapacity();
        return count;
    }

    /// Return the number of pending commands.
    pub fn pendingCommandCount(self: *const ArchiveConductor) usize {
        return self.pending_commands.items.len;
    }

    /// Return the number of queued responses.
    pub fn responseCount(self: *const ArchiveConductor) usize {
        return self.responses.items.len;
    }

    /// Delegate to recorder for active session count.
    pub fn recorderActiveSessions(self: *const ArchiveConductor) usize {
        return if (self.recorder) |recorder| recorder.activeSessions() else 0;
    }

    /// Delegate to replayer for active session count.
    pub fn replayerActiveSessions(self: *const ArchiveConductor) usize {
        return self.replayer.activeSessions();
    }

    fn readRecordingData(self: *ArchiveConductor, recording_id: i64) ![]u8 {
        if (self.recorder) |recorder| {
            if (recorder.findSession(recording_id)) |session| {
                try session.writer.flush();
                return session.snapshot(self.allocator);
            }
        }

        const recording_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}.dat", .{ self.archive_dir, recording_id });
        defer self.allocator.free(recording_path);

        const file = try std.fs.cwd().openFile(recording_path, .{});
        defer file.close();
        const file_size = (try file.stat()).size;
        return file.readToEndAlloc(self.allocator, file_size);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ArchiveConductor init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    defer conductor.deinit();

    try std.testing.expectEqual(0, conductor.pendingCommandCount());
    try std.testing.expectEqual(0, conductor.responseCount());
}

test "ArchiveConductor start_recording command creates recording" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(channel);
    const source_identity = try allocator.dupe(u8, "test-source");
    defer allocator.free(source_identity);

    const cmd = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 100,
            .session_id = 1,
            .stream_id = 2,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    try conductor.enqueueCommand(cmd);
    _ = try conductor.doWork();

    try std.testing.expectEqual(1, conductor.responseCount());

    const Capture = struct {
        pub var response_received: bool = false;
    };
    Capture.response_received = false;
    const handler = struct {
        pub fn handle(response: *const Response) void {
            Capture.response_received = response.correlation_id == 100 and
                response.code == @intFromEnum(protocol.ControlResponseCode.ok) and
                response.recording_id == 1;
        }
    }.handle;

    _ = conductor.pollResponses(&handler);
    try std.testing.expect(Capture.response_received);
}

test "ArchiveConductor stop_recording command stops recording" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Start a recording first
    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
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

    try conductor.enqueueCommand(start_cmd);
    _ = try conductor.doWork();
    _ = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);

    // Stop the recording
    const stop_cmd = Command{
        .stop_recording = StopRecordingCmd{
            .correlation_id = 101,
            .recording_id = 1,
        },
    };

    try conductor.enqueueCommand(stop_cmd);
    _ = try conductor.doWork();

    try std.testing.expectEqual(1, conductor.responseCount());
}

test "ArchiveConductor replay command creates replay session" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Start a recording
    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
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

    try conductor.enqueueCommand(start_cmd);
    _ = try conductor.doWork();
    _ = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);

    // Write some data to the recording
    try std.testing.expect(conductor.recorder != null);
    if (conductor.recorder.?.findSession(1)) |session| {
        try session.onFragment("test data");
    }

    // Replay the recording
    const replay_cmd = Command{
        .replay = ReplayCmd{
            .correlation_id = 101,
            .recording_id = 1,
            .position = 0,
            .length = 0,
        },
    };

    try conductor.enqueueCommand(replay_cmd);
    _ = try conductor.doWork();

    try std.testing.expectEqual(1, conductor.responseCount());
}

test "ArchiveConductor stop_replay command stops replay" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Start a recording and write data
    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
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

    try conductor.enqueueCommand(start_cmd);
    _ = try conductor.doWork();
    _ = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);

    try std.testing.expect(conductor.recorder != null);
    if (conductor.recorder.?.findSession(1)) |session| {
        try session.onFragment("test data");
    }

    // Start replay
    const replay_cmd = Command{
        .replay = ReplayCmd{
            .correlation_id = 101,
            .recording_id = 1,
            .position = 0,
            .length = 0,
        },
    };

    try conductor.enqueueCommand(replay_cmd);
    _ = try conductor.doWork();
    _ = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);

    // Stop replay
    const stop_replay_cmd = Command{
        .stop_replay = StopReplayCmd{
            .correlation_id = 102,
            .replay_session_id = 1,
        },
    };

    try conductor.enqueueCommand(stop_replay_cmd);
    _ = try conductor.doWork();

    try std.testing.expectEqual(1, conductor.responseCount());
}

test "ArchiveConductor list_recordings command" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Start 3 recordings
    const channels = [_][]const u8{
        "aeron:udp://localhost:40121",
        "aeron:udp://localhost:40122",
        "aeron:udp://localhost:40123",
    };
    const source_identities = [_][]const u8{
        "source-1",
        "source-2",
        "source-3",
    };
    for (channels, 0..) |channel, idx| {
        const cmd = Command{
            .start_recording = StartRecordingCmd{
                .correlation_id = @as(i64, @intCast(101 + idx)),
                .session_id = @as(i32, @intCast(idx + 1)),
                .stream_id = @as(i32, @intCast(idx + 1)),
                .channel = channel,
                .source_identity = source_identities[idx],
            },
        };

        try conductor.enqueueCommand(cmd);
    }

    _ = try conductor.doWork();
    _ = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);

    // List recordings
    const list_cmd = Command{
        .list_recordings = ListRecordingsCmd{
            .correlation_id = 200,
            .from_recording_id = 1,
            .record_count = 10,
        },
    };

    try conductor.enqueueCommand(list_cmd);
    _ = try conductor.doWork();

    try std.testing.expectEqual(1, conductor.responseCount());
}

test "ArchiveConductor processes multiple commands in one doWork" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Enqueue 3 commands
    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(channel);
    const source_identity = try allocator.dupe(u8, "test-source");
    defer allocator.free(source_identity);

    const cmd1 = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 100,
            .session_id = 1,
            .stream_id = 2,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    const cmd2 = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 101,
            .session_id = 3,
            .stream_id = 4,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    const cmd3 = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 102,
            .session_id = 5,
            .stream_id = 6,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    try conductor.enqueueCommand(cmd1);
    try conductor.enqueueCommand(cmd2);
    try conductor.enqueueCommand(cmd3);

    const work_count = try conductor.doWork();
    try std.testing.expectEqual(3, work_count);
    try std.testing.expectEqual(3, conductor.responseCount());
}

test "ArchiveConductor pollResponses drains queue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ArchiveConductor.init(allocator);
    try conductor.initRecorder();
    defer conductor.deinit();

    // Enqueue and process commands
    const channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(channel);
    const source_identity = try allocator.dupe(u8, "test-source");
    defer allocator.free(source_identity);

    const cmd1 = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 100,
            .session_id = 1,
            .stream_id = 2,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    const cmd2 = Command{
        .start_recording = StartRecordingCmd{
            .correlation_id = 101,
            .session_id = 3,
            .stream_id = 4,
            .channel = channel,
            .source_identity = source_identity,
        },
    };

    try conductor.enqueueCommand(cmd1);
    try conductor.enqueueCommand(cmd2);
    _ = try conductor.doWork();

    try std.testing.expectEqual(2, conductor.responseCount());

    var count: i32 = 0;
    const handler = struct {
        pub fn handle(_: *const Response) void {}
    }.handle;
    count = conductor.pollResponses(&handler);

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(0, conductor.responseCount());
}
