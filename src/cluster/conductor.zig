// Aeron Cluster Conductor — session management and log replication
// Routes cluster commands from clients to distributed log and session state.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/ClusterConductor.java
//
// Types live in conductor/types.zig, snapshot take/load/serialize in
// conductor/snapshot.zig, and peer/member-list handling in
// conductor/members.zig — this file owns the ClusterConductor struct and
// its core command-processing loop.

const protocol_mod = @import("protocol.zig");
const QueryMemberList = protocol_mod.QueryMemberList;

const std = @import("std");
const log_mod = @import("log.zig");
const archive_mod = @import("../archive/archive.zig");
const types = @import("conductor/types.zig");
const snapshot = @import("conductor/snapshot.zig");
const members = @import("conductor/members.zig");

pub const ClusterRole = types.ClusterRole;
pub const SessionState = types.SessionState;
pub const ClusterConductorState = types.ClusterConductorState;
pub const SnapshotState = types.SnapshotState;
pub const SessionConnectCmd = types.SessionConnectCmd;
pub const SessionCloseCmd = types.SessionCloseCmd;
pub const SessionMessageCmd = types.SessionMessageCmd;
pub const AppendPositionCmd = types.AppendPositionCmd;
pub const CommitPositionCmd = types.CommitPositionCmd;
pub const AddPassiveMemberCmd = types.AddPassiveMemberCmd;
pub const SnapshotBeginCmd = types.SnapshotBeginCmd;
pub const SnapshotEndCmd = types.SnapshotEndCmd;
pub const SessionEventResponse = types.SessionEventResponse;
pub const ErrorResponse = types.ErrorResponse;
pub const CommitPositionResponse = types.CommitPositionResponse;
pub const RedirectResponse = types.RedirectResponse;
pub const ActiveMember = types.ActiveMember;
pub const ClusterMembersResponse = types.ClusterMembersResponse;

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
    snapshot_begin: SnapshotBeginCmd,
    snapshot_end: SnapshotEndCmd,
    add_passive_member: AddPassiveMemberCmd,
    query_member_list: QueryMemberList,
    admin_catchup: struct {
        leader_state: *const ClusterConductor,
    },
};

// =============================================================================
// Response Union
// =============================================================================

/// Response — union of all possible cluster responses.
pub const Response = union(enum) {
    session_event: SessionEventResponse,
    error_response: ErrorResponse,
    commit_position: CommitPositionResponse,
    redirect: RedirectResponse,
    member_list: ClusterMembersResponse,
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
    snapshot_state: SnapshotState = .none,
    /// Captured conductor state at snapshot begin; null when no snapshot in progress.
    pending_snapshot: ?ClusterConductorState = null,
    /// Known active peers (voting members except self). Populated from config at init or via addPeer.
    peers: std.ArrayList(ActiveMember) = .empty,
    /// Known passive peers (non-voting members). Populated via add_passive_member commands.
    passive_peers: std.ArrayList(ActiveMember) = .empty,
    archive: ?*archive_mod.Archive = null,

    /// Initialize a new ClusterConductor.
    pub fn init(allocator: std.mem.Allocator, member_id: i32) ClusterConductor {
        return ClusterConductor{
            .allocator = allocator,
            .role = .follower,
            .member_id = member_id,
            .leader_member_id = -1,
            .leader_ship_term_id = 0,
            .log = log_mod.ClusterLog.init(allocator),
            .command_queue = .empty,
            .response_queue = .empty,
            .sessions = .empty,
            .next_session_id = 1,
            .commit_position = 0,
            .snapshot_state = .none,
        };
    }

    /// Register a known peer member. Replaces any existing entry for the same member_id.
    pub fn addPeer(self: *ClusterConductor, peer: ActiveMember) !void {
        try members.addPeer(self, peer);
    }

    /// Add peers from a static clusterMemberEndpoints string.
    /// Format: "0,ingress:port,consensus:port,log:port,catchup:port,archive:port|1,..."
    pub fn addPeersFromConfig(self: *ClusterConductor, endpoints_string: []const u8) !void {
        try members.addPeersFromConfig(self, endpoints_string);
    }

    /// Free all conductor resources.
    pub fn deinit(self: *ClusterConductor) void {
        if (self.pending_snapshot) |*snap| snap.deinit(self.allocator);
        self.pending_snapshot = null;
        self.clearSessions();
        for (self.peers.items) |*p| p.deinit(self.allocator);
        self.peers.deinit(self.allocator);
        for (self.passive_peers.items) |*p| p.deinit(self.allocator);
        self.passive_peers.deinit(self.allocator);
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
            .snapshot_begin => |snapshot_cmd| {
                try self.handleSnapshotBegin(snapshot_cmd);
            },
            .snapshot_end => |snapshot_cmd| {
                try self.handleSnapshotEnd(snapshot_cmd);
            },
            .add_passive_member => |add_passive_cmd| {
                try self.handleAddPassiveMember(add_passive_cmd);
            },
            .query_member_list => |query_cmd| {
                try self.handleQueryMemberList(query_cmd);
            },
            .admin_catchup => |catchup_cmd| {
                try self.catchUpFromLeader(catchup_cmd.leader_state);
            },
        }
    }

    /// Handle session_connect command.
    /// If this node is not the leader, emit a redirect response pointing to the
    /// current known leader rather than accepting the session.
    fn handleSessionConnect(self: *ClusterConductor, cmd: SessionConnectCmd) !void {
        if (self.role != .leader) {
            // Redirect client to the current leader
            const response = Response{
                .redirect = RedirectResponse{
                    .cluster_session_id = cmd.cluster_session_id,
                    .correlation_id = cmd.correlation_id,
                    .leader_member_id = self.leader_member_id,
                },
            };
            try self.response_queue.append(self.allocator, response);
            return;
        }

        const session = SessionState{
            .cluster_session_id = self.next_session_id,
            .response_stream_id = cmd.response_stream_id,
            .response_channel = try self.allocator.dupe(u8, cmd.response_channel),
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

    /// Handle snapshot_begin command.
    /// Mark snapshot in progress and capture current conductor state.
    pub fn handleSnapshotBegin(self: *ClusterConductor, cmd: SnapshotBeginCmd) !void {
        try snapshot.handleBegin(self, cmd);
    }

    /// Handle snapshot_end command.
    /// Snapshot complete — clear pending snapshot and resume normal operation.
    pub fn handleSnapshotEnd(self: *ClusterConductor, cmd: SnapshotEndCmd) !void {
        try snapshot.handleEnd(self, cmd);
    }

    /// Load the last successful snapshot from the Archive, if wired up.
    pub fn loadLastSnapshot(self: *ClusterConductor) !void {
        try snapshot.loadLast(self);
    }

    /// Handle add_passive_member command.
    pub fn handleAddPassiveMember(self: *ClusterConductor, cmd: AddPassiveMemberCmd) !void {
        try members.handleAddPassiveMember(self, cmd);
    }

    /// Handle query_member_list command.
    pub fn handleQueryMemberList(self: *ClusterConductor, cmd: QueryMemberList) !void {
        try members.handleQueryMemberList(self, cmd);
    }

    /// Drain and deliver all queued responses.
    /// Calls handler for each response, then clears the queue.
    /// Returns the number of responses delivered.
    pub fn pollResponses(self: *ClusterConductor, handler: *const fn (response: *const Response) void) i32 {
        var count: i32 = 0;
        for (self.response_queue.items) |*response| {
            handler(response);
            if (response.* == .member_list) response.member_list.deinit(self.allocator);
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

    /// Transition to follower role and emit redirect responses to all open sessions
    /// so that clients know to reconnect to the new leader.
    pub fn becomeFollower(self: *ClusterConductor, leader_id: i32, term_id: i64) void {
        const was_leader = self.role == .leader;
        self.role = .follower;
        self.leader_member_id = leader_id;
        self.leader_ship_term_id = term_id;
        if (was_leader) {
            self.notifySessionsRedirect(leader_id) catch {};
        }
    }

    /// Emit redirect responses for all open sessions, directing clients to new_leader_id.
    pub fn notifySessionsRedirect(self: *ClusterConductor, new_leader_id: i32) !void {
        for (self.sessions.items) |*session| {
            if (session.is_open) {
                try self.response_queue.append(self.allocator, .{
                    .redirect = RedirectResponse{
                        .cluster_session_id = session.cluster_session_id,
                        .correlation_id = 0,
                        .leader_member_id = new_leader_id,
                    },
                });
            }
        }
    }

    /// Replace local replicated state with a leader snapshot while preserving local identity.
    pub fn catchUpFromLeader(self: *ClusterConductor, leader: *const ClusterConductor) !void {
        var state = try leader.captureState(self.allocator);
        defer state.deinit(self.allocator);

        try self.restoreState(&state);
        self.role = .follower;
        self.leader_member_id = leader.member_id;
        self.leader_ship_term_id = leader.leader_ship_term_id;
    }

    /// Capture all durable conductor state for restart or handoff.
    pub fn captureState(self: *const ClusterConductor, allocator: std.mem.Allocator) !ClusterConductorState {
        var sessions = try allocator.alloc(SessionState, self.sessions.items.len);
        var copied: usize = 0;
        errdefer {
            for (sessions[0..copied]) |session| {
                allocator.free(session.response_channel);
            }
            allocator.free(sessions);
        }

        for (self.sessions.items, 0..) |session, idx| {
            sessions[idx] = .{
                .cluster_session_id = session.cluster_session_id,
                .response_stream_id = session.response_stream_id,
                .response_channel = try allocator.dupe(u8, session.response_channel),
                .is_open = session.is_open,
            };
            copied += 1;
        }

        const log_state = try self.log.captureState(allocator);
        errdefer {
            var mutable_log_state = log_state;
            mutable_log_state.deinit(allocator);
        }

        return .{
            .role = self.role,
            .leader_member_id = self.leader_member_id,
            .leader_ship_term_id = self.leader_ship_term_id,
            .next_session_id = self.next_session_id,
            .commit_position = self.commit_position,
            .sessions = sessions,
            .log_state = log_state,
        };
    }

    /// Restore durable conductor state and clear transient queues.
    pub fn restoreState(self: *ClusterConductor, state: *const ClusterConductorState) !void {
        self.command_queue.clearRetainingCapacity();
        self.response_queue.clearRetainingCapacity();
        self.clearSessions();

        self.role = state.role;
        self.leader_member_id = state.leader_member_id;
        self.leader_ship_term_id = state.leader_ship_term_id;
        self.next_session_id = state.next_session_id;
        self.commit_position = state.commit_position;
        try self.log.restoreState(&state.log_state);

        for (state.sessions) |session| {
            try self.sessions.append(self.allocator, .{
                .cluster_session_id = session.cluster_session_id,
                .response_stream_id = session.response_stream_id,
                .response_channel = try self.allocator.dupe(u8, session.response_channel),
                .is_open = session.is_open,
            });
        }
    }

    /// Serialize durable conductor state into a recovery blob. See conductor/snapshot.zig.
    pub fn serializeState(self: *const ClusterConductor, allocator: std.mem.Allocator) ![]u8 {
        return snapshot.serialize(self, allocator);
    }

    /// Parse a blob produced by `serializeState`. See conductor/snapshot.zig.
    pub fn deserializeState(allocator: std.mem.Allocator, bytes: []const u8) !ClusterConductorState {
        return snapshot.deserialize(allocator, bytes);
    }

    /// Recover conductor state from a serialized snapshot blob. See conductor/snapshot.zig.
    pub fn loadSnapshot(self: *ClusterConductor, bytes: []const u8) !void {
        try snapshot.load(self, bytes);
    }

    /// Return the number of open sessions.
    pub fn sessionCount(self: *const ClusterConductor) usize {
        return self.sessions.items.len;
    }

    fn clearSessions(self: *ClusterConductor) void {
        for (self.sessions.items) |session| {
            self.allocator.free(session.response_channel);
        }
        self.sessions.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "conductor init" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    // Must be leader to accept session connects
    conductor.becomeLeader(1);

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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    // Must be leader to accept session connects
    conductor.becomeLeader(1);

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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    // Must be leader to accept session connects
    conductor.becomeLeader(1);

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

test "conductor catch up from leader preserves replicated state" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var leader = ClusterConductor.init(allocator, 0);
    defer leader.deinit();
    leader.becomeLeader(3);

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(response_channel);
    try leader.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 10,
            .cluster_session_id = 1,
            .response_stream_id = 7,
            .response_channel = response_channel,
        },
    });
    _ = try leader.doWork();
    leader.response_queue.clearRetainingCapacity();

    const data = try allocator.dupe(u8, "replicated");
    defer allocator.free(data);
    try leader.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = 1000,
            .data = data,
        },
    });
    _ = try leader.doWork();
    leader.response_queue.clearRetainingCapacity();

    var follower = ClusterConductor.init(allocator, 1);
    defer follower.deinit();
    follower.becomeFollower(0, 3);

    try follower.catchUpFromLeader(&leader);

    try std.testing.expectEqual(ClusterRole.follower, follower.role);
    try std.testing.expectEqual(@as(i32, 0), follower.leader_member_id);
    try std.testing.expectEqual(leader.commit_position, follower.commit_position);
    try std.testing.expectEqual(leader.log.appendPosition(), follower.log.appendPosition());
    try std.testing.expectEqual(@as(usize, 1), follower.sessionCount());
    try std.testing.expectEqualSlices(u8, "replicated", follower.log.entryAt(0).?.data);
}

test "conductor state round trip restores leader progress" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 2);
    defer conductor.deinit();
    conductor.becomeLeader(5);

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40124");
    defer allocator.free(response_channel);
    try conductor.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 11,
            .cluster_session_id = 1,
            .response_stream_id = 8,
            .response_channel = response_channel,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    const data = try allocator.dupe(u8, "resume");
    defer allocator.free(data);
    try conductor.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = 2000,
            .data = data,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    var state = try conductor.captureState(allocator);
    defer state.deinit(allocator);

    var restored = ClusterConductor.init(allocator, 2);
    defer restored.deinit();
    try restored.restoreState(&state);

    try std.testing.expectEqual(ClusterRole.leader, restored.role);
    try std.testing.expectEqual(@as(i64, 5), restored.leader_ship_term_id);
    try std.testing.expectEqual(conductor.log.appendPosition(), restored.log.appendPosition());
    try std.testing.expectEqual(conductor.commit_position, restored.commit_position);
    try std.testing.expectEqual(conductor.next_session_id, restored.next_session_id);
    try std.testing.expectEqual(@as(usize, 1), restored.sessionCount());
    try std.testing.expectEqualSlices(u8, "resume", restored.log.entryAt(0).?.data);
}

test "serializeState round trips through loadSnapshot" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 2);
    defer conductor.deinit();
    conductor.becomeLeader(5);

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40124");
    defer allocator.free(response_channel);
    try conductor.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 11,
            .cluster_session_id = 1,
            .response_stream_id = 8,
            .response_channel = response_channel,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    const data = try allocator.dupe(u8, "resume");
    defer allocator.free(data);
    try conductor.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = 2000,
            .data = data,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    const blob = try conductor.serializeState(allocator);
    defer allocator.free(blob);

    var restored = ClusterConductor.init(allocator, 2);
    defer restored.deinit();
    try restored.loadSnapshot(blob);

    try std.testing.expectEqual(ClusterRole.leader, restored.role);
    try std.testing.expectEqual(@as(i64, 5), restored.leader_ship_term_id);
    try std.testing.expectEqual(conductor.log.appendPosition(), restored.log.appendPosition());
    try std.testing.expectEqual(conductor.commit_position, restored.commit_position);
    try std.testing.expectEqual(conductor.next_session_id, restored.next_session_id);
    try std.testing.expectEqual(@as(usize, 1), restored.sessionCount());
    try std.testing.expectEqualSlices(u8, "aeron:udp://localhost:40124", restored.sessions.items[0].response_channel);
    try std.testing.expectEqualSlices(u8, "resume", restored.log.entryAt(0).?.data);
}

test "ClusterConductor auto-wired snapshot round trip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try std.fmt.allocPrint(allocator, "/tmp/aeron-cluster-snapshot-test-{d}", .{@import("../time.zig").nanoTimestamp()});
    defer allocator.free(archive_dir);
    const io_mod = @import("../io.zig");
    try std.Io.Dir.cwd().createDirPath(io_mod.io(), archive_dir);
    defer std.Io.Dir.cwd().deleteTree(io_mod.io(), archive_dir) catch {};

    const ctx = archive_mod.ArchiveContext{ .archive_dir = archive_dir };
    var archive = try archive_mod.Archive.init(allocator, ctx);
    defer archive.deinit();

    var conductor = ClusterConductor.init(allocator, 2);
    defer conductor.deinit();
    conductor.archive = &archive;
    conductor.becomeLeader(5);

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40124");
    defer allocator.free(response_channel);
    try conductor.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 11,
            .cluster_session_id = 1,
            .response_stream_id = 8,
            .response_channel = response_channel,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    const data = try allocator.dupe(u8, "resume");
    defer allocator.free(data);
    try conductor.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = 2000,
            .data = data,
        },
    });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    // Trigger snapshot
    try conductor.handleSnapshotBegin(.{
        .leadership_term_id = 5,
        .log_position = conductor.log.appendPosition(),
        .timestamp = 2000,
        .member_id = 2,
    });

    // Create a new conductor instance and restore state
    var restored = ClusterConductor.init(allocator, 2);
    defer restored.deinit();
    restored.archive = &archive;

    try restored.loadLastSnapshot();

    try std.testing.expectEqual(ClusterRole.leader, restored.role);
    try std.testing.expectEqual(@as(i64, 5), restored.leader_ship_term_id);
    try std.testing.expectEqual(conductor.log.appendPosition(), restored.log.appendPosition());
    try std.testing.expectEqual(conductor.commit_position, restored.commit_position);
    try std.testing.expectEqual(conductor.next_session_id, restored.next_session_id);
    try std.testing.expectEqual(@as(usize, 1), restored.sessionCount());
    try std.testing.expectEqualSlices(u8, "aeron:udp://localhost:40124", restored.sessions.items[0].response_channel);
    try std.testing.expectEqualSlices(u8, "resume", restored.log.entryAt(0).?.data);
}

test "deserializeState rejects an empty log and preserves an empty snapshot" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    const blob = try conductor.serializeState(allocator);
    defer allocator.free(blob);

    var state = try ClusterConductor.deserializeState(allocator, blob);
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), state.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), state.log_state.entries.len);
    try std.testing.expectEqual(ClusterRole.leader, state.role);
}

test "deserializeState rejects bad magic and truncation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    const blob = try conductor.serializeState(allocator);
    defer allocator.free(blob);

    // Corrupt the magic prefix.
    const bad_magic = try allocator.dupe(u8, blob);
    defer allocator.free(bad_magic);
    bad_magic[0] ^= 0xFF;
    try std.testing.expectError(error.InvalidSnapshotMagic, ClusterConductor.deserializeState(allocator, bad_magic));

    // A blob cut short of a full header must fail cleanly, not panic.
    try std.testing.expectError(error.SnapshotTruncated, ClusterConductor.deserializeState(allocator, blob[0 .. blob.len - 1]));
}

test "follower redirects session_connect to leader" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 1);
    defer conductor.deinit();
    conductor.becomeFollower(0, 3); // node 0 is leader, term 3

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40200");
    defer allocator.free(response_channel);

    try conductor.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 55,
            .cluster_session_id = 10,
            .response_stream_id = 7,
            .response_channel = response_channel,
        },
    });
    _ = try conductor.doWork();

    // Follower must not create a session locally
    try std.testing.expectEqual(@as(usize, 0), conductor.sessionCount());

    // Must emit a redirect pointing to leader 0
    const CaptureRedirect = struct {
        pub var got_redirect: bool = false;
        pub var redirected_to: i32 = -1;
        pub var corr_id: i64 = -1;
    };
    CaptureRedirect.got_redirect = false;
    _ = conductor.pollResponses(&struct {
        pub fn handle(response: *const Response) void {
            if (response.* == .redirect) {
                CaptureRedirect.got_redirect = true;
                CaptureRedirect.redirected_to = response.redirect.leader_member_id;
                CaptureRedirect.corr_id = response.redirect.correlation_id;
            }
        }
    }.handle);
    try std.testing.expect(CaptureRedirect.got_redirect);
    try std.testing.expectEqual(@as(i32, 0), CaptureRedirect.redirected_to);
    try std.testing.expectEqual(@as(i64, 55), CaptureRedirect.corr_id);
}

test "leader-to-follower transition emits redirect for open sessions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    // Open two sessions while leader
    const rc1 = try allocator.dupe(u8, "aeron:udp://localhost:40201");
    defer allocator.free(rc1);
    const rc2 = try allocator.dupe(u8, "aeron:udp://localhost:40202");
    defer allocator.free(rc2);

    try conductor.enqueueCommand(.{ .session_connect = .{ .correlation_id = 1, .cluster_session_id = 1, .response_stream_id = 1, .response_channel = rc1 } });
    _ = try conductor.doWork();
    try conductor.enqueueCommand(.{ .session_connect = .{ .correlation_id = 2, .cluster_session_id = 2, .response_stream_id = 2, .response_channel = rc2 } });
    _ = try conductor.doWork();
    conductor.response_queue.clearRetainingCapacity();

    // Become follower (new leader = node 2)
    conductor.becomeFollower(2, 2);

    // Should have emitted 2 redirect responses
    const CaptureLeaderChange = struct {
        pub var redirect_count: i32 = 0;
        pub var all_point_to_node2: bool = true;
    };
    CaptureLeaderChange.redirect_count = 0;
    CaptureLeaderChange.all_point_to_node2 = true;
    _ = conductor.pollResponses(&struct {
        pub fn handle(response: *const Response) void {
            if (response.* == .redirect) {
                CaptureLeaderChange.redirect_count += 1;
                if (response.redirect.leader_member_id != 2) {
                    CaptureLeaderChange.all_point_to_node2 = false;
                }
            }
        }
    }.handle);
    try std.testing.expectEqual(@as(i32, 2), CaptureLeaderChange.redirect_count);
    try std.testing.expect(CaptureLeaderChange.all_point_to_node2);
}

test "snapshot state machine transitions" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    try std.testing.expectEqual(SnapshotState.none, conductor.snapshot_state);

    try conductor.enqueueCommand(.{ .snapshot_begin = .{ .leadership_term_id = 1, .log_position = 0, .timestamp = 0, .member_id = 0 } });
    _ = try conductor.doWork();
    try std.testing.expectEqual(SnapshotState.taking, conductor.snapshot_state);

    try conductor.enqueueCommand(.{ .snapshot_end = .{ .leadership_term_id = 1, .log_position = 0, .member_id = 0 } });
    _ = try conductor.doWork();
    try std.testing.expectEqual(SnapshotState.completed, conductor.snapshot_state);
}

test "handleSnapshotBegin captures pending snapshot state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    try std.testing.expect(conductor.pending_snapshot == null);

    try conductor.handleSnapshotBegin(.{ .leadership_term_id = 1, .log_position = 0, .timestamp = 0, .member_id = 0 });
    try std.testing.expectEqual(SnapshotState.taking, conductor.snapshot_state);
    try std.testing.expect(conductor.pending_snapshot != null);

    try conductor.handleSnapshotEnd(.{ .leadership_term_id = 1, .log_position = 0, .member_id = 0 });
    try std.testing.expectEqual(SnapshotState.completed, conductor.snapshot_state);
    try std.testing.expect(conductor.pending_snapshot == null);
}

test "handleQueryMemberList returns self in single-node cluster" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    try conductor.handleQueryMemberList(.{ .correlation_id = 42, .member_id = 0, ._padding = 0 });

    const Capture = struct {
        pub var active_count: usize = 0;
        pub var first_member_id: i32 = -1;
    };
    _ = conductor.pollResponses(&struct {
        pub fn handle(resp: *const Response) void {
            if (resp.* == .member_list) {
                Capture.active_count = resp.member_list.active_members.len;
                if (resp.member_list.active_members.len > 0)
                    Capture.first_member_id = resp.member_list.active_members[0].member_id;
            }
        }
    }.handle);
    try std.testing.expectEqual(@as(usize, 1), Capture.active_count);
    try std.testing.expectEqual(@as(i32, 0), Capture.first_member_id);
}

test "query_member_list command dispatches through doWork" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    try conductor.enqueueCommand(.{ .query_member_list = .{ .correlation_id = 7, .member_id = 0, ._padding = 0 } });
    try std.testing.expectEqual(@as(i32, 1), try conductor.doWork());

    const Capture = struct {
        pub var count: usize = 0;
    };
    Capture.count = 0;
    _ = conductor.pollResponses(&struct {
        pub fn handle(resp: *const Response) void {
            if (resp.* == .member_list) Capture.count = resp.member_list.active_members.len;
        }
    }.handle);
    try std.testing.expectEqual(@as(usize, 1), Capture.count);
}

test "handleQueryMemberList returns all members in 3-node cluster" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    try conductor.addPeer(.{
        .leadership_term_id = 1,
        .log_position = 0,
        .time_of_last_append_ns = 0,
        .member_id = 1,
        .ingress_endpoint = try allocator.dupe(u8, "localhost:20111"),
        .consensus_endpoint = try allocator.dupe(u8, "localhost:20112"),
        .log_endpoint = try allocator.dupe(u8, "localhost:20113"),
        .catchup_endpoint = try allocator.dupe(u8, "localhost:20114"),
        .archive_endpoint = try allocator.dupe(u8, "localhost:20115"),
    });
    try conductor.addPeer(.{
        .leadership_term_id = 1,
        .log_position = 0,
        .time_of_last_append_ns = 0,
        .member_id = 2,
        .ingress_endpoint = try allocator.dupe(u8, "localhost:20121"),
        .consensus_endpoint = try allocator.dupe(u8, "localhost:20122"),
        .log_endpoint = try allocator.dupe(u8, "localhost:20123"),
        .catchup_endpoint = try allocator.dupe(u8, "localhost:20124"),
        .archive_endpoint = try allocator.dupe(u8, "localhost:20125"),
    });

    try conductor.handleQueryMemberList(.{ .correlation_id = 99, .member_id = 0, ._padding = 0 });

    const Capture = struct {
        pub var active_count: usize = 0;
    };
    _ = conductor.pollResponses(&struct {
        pub fn handle(resp: *const Response) void {
            if (resp.* == .member_list)
                Capture.active_count = resp.member_list.active_members.len;
        }
    }.handle);
    try std.testing.expectEqual(@as(usize, 3), Capture.active_count);
}

test "admin_catchup command restores state from leader" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var leader = ClusterConductor.init(allocator, 0);
    defer leader.deinit();
    leader.becomeLeader(5);
    _ = try leader.log.append("leader entry", 1000);

    var follower = ClusterConductor.init(allocator, 1);
    defer follower.deinit();

    try follower.enqueueCommand(.{ .admin_catchup = .{ .leader_state = &leader } });
    _ = try follower.doWork();

    try std.testing.expectEqual(leader.commit_position, follower.commit_position);
    try std.testing.expectEqualSlices(u8, "leader entry", follower.log.entryAt(0).?.data);
}

test "addPeersFromConfig parses endpoints string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();

    const config = "0,ing0,con0,log0,catch0,arch0|1,ing1,con1,log1,catch1,arch1|2,ing2,con2,log2,catch2,arch2";
    try conductor.addPeersFromConfig(config);

    // Should skip self (0) and add 1 and 2
    try std.testing.expectEqual(@as(usize, 2), conductor.peers.items.len);

    const peer1 = conductor.peers.items[0];
    try std.testing.expectEqual(@as(i32, 1), peer1.member_id);
    try std.testing.expectEqualStrings("ing1", peer1.ingress_endpoint);
    try std.testing.expectEqualStrings("con1", peer1.consensus_endpoint);
    try std.testing.expectEqualStrings("log1", peer1.log_endpoint);
    try std.testing.expectEqualStrings("catch1", peer1.catchup_endpoint);
    try std.testing.expectEqualStrings("arch1", peer1.archive_endpoint);

    const peer2 = conductor.peers.items[1];
    try std.testing.expectEqual(@as(i32, 2), peer2.member_id);
    try std.testing.expectEqualStrings("ing2", peer2.ingress_endpoint);
    try std.testing.expectEqualStrings("con2", peer2.consensus_endpoint);
}

test "handleAddPassiveMember updates passive list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        std.debug.assert(check == .ok);
    }
    const allocator = gpa.allocator();

    var conductor = ClusterConductor.init(allocator, 0);
    defer conductor.deinit();
    conductor.becomeLeader(1);

    try conductor.enqueueCommand(.{
        .add_passive_member = .{
            .member_id = 99,
            .member_endpoints = "ing99,con99,log99,catch99,arch99",
        },
    });
    _ = try conductor.doWork();

    try std.testing.expectEqual(@as(usize, 1), conductor.passive_peers.items.len);
    const peer = conductor.passive_peers.items[0];
    try std.testing.expectEqual(@as(i32, 99), peer.member_id);
    try std.testing.expectEqualStrings("ing99", peer.ingress_endpoint);
    try std.testing.expectEqualStrings("con99", peer.consensus_endpoint);
    try std.testing.expectEqualStrings("arch99", peer.archive_endpoint);

    // Add another passive member
    try conductor.enqueueCommand(.{
        .add_passive_member = .{
            .member_id = 100,
            .member_endpoints = "ing100,con100,log100,catch100,arch100",
        },
    });
    _ = try conductor.doWork();

    try std.testing.expectEqual(@as(usize, 2), conductor.passive_peers.items.len);

    // Test updating an existing passive member
    try conductor.enqueueCommand(.{
        .add_passive_member = .{
            .member_id = 99,
            .member_endpoints = "new_ing,new_con,new_log,new_catch,new_arch",
        },
    });
    _ = try conductor.doWork();

    try std.testing.expectEqual(@as(usize, 2), conductor.passive_peers.items.len);
    const updated_peer = conductor.passive_peers.items[0];
    try std.testing.expectEqual(@as(i32, 99), updated_peer.member_id);
    try std.testing.expectEqualStrings("new_ing", updated_peer.ingress_endpoint);
}
