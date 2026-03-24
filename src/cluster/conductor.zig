// Aeron Cluster Conductor — session management and log replication
// Routes cluster commands from clients to distributed log and session state.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/ClusterConductor.java

const std = @import("std");
const log_mod = @import("log.zig");

// =============================================================================
// Role Enum
// =============================================================================

/// ClusterRole — the current role of this cluster member.
pub const ClusterRole = enum {
    leader,
    follower,
    candidate,
};

// =============================================================================
// Session State
// =============================================================================

/// SessionState — tracks open client session metadata.
pub const SessionState = struct {
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel: []const u8,
    is_open: bool = true,
};

// =============================================================================
// Command Payloads
// =============================================================================

/// SessionConnectCmd — parameters for opening a new client session.
pub const SessionConnectCmd = struct {
    correlation_id: i64,
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel: []const u8,
};

/// SessionCloseCmd — parameters for closing a client session.
pub const SessionCloseCmd = struct {
    cluster_session_id: i64,
};

/// SessionMessageCmd — a message from client to be committed to log.
pub const SessionMessageCmd = struct {
    cluster_session_id: i64,
    timestamp: i64,
    data: []const u8,
};

/// AppendPositionCmd — replication message from leader to follower.
pub const AppendPositionCmd = struct {
    leader_ship_term_id: i64,
    log_position: i64,
    follower_member_id: i32,
};

/// CommitPositionCmd — commit notification from leader to followers.
pub const CommitPositionCmd = struct {
    leader_ship_term_id: i64,
    log_position: i64,
};

// =============================================================================
// Command Union
// =============================================================================

/// Command — union of all possible cluster control commands.
pub const Command = union(enum) {
    session_connect: SessionConnectCmd,
    session_close: SessionCloseCmd,
    session_message: SessionMessageCmd,
    append_position: AppendPositionCmd,
    commit_position: CommitPositionCmd,
};

// =============================================================================
// Response Payloads
// =============================================================================

/// SessionEventResponse — notifies client of session state change.
pub const SessionEventResponse = struct {
    cluster_session_id: i64,
    correlation_id: i64,
    event_code: i32,
};

/// ErrorResponse — notifies client of error.
pub const ErrorResponse = struct {
    correlation_id: i64,
    error_code: i32,
    message: []const u8,
};

/// CommitPositionResponse — confirms log position committed on leader.
pub const CommitPositionResponse = struct {
    leader_ship_term_id: i64,
    log_position: i64,
};

// =============================================================================
// Response Union
// =============================================================================

/// Response — union of all possible cluster responses.
pub const Response = union(enum) {
    session_event: SessionEventResponse,
    error_response: ErrorResponse,
    commit_position: CommitPositionResponse,
};

// =============================================================================
// ClusterConductor
// =============================================================================

/// ClusterConductor — manages cluster sessions, log replication, and role transitions.
pub const ClusterConductor = struct {
    allocator: std.mem.Allocator,
    role: ClusterRole,
    member_id: i32,
    leader_member_id: i32,
    leader_ship_term_id: i64,
    log: log_mod.ClusterLog,
    command_queue: std.ArrayList(Command),
    response_queue: std.ArrayList(Response),
    sessions: std.ArrayList(SessionState),
    next_session_id: i64,
    commit_position: i64,

    /// Initialize a new ClusterConductor.
    pub fn init(allocator: std.mem.Allocator, member_id: i32) ClusterConductor {
        return ClusterConductor{
            .allocator = allocator,
            .role = .follower,
            .member_id = member_id,
            .leader_member_id = -1,
            .leader_ship_term_id = 0,
            .log = log_mod.ClusterLog.init(allocator),
            .command_queue = .{},
            .response_queue = .{},
            .sessions = .{},
            .next_session_id = 1,
            .commit_position = 0,
        };
    }

    /// Free all conductor resources.
    pub fn deinit(self: *ClusterConductor) void {
        self.command_queue.deinit(self.allocator);
        self.response_queue.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.log.deinit();
    }

    /// Enqueue a command for processing.
    pub fn enqueueCommand(self: *ClusterConductor, cmd: Command) !void {
        try self.command_queue.append(self.allocator, cmd);
    }

    /// Process one command from queue and queue its response.
    /// Returns 1 if a command was processed, 0 if queue is empty.
    pub fn doWork(self: *ClusterConductor) !i32 {
        if (self.command_queue.pop()) |cmd| {
            try self.processCommand(cmd);
            return 1;
        }
        return 0;
    }

    /// Process a single command and queue its response.
    fn processCommand(self: *ClusterConductor, cmd: Command) !void {
        switch (cmd) {
            .session_connect => |connect_cmd| {
                try self.handleSessionConnect(connect_cmd);
            },
            .session_close => |close_cmd| {
                try self.handleSessionClose(close_cmd);
            },
            .session_message => |msg_cmd| {
                try self.handleSessionMessage(msg_cmd);
            },
            .append_position => |append_cmd| {
                try self.handleAppendPosition(append_cmd);
            },
            .commit_position => |commit_cmd| {
                try self.handleCommitPosition(commit_cmd);
            },
        }
    }

    /// Handle session_connect command.
    fn handleSessionConnect(self: *ClusterConductor, cmd: SessionConnectCmd) !void {
        const session = SessionState{
            .cluster_session_id = self.next_session_id,
            .response_stream_id = cmd.response_stream_id,
            .response_channel = cmd.response_channel,
            .is_open = true,
        };
        try self.sessions.append(self.allocator, session);
        self.next_session_id += 1;

        const response = Response{
            .session_event = SessionEventResponse{
                .cluster_session_id = session.cluster_session_id,
                .correlation_id = cmd.correlation_id,
                .event_code = 0, // OK
            },
        };
        try self.response_queue.append(self.allocator, response);
    }

    /// Handle session_close command.
    fn handleSessionClose(self: *ClusterConductor, cmd: SessionCloseCmd) !void {
        // Mark session as closed
        for (self.sessions.items) |*session| {
            if (session.cluster_session_id == cmd.cluster_session_id) {
                session.is_open = false;
                break;
            }
        }

        const response = Response{
            .session_event = SessionEventResponse{
                .cluster_session_id = cmd.cluster_session_id,
                .correlation_id = 0,
                .event_code = 1, // CLOSED
            },
        };
        try self.response_queue.append(self.allocator, response);
    }

    /// Handle session_message command.
    fn handleSessionMessage(self: *ClusterConductor, cmd: SessionMessageCmd) !void {
        if (self.role == .leader) {
            _ = try self.log.append(cmd.data, cmd.timestamp);
            self.log.advanceCommitPosition(self.log.appendPosition());
            self.commit_position = self.log.commitPosition();
            const response = Response{
                .commit_position = CommitPositionResponse{
                    .leader_ship_term_id = self.leader_ship_term_id,
                    .log_position = self.commit_position,
                },
            };
            try self.response_queue.append(self.allocator, response);
        } else {
            // Follower: reject, not leader
            const response = Response{
                .error_response = ErrorResponse{
                    .correlation_id = 0,
                    .error_code = 1,
                    .message = "not leader",
                },
            };
            try self.response_queue.append(self.allocator, response);
        }
    }

    /// Handle append_position command.
    fn handleAppendPosition(self: *ClusterConductor, cmd: AppendPositionCmd) !void {
        // Update internal replication tracking (no response for append)
        if (cmd.leader_ship_term_id > self.leader_ship_term_id) {
            self.leader_ship_term_id = cmd.leader_ship_term_id;
        }
    }

    /// Handle commit_position command.
    fn handleCommitPosition(self: *ClusterConductor, cmd: CommitPositionCmd) !void {
        self.log.advanceCommitPosition(cmd.log_position);
        self.commit_position = self.log.commitPosition();
    }

    /// Drain and deliver all queued responses.
    /// Calls handler for each response, then clears the queue.
    /// Returns the number of responses delivered.
    pub fn pollResponses(self: *ClusterConductor, handler: *const fn (response: *const Response) void) i32 {
        var count: i32 = 0;
        for (self.response_queue.items) |*response| {
            handler(response);
            count += 1;
        }
        self.response_queue.clearRetainingCapacity();
        return count;
    }

    /// Transition to leader role.
    pub fn becomeLeader(self: *ClusterConductor, term_id: i64) void {
        self.role = .leader;
        self.leader_member_id = self.member_id;
        self.leader_ship_term_id = term_id;
    }

    /// Transition to follower role.
    pub fn becomeFollower(self: *ClusterConductor, leader_id: i32, term_id: i64) void {
        self.role = .follower;
        self.leader_member_id = leader_id;
        self.leader_ship_term_id = term_id;
    }

    /// Return the number of open sessions.
    pub fn sessionCount(self: *const ClusterConductor) usize {
        return self.sessions.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "conductor init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    try std.testing.expectEqual(ClusterRole.follower, conductor.role);
    try std.testing.expectEqual(0, conductor.member_id);
    try std.testing.expectEqual(-1, conductor.leader_member_id);
    try std.testing.expectEqual(0, conductor.commit_position);
    try std.testing.expectEqual(0, conductor.sessionCount());
}

test "session connect and close" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(response_channel);

    // Connect session
    const connect_cmd = Command{
        .session_connect = SessionConnectCmd{
            .correlation_id = 100,
            .cluster_session_id = 1,
            .response_stream_id = 1,
            .response_channel = response_channel,
        },
    };

    try conductor.enqueueCommand(connect_cmd);
    const work_count = try conductor.doWork();
    try std.testing.expectEqual(1, work_count);
    try std.testing.expectEqual(1, conductor.sessionCount());

    const Capture = struct {
        pub var response_received: bool = false;
    };
    Capture.response_received = false;
    const handler = struct {
        pub fn handle(response: *const Response) void {
            if (response.* == .session_event) {
                Capture.response_received = response.session_event.correlation_id == 100 and
                    response.session_event.event_code == 0;
            }
        }
    };
    _ = conductor.pollResponses(&handler.handle);
    try std.testing.expect(Capture.response_received);

    // Close session
    const close_cmd = Command{
        .session_close = SessionCloseCmd{
            .cluster_session_id = 1,
        },
    };

    try conductor.enqueueCommand(close_cmd);
    _ = try conductor.doWork();
    try std.testing.expectEqual(1, conductor.sessionCount());

    Capture.response_received = false;
    _ = conductor.pollResponses(&handler.handle);
}

test "session message as leader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    conductor.becomeLeader(1);

    const data = try allocator.dupe(u8, "test message");
    defer allocator.free(data);

    const msg_cmd = Command{
        .session_message = SessionMessageCmd{
            .cluster_session_id = 1,
            .timestamp = 0,
            .data = data,
        },
    };

    try conductor.enqueueCommand(msg_cmd);
    _ = try conductor.doWork();

    const CaptureCommit = struct {
        pub var commit_response_received: bool = false;
    };
    CaptureCommit.commit_response_received = false;
    const handler = struct {
        pub fn handle(response: *const Response) void {
            if (response.* == .commit_position) {
                CaptureCommit.commit_response_received = true;
            }
        }
    };
    _ = conductor.pollResponses(&handler.handle);
    try std.testing.expect(CaptureCommit.commit_response_received);
    try std.testing.expectEqual(@as(i64, 12), conductor.log.appendPosition());
    try std.testing.expectEqual(@as(i64, 12), conductor.commit_position);
    try std.testing.expectEqualSlices(u8, "test message", conductor.log.entryAt(0).?.data);
}

test "session message as follower rejects" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    // Conductor is follower by default
    try std.testing.expectEqual(ClusterRole.follower, conductor.role);

    const data = try allocator.dupe(u8, "test message");
    defer allocator.free(data);

    const msg_cmd = Command{
        .session_message = SessionMessageCmd{
            .cluster_session_id = 1,
            .timestamp = 0,
            .data = data,
        },
    };

    try conductor.enqueueCommand(msg_cmd);
    _ = try conductor.doWork();

    const CaptureError = struct {
        pub var error_response_received: bool = false;
    };
    CaptureError.error_response_received = false;
    const handler = struct {
        pub fn handle(response: *const Response) void {
            if (response.* == .error_response) {
                CaptureError.error_response_received = response.error_response.error_code == 1;
            }
        }
    };
    _ = conductor.pollResponses(&handler.handle);
    try std.testing.expect(CaptureError.error_response_received);
}

test "become leader and follower" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    try std.testing.expectEqual(ClusterRole.follower, conductor.role);

    conductor.becomeLeader(1);
    try std.testing.expectEqual(ClusterRole.leader, conductor.role);
    try std.testing.expectEqual(0, conductor.leader_member_id);
    try std.testing.expectEqual(1, conductor.leader_ship_term_id);

    conductor.becomeFollower(1, 2);
    try std.testing.expectEqual(ClusterRole.follower, conductor.role);
    try std.testing.expectEqual(1, conductor.leader_member_id);
    try std.testing.expectEqual(2, conductor.leader_ship_term_id);
}

test "commit position advance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    try std.testing.expectEqual(0, conductor.commit_position);

    _ = try conductor.log.append("entry", 100);

    const commit_cmd = Command{
        .commit_position = CommitPositionCmd{
            .leader_ship_term_id = 1,
            .log_position = 5,
        },
    };

    try conductor.enqueueCommand(commit_cmd);
    _ = try conductor.doWork();
    try std.testing.expectEqual(5, conductor.commit_position);
    try std.testing.expectEqual(5, conductor.log.commitPosition());
}

test "multiple sessions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(response_channel);

    for (0..3) |i| {
        const connect_cmd = Command{
            .session_connect = SessionConnectCmd{
                .correlation_id = @as(i64, @intCast(100 + i)),
                .cluster_session_id = @as(i64, @intCast(i + 1)),
                .response_stream_id = @as(i32, @intCast(i + 1)),
                .response_channel = response_channel,
            },
        };
        try conductor.enqueueCommand(connect_cmd);
        _ = try conductor.doWork();
    }

    try std.testing.expectEqual(3, conductor.sessionCount());
}

test "poll responses clears queue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(response_channel);

    // Connect 2 sessions
    for (0..2) |i| {
        const connect_cmd = Command{
            .session_connect = SessionConnectCmd{
                .correlation_id = @as(i64, @intCast(100 + i)),
                .cluster_session_id = @as(i64, @intCast(i + 1)),
                .response_stream_id = @as(i32, @intCast(i + 1)),
                .response_channel = response_channel,
            },
        };
        try conductor.enqueueCommand(connect_cmd);
        _ = try conductor.doWork();
    }

    // First poll should return 2 responses
    var count = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);
    try std.testing.expectEqual(2, count);

    // Second poll should return 0 responses (queue was cleared)
    count = conductor.pollResponses(&struct {
        pub fn handle(_: *const Response) void {}
    }.handle);
    try std.testing.expectEqual(0, count);
}
