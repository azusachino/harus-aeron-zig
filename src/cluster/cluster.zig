// Aeron Cluster — top-level ConsensusModule owning Election, Log, and Conductor
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModule.java

const std = @import("std");
const election_mod = @import("election.zig");
const log_mod = @import("log.zig");
const conductor_mod = @import("conductor.zig");

// =============================================================================
// MemberConfig
// =============================================================================

/// MemberConfig — configuration for a single cluster member.
pub const MemberConfig = struct {
    member_id: i32,
    host: []const u8 = "localhost",
    client_port: u16 = 9010,
    consensus_port: u16 = 9020,
    log_port: u16 = 9030,
};

// =============================================================================
// ClusterContext — Configuration
// =============================================================================

/// ClusterContext — configuration for an Aeron Cluster node.
pub const ClusterContext = struct {
    /// This node's unique member ID.
    member_id: i32,
    /// Configuration for all cluster members.
    cluster_members: []const MemberConfig = &.{},
    /// Channel for client ingress.
    ingress_channel: []const u8 = "aeron:udp?endpoint=localhost:9010",
    /// Stream ID for client ingress.
    ingress_stream_id: i32 = 100,
    /// Channel for log replication between nodes.
    log_channel: []const u8 = "aeron:udp?endpoint=localhost:9020",
    /// Stream ID for log replication.
    log_stream_id: i32 = 101,
    /// Channel for consensus (election, heartbeat) messages.
    consensus_channel: []const u8 = "aeron:udp?endpoint=localhost:9030",
    /// Stream ID for consensus.
    consensus_stream_id: i32 = 102,
};

// =============================================================================
// ConsensusModule
// =============================================================================

/// ConsensusModule — top-level context owning Election, ClusterLog, and ClusterConductor.
/// Manages the lifecycle of a cluster node and drives duty cycles.
pub const ConsensusModule = struct {
    allocator: std.mem.Allocator,
    ctx: ClusterContext,
    election: election_mod.Election,
    log: log_mod.ClusterLog,
    conductor: conductor_mod.ClusterConductor,
    is_running: bool = false,

    /// Initialize a new ConsensusModule with the given allocator and context.
    pub fn init(allocator: std.mem.Allocator, ctx: ClusterContext) !ConsensusModule {
        const cluster_size: u32 = if (ctx.cluster_members.len > 0)
            @intCast(ctx.cluster_members.len)
        else
            1;

        return ConsensusModule{
            .allocator = allocator,
            .ctx = ctx,
            .election = try election_mod.Election.init(allocator, ctx.member_id, cluster_size),
            .log = log_mod.ClusterLog.init(allocator),
            .conductor = conductor_mod.ClusterConductor.init(allocator, ctx.member_id),
            .is_running = false,
        };
    }

    /// Free all resources.
    pub fn deinit(self: *ConsensusModule) void {
        self.conductor.deinit();
        self.log.deinit();
        self.election.deinit();
    }

    /// Start the consensus module.
    pub fn start(self: *ConsensusModule) void {
        self.is_running = true;
    }

    /// Stop the consensus module.
    pub fn stop(self: *ConsensusModule) void {
        self.is_running = false;
    }

    /// Check if the module is running.
    pub fn isRunning(self: *const ConsensusModule) bool {
        return self.is_running;
    }

    /// Run one duty cycle of the consensus module.
    /// Drives election, then conductor. Returns total work count.
    pub fn doWork(self: *ConsensusModule, now_ns: i64) !i32 {
        if (!self.is_running) {
            return 0;
        }

        var work_count: i32 = 0;

        // Drive election state machine
        work_count += self.election.doWork(now_ns);

        // Sync election result to conductor
        if (self.election.currentState() == election_mod.ElectionState.leader_ready and
            self.conductor.role != conductor_mod.ClusterRole.leader)
        {
            self.conductor.becomeLeader(self.election.leaderShipTermId());
        } else if (self.election.currentState() == election_mod.ElectionState.follower_ready and
            self.conductor.role != conductor_mod.ClusterRole.follower)
        {
            self.conductor.becomeFollower(
                self.election.leaderMemberId(),
                self.election.leaderShipTermId(),
            );
        }

        // Drive conductor
        work_count += try self.conductor.doWork();

        return work_count;
    }

    /// Enqueue a command for the conductor.
    pub fn enqueueCommand(self: *ConsensusModule, cmd: conductor_mod.Command) !void {
        try self.conductor.enqueueCommand(cmd);
    }

    /// Poll and deliver all queued responses.
    pub fn pollResponses(self: *ConsensusModule, handler: *const fn (response: *const conductor_mod.Response) void) i32 {
        return self.conductor.pollResponses(handler);
    }

    /// Return the current cluster role.
    pub fn role(self: *const ConsensusModule) conductor_mod.ClusterRole {
        return self.conductor.role;
    }

    /// Return the current leader member ID.
    pub fn leaderMemberId(self: *const ConsensusModule) i32 {
        return self.election.leaderMemberId();
    }

    /// Return the current leadership term.
    pub fn leaderShipTermId(self: *const ConsensusModule) i64 {
        return self.election.leaderShipTermId();
    }

    /// Return the election state.
    pub fn electionState(self: *const ConsensusModule) election_mod.ElectionState {
        return self.election.currentState();
    }

    /// Return a copy of the context.
    pub fn context(self: *const ConsensusModule) ClusterContext {
        return self.ctx;
    }
};

// =============================================================================
// Re-exports
// =============================================================================

pub const Command = conductor_mod.Command;
pub const Response = conductor_mod.Response;
pub const SessionConnectCmd = conductor_mod.SessionConnectCmd;
pub const SessionCloseCmd = conductor_mod.SessionCloseCmd;
pub const SessionMessageCmd = conductor_mod.SessionMessageCmd;
pub const ClusterRole = conductor_mod.ClusterRole;
pub const ElectionState = election_mod.ElectionState;

// =============================================================================
// Tests
// =============================================================================

test "ClusterContext has sensible defaults" {
    const ctx = ClusterContext{ .member_id = 0 };
    try std.testing.expectEqualStrings("aeron:udp?endpoint=localhost:9010", ctx.ingress_channel);
    try std.testing.expectEqual(@as(i32, 100), ctx.ingress_stream_id);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=localhost:9020", ctx.log_channel);
    try std.testing.expectEqual(@as(i32, 101), ctx.log_stream_id);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=localhost:9030", ctx.consensus_channel);
    try std.testing.expectEqual(@as(i32, 102), ctx.consensus_stream_id);
}

test "ConsensusModule init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ClusterContext{ .member_id = 0 };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();

    try std.testing.expect(!module.isRunning());
    try std.testing.expectEqual(ClusterRole.follower, module.role());
    try std.testing.expectEqual(@as(i32, -1), module.leaderMemberId());
}

test "ConsensusModule start and stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ClusterContext{ .member_id = 0 };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();

    try std.testing.expect(!module.isRunning());

    module.start();
    try std.testing.expect(module.isRunning());

    module.stop();
    try std.testing.expect(!module.isRunning());
}

test "ConsensusModule doWork returns 0 when not running" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ClusterContext{ .member_id = 0 };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();

    const work_count = try module.doWork(1000);
    try std.testing.expectEqual(@as(i32, 0), work_count);
}

test "ConsensusModule election drives role transition" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };
    const ctx = ClusterContext{
        .member_id = 0,
        .cluster_members = &members,
    };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();
    module.start();

    // Drive through init → canvass
    _ = try module.doWork(1000);
    try std.testing.expectEqual(ElectionState.canvass, module.electionState());

    // Drive past canvass timeout → candidate_ballot
    const deadline = module.election.election_deadline_ns + 1;
    _ = try module.doWork(deadline);
    try std.testing.expectEqual(ElectionState.candidate_ballot, module.electionState());

    // Simulate receiving votes from node 1 and node 2
    module.election.onVote(module.election.candidate_term_id, 0, 1, true);
    module.election.onVote(module.election.candidate_term_id, 0, 2, true);

    // Drive — should become leader, conductor should sync to leader role
    _ = try module.doWork(deadline + 100);
    try std.testing.expectEqual(ElectionState.leader_ready, module.electionState());
    try std.testing.expectEqual(ClusterRole.leader, module.role());
    try std.testing.expectEqual(@as(i32, 0), module.leaderMemberId());
}

test "ConsensusModule follower role on new leadership term" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ClusterContext{ .member_id = 1 };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();
    module.start();

    // Receive notification of new leader (node 0)
    module.election.onNewLeadershipTerm(1, 0, 0);

    // Drive — conductor should sync to follower role
    _ = try module.doWork(1000);
    try std.testing.expectEqual(ElectionState.follower_ready, module.electionState());
    try std.testing.expectEqual(ClusterRole.follower, module.role());
    try std.testing.expectEqual(@as(i32, 0), module.leaderMemberId());
}

test "ConsensusModule end-to-end: election, connect, message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };
    const ctx = ClusterContext{
        .member_id = 0,
        .cluster_members = &members,
    };
    var module = try ConsensusModule.init(allocator, ctx);
    defer module.deinit();
    module.start();

    // Drive election to leader
    _ = try module.doWork(1000);
    const deadline = module.election.election_deadline_ns + 1;
    _ = try module.doWork(deadline);
    module.election.onVote(module.election.candidate_term_id, 0, 1, true);
    _ = try module.doWork(deadline + 100);
    try std.testing.expectEqual(ClusterRole.leader, module.role());

    // Connect a session
    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40123");
    defer allocator.free(response_channel);

    try module.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 100,
            .cluster_session_id = 1,
            .response_stream_id = 1,
            .response_channel = response_channel,
        },
    });
    _ = try module.doWork(deadline + 200);

    const noop = struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle;
    const connect_responses = module.pollResponses(&noop);
    try std.testing.expectEqual(@as(i32, 1), connect_responses);

    // Send a message (as leader)
    const data = try allocator.dupe(u8, "hello cluster");
    defer allocator.free(data);

    try module.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = deadline + 300,
            .data = data,
        },
    });
    _ = try module.doWork(deadline + 300);

    const msg_responses = module.pollResponses(&noop);
    try std.testing.expectEqual(@as(i32, 1), msg_responses);
}
