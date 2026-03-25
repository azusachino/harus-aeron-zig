// Aeron Cluster protocol codec
// Reference: https://github.com/aeron-io/aeron/tree/master/aeron-cluster/src/main/java/io/aeron/cluster/codecs
// LESSON(cluster-protocol): Cluster messages are divided into Client (session), Consensus (Raft), and Service (delivery) families. See docs/tutorial/06-cluster/01-cluster-protocol.md
// LESSON(cluster-protocol): Using extern structs with explicit _padding fields ensures the 64-bit alignment required for shared memory. See docs/tutorial/06-cluster/01-cluster-protocol.md
const std = @import("std");

pub const EventCode = enum(i32) {
    ok = 0,
    error_val = 1,
    redirect = 2,
    authentication_rejected = 3,
};

pub const ClusterAction = enum(i32) {
    suspend_val = 0,
    resume_val = 1,
    snapshot = 2,
    shutdown = 3,
    abort = 4,
};

// ============================================================================
// Client-facing messages (MSG_TYPE_IDs 201-210)
// ============================================================================

/// SessionConnectRequest — client initiates cluster session connection
// LESSON(cluster-protocol): Clients connect to the cluster via a session. The leader assigns a cluster_session_id. See docs/tutorial/06-cluster/01-cluster-protocol.md
pub const SessionConnectRequest = extern struct {
    correlation_id: i64,
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel_length: i32,
    // Variable-length response_channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(SessionConnectRequest);
    pub const MSG_TYPE_ID: i32 = 201;
};

/// SessionCloseRequest — client closes cluster session
pub const SessionCloseRequest = extern struct {
    cluster_session_id: i64,
    leader_ship_term_id: i64,

    pub const HEADER_LENGTH = @sizeOf(SessionCloseRequest);
    pub const MSG_TYPE_ID: i32 = 202;
};

/// SessionMessageHeader — header for client-to-cluster messages
// LESSON(cluster-protocol): The SessionMessageHeader is prepended to every client message before it is replicated in the Raft log. See docs/tutorial/06-cluster/01-cluster-protocol.md
pub const SessionMessageHeader = extern struct {
    cluster_session_id: i64,
    timestamp: i64,
    correlation_id: i64,

    pub const HEADER_LENGTH = @sizeOf(SessionMessageHeader);
    pub const MSG_TYPE_ID: i32 = 203;
};

/// SessionEvent — notification of session state changes
pub const SessionEvent = extern struct {
    cluster_session_id: i64,
    correlation_id: i64,
    leader_ship_term_id: i64,
    leader_member_id: i32,
    event_code: i32,

    pub const HEADER_LENGTH = @sizeOf(SessionEvent);
    pub const MSG_TYPE_ID: i32 = 204;
};

// ============================================================================
// Cluster-internal consensus messages (MSG_TYPE_IDs 211-220)
// ============================================================================

/// AppendRequestHeader — leader sends log entries to followers
// LESSON(log-replication): AppendRequest is the core of Raft replication. It carries the leader_ship_term_id and log_position. See docs/tutorial/06-cluster/03-log-replication.md
pub const AppendRequestHeader = extern struct {
    leader_ship_term_id: i64,
    log_position: i64,
    timestamp: i64,
    leader_member_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(AppendRequestHeader);
    pub const MSG_TYPE_ID: i32 = 211;
};

/// AppendPositionHeader — follower acknowledges append progress
pub const AppendPositionHeader = extern struct {
    leader_ship_term_id: i64,
    log_position: i64,
    follower_member_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(AppendPositionHeader);
    pub const MSG_TYPE_ID: i32 = 212;
};

/// CommitPositionHeader — leader broadcasts committed log position
// LESSON(log-replication): A message is committed only after a majority of followers have ACK'd its position. See docs/tutorial/06-cluster/03-log-replication.md
pub const CommitPositionHeader = extern struct {
    leader_ship_term_id: i64,
    log_position: i64,
    leader_member_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(CommitPositionHeader);
    pub const MSG_TYPE_ID: i32 = 213;
};

/// RequestVoteHeader — candidate requests votes during election
pub const RequestVoteHeader = extern struct {
    log_leader_ship_term_id: i64,
    log_position: i64,
    candidate_term_id: i64,
    candidate_member_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(RequestVoteHeader);
    pub const MSG_TYPE_ID: i32 = 214;
};

/// VoteHeader — member votes in election
pub const VoteHeader = extern struct {
    candidate_term_id: i64,
    log_leader_ship_term_id: i64,
    log_position: i64,
    candidate_member_id: i32,
    follower_member_id: i32,
    vote: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(VoteHeader);
    pub const MSG_TYPE_ID: i32 = 215;
};

/// NewLeadershipTermHeader — notification of new leadership term
pub const NewLeadershipTermHeader = extern struct {
    log_leader_ship_term_id: i64,
    log_truncate_position: i64,
    leader_ship_term_id: i64,
    log_position: i64,
    timestamp: i64,
    leader_member_id: i32,
    log_session_id: i32,

    pub const HEADER_LENGTH = @sizeOf(NewLeadershipTermHeader);
    pub const MSG_TYPE_ID: i32 = 216;
};

// ============================================================================
// Service-facing messages (MSG_TYPE_IDs 221-230)
// ============================================================================

/// ServiceAck — service acknowledges command execution
pub const ServiceAck = extern struct {
    log_position: i64,
    timestamp: i64,
    ack_id: i64,
    relevant_id: i64,
    service_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(ServiceAck);
    pub const MSG_TYPE_ID: i32 = 221;
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Encode a length-prefixed channel string into buffer.
/// Returns number of bytes written (length prefix + string data).
// LESSON(cluster-protocol): Big-endian or little-endian is handled explicitly with std.mem.writeInt for cross-platform shared memory. See docs/tutorial/06-cluster/01-cluster-protocol.md
pub fn encodeChannel(buf: []u8, channel: []const u8) !usize {
    if (buf.len < 4 + channel.len) {
        return error.BufferTooSmall;
    }
    // Write length as i32 (little-endian)
    const channel_len: i32 = @intCast(channel.len);
    std.mem.writeInt(i32, buf[0..4], channel_len, .little);
    // Write channel string
    @memcpy(buf[4 .. 4 + channel.len], channel);
    return 4 + channel.len;
}

/// Decode a length-prefixed channel string from buffer.
/// Returns a slice into the buffer if valid, null if buffer too small.
pub fn decodeChannel(buf: []const u8) ?[]const u8 {
    if (buf.len < 4) {
        return null;
    }
    const channel_len = std.mem.readInt(i32, buf[0..4], .little);
    if (channel_len < 0 or buf.len < 4 + channel_len) {
        return null;
    }
    return buf[4 .. 4 + @as(usize, @intCast(channel_len))];
}

// ============================================================================
// Compile-time Assertions
// ============================================================================

comptime {
    // Verify MSG_TYPE_IDs are unique
    std.debug.assert(SessionConnectRequest.MSG_TYPE_ID != SessionCloseRequest.MSG_TYPE_ID);
    std.debug.assert(SessionMessageHeader.MSG_TYPE_ID != SessionEvent.MSG_TYPE_ID);
    std.debug.assert(AppendRequestHeader.MSG_TYPE_ID != AppendPositionHeader.MSG_TYPE_ID);
    std.debug.assert(CommitPositionHeader.MSG_TYPE_ID != RequestVoteHeader.MSG_TYPE_ID);
    std.debug.assert(VoteHeader.MSG_TYPE_ID != NewLeadershipTermHeader.MSG_TYPE_ID);
    std.debug.assert(NewLeadershipTermHeader.MSG_TYPE_ID != ServiceAck.MSG_TYPE_ID);

    // Verify EventCode values
    std.debug.assert(@intFromEnum(EventCode.ok) == 0);
    std.debug.assert(@intFromEnum(EventCode.error_val) == 1);
    std.debug.assert(@intFromEnum(EventCode.redirect) == 2);
    std.debug.assert(@intFromEnum(EventCode.authentication_rejected) == 3);

    // Verify ClusterAction values
    std.debug.assert(@intFromEnum(ClusterAction.suspend_val) == 0);
    std.debug.assert(@intFromEnum(ClusterAction.resume_val) == 1);
    std.debug.assert(@intFromEnum(ClusterAction.snapshot) == 2);
    std.debug.assert(@intFromEnum(ClusterAction.shutdown) == 3);
    std.debug.assert(@intFromEnum(ClusterAction.abort) == 4);
}

// ============================================================================
// Tests
// ============================================================================

test "header sizes are correct" {
    try std.testing.expectEqual(@as(usize, 24), SessionConnectRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), SessionCloseRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 24), SessionMessageHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 32), SessionEvent.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 32), AppendRequestHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 24), AppendPositionHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 24), CommitPositionHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 32), RequestVoteHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 40), VoteHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 48), NewLeadershipTermHeader.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 40), ServiceAck.HEADER_LENGTH);
}

test "msg_type_ids are unique" {
    try std.testing.expectEqual(201, SessionConnectRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(202, SessionCloseRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(203, SessionMessageHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(204, SessionEvent.MSG_TYPE_ID);
    try std.testing.expectEqual(211, AppendRequestHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(212, AppendPositionHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(213, CommitPositionHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(214, RequestVoteHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(215, VoteHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(216, NewLeadershipTermHeader.MSG_TYPE_ID);
    try std.testing.expectEqual(221, ServiceAck.MSG_TYPE_ID);
}

test "event code enum values" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(EventCode.ok));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(EventCode.error_val));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(EventCode.redirect));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(EventCode.authentication_rejected));
}

test "cluster action enum values" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ClusterAction.suspend_val));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ClusterAction.resume_val));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(ClusterAction.snapshot));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(ClusterAction.shutdown));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(ClusterAction.abort));
}

test "encodeChannel round-trip" {
    var buf: [256]u8 = undefined;
    const channel = "aeron:udp://localhost:40123";

    const written = try encodeChannel(&buf, channel);
    try std.testing.expectEqual(4 + channel.len, written);

    const decoded = decodeChannel(buf[0..written]);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqualSlices(u8, channel, decoded.?);
}

test "decodeChannel with invalid buffer" {
    try std.testing.expect(decodeChannel("abc") == null);
}

test "session connect request layout" {
    var req: SessionConnectRequest = undefined;
    req.correlation_id = 12345;
    req.cluster_session_id = 67890;
    req.response_stream_id = 1;
    req.response_channel_length = 30;

    try std.testing.expectEqual(@as(i64, 12345), req.correlation_id);
    try std.testing.expectEqual(@as(i64, 67890), req.cluster_session_id);
    try std.testing.expectEqual(@as(i32, 1), req.response_stream_id);
    try std.testing.expectEqual(@as(i32, 30), req.response_channel_length);
}

test "vote header layout" {
    var vote: VoteHeader = undefined;
    vote.candidate_term_id = 1;
    vote.log_leader_ship_term_id = 0;
    vote.log_position = 1000;
    vote.candidate_member_id = 2;
    vote.follower_member_id = 3;
    vote.vote = 1;
    vote._padding = 0;

    try std.testing.expectEqual(@as(i64, 1), vote.candidate_term_id);
    try std.testing.expectEqual(@as(i64, 0), vote.log_leader_ship_term_id);
    try std.testing.expectEqual(@as(i64, 1000), vote.log_position);
    try std.testing.expectEqual(@as(i32, 2), vote.candidate_member_id);
    try std.testing.expectEqual(@as(i32, 3), vote.follower_member_id);
    try std.testing.expectEqual(@as(i32, 1), vote.vote);
}
