//! Data types owned by the cluster conductor: session/role state, the
//! command and response payloads routed through ClusterConductor.doWork,
//! and the durable recovery snapshot shape. Kept independent of
//! ClusterConductor itself so they can be shared without pulling in its
//! behavior.

const std = @import("std");
const log_mod = @import("../log.zig");

/// ClusterRole — the current role of this cluster member.
pub const ClusterRole = enum {
    leader,
    follower,
    candidate,
};

/// SessionState — tracks open client session metadata.
pub const SessionState = struct {
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel: []u8,
    is_open: bool = true,
};

/// ClusterConductorState — owned snapshot of conductor recovery state.
pub const ClusterConductorState = struct {
    role: ClusterRole,
    leader_member_id: i32,
    leader_ship_term_id: i64,
    next_session_id: i64,
    commit_position: i64,
    sessions: []SessionState,
    log_state: log_mod.ClusterLogState,

    pub fn deinit(self: *ClusterConductorState, allocator: std.mem.Allocator) void {
        for (self.sessions) |session| {
            allocator.free(session.response_channel);
        }
        allocator.free(self.sessions);
        self.sessions = &.{};
        self.log_state.deinit(allocator);
    }
};

/// SnapshotState — tracks the progress of a local snapshot operation.
pub const SnapshotState = enum {
    none,
    taking,
    completed,
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

/// AddPassiveMemberCmd — add a node to the passive (non-voting) member list.
/// Matches the intent of SBE AddPassiveMember (id=70) from aeron-cluster-codecs.xml.
/// member_endpoints is a borrowed slice in the format "ingress,consensus,log,catchup,archive".
pub const AddPassiveMemberCmd = struct {
    member_id: i32,
    /// Five-endpoint comma-separated string: ingress,consensus,log,catchup,archive.
    /// Not owned by this struct — caller must ensure it outlives the command.
    member_endpoints: []const u8,
};

/// SnapshotBeginCmd — leader signals start of snapshot.
pub const SnapshotBeginCmd = struct {
    leadership_term_id: i64,
    log_position: i64,
    timestamp: i64,
    member_id: i32,
};

/// SnapshotEndCmd — leader signals snapshot is complete.
pub const SnapshotEndCmd = struct {
    leadership_term_id: i64,
    log_position: i64,
    member_id: i32,
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

/// RedirectResponse — notifies client to reconnect to the current leader.
/// Matches Aeron SessionEvent with event_code = redirect (2).
pub const RedirectResponse = struct {
    cluster_session_id: i64,
    correlation_id: i64,
    leader_member_id: i32,
};

/// ActiveMember — per-member data in a ClusterMembersExtendedResponse.
/// Matches the SBE activeMembers group in aeron-cluster-codecs.xml (id=43).
pub const ActiveMember = struct {
    leadership_term_id: i64,
    log_position: i64,
    time_of_last_append_ns: i64,
    member_id: i32,
    ingress_endpoint: []const u8,
    consensus_endpoint: []const u8,
    log_endpoint: []const u8,
    catchup_endpoint: []const u8,
    archive_endpoint: []const u8,

    pub fn deinit(self: *ActiveMember, allocator: std.mem.Allocator) void {
        allocator.free(self.ingress_endpoint);
        allocator.free(self.consensus_endpoint);
        allocator.free(self.log_endpoint);
        allocator.free(self.catchup_endpoint);
        allocator.free(self.archive_endpoint);
    }
};

/// ClusterMembersResponse — in-memory representation of ClusterMembersExtendedResponse.
/// Matches SBE message id=43 in aeron-cluster-codecs.xml (activeMembers + passiveMembers groups).
/// active_members and passive_members are caller-owned; call deinit to free.
pub const ClusterMembersResponse = struct {
    correlation_id: i64,
    current_time_ns: i64,
    leader_member_id: i32,
    member_id: i32,
    active_members: []ActiveMember,
    passive_members: []ActiveMember,

    pub fn deinit(self: *ClusterMembersResponse, allocator: std.mem.Allocator) void {
        for (self.active_members) |*m| m.deinit(allocator);
        allocator.free(self.active_members);
        self.active_members = &.{};
        for (self.passive_members) |*m| m.deinit(allocator);
        allocator.free(self.passive_members);
        self.passive_members = &.{};
    }
};
