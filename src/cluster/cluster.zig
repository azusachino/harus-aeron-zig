// Aeron Cluster — top-level ConsensusModule owning Election, Log, and Conductor
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModule.java

const std = @import("std");
const election_mod = @import("election.zig");
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

/// ElectionSnapshot — owned copy of election state for restart continuity.
pub const ElectionSnapshot = struct {
    state: election_mod.ElectionState,
    leader_member_id: i32,
    candidate_term_id: i64,
    leader_ship_term_id: i64,
    log_position: i64,
    election_deadline_ns: i64,
    votes_received: u32,
    cluster_members: []election_mod.MemberState,

    pub fn deinit(self: *ElectionSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.cluster_members);
        self.cluster_members = &.{};
    }
};

/// ConsensusModuleState — durable cluster state for restart and failover tests.
pub const ConsensusModuleState = struct {
    is_running: bool,
    election: ElectionSnapshot,
    conductor: conductor_mod.ClusterConductorState,

    pub fn deinit(self: *ConsensusModuleState, allocator: std.mem.Allocator) void {
        self.election.deinit(allocator);
        self.conductor.deinit(allocator);
    }
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
            .conductor = conductor_mod.ClusterConductor.init(allocator, ctx.member_id),
            .is_running = false,
        };
    }

    /// Free all resources.
    pub fn deinit(self: *ConsensusModule) void {
        self.conductor.deinit();
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

    /// Refresh follower state from the current leader without changing local member identity.
    pub fn catchUpFromLeader(self: *ConsensusModule, leader: *const ConsensusModule, now_ns: i64) !void {
        self.election.onLeaderHeartbeat(
            leader.leaderShipTermId(),
            leader.conductor.log.appendPosition(),
            leader.leaderMemberId(),
            now_ns,
        );
        try self.conductor.catchUpFromLeader(&leader.conductor);
    }

    /// Capture restart state for the consensus module.
    pub fn captureState(self: *const ConsensusModule, allocator: std.mem.Allocator) !ConsensusModuleState {
        const members = try allocator.dupe(election_mod.MemberState, self.election.cluster_members);
        errdefer allocator.free(members);

        return .{
            .is_running = self.is_running,
            .election = .{
                .state = self.election.state,
                .leader_member_id = self.election.leader_member_id,
                .candidate_term_id = self.election.candidate_term_id,
                .leader_ship_term_id = self.election.leader_ship_term_id,
                .log_position = self.election.log_position,
                .election_deadline_ns = self.election.election_deadline_ns,
                .votes_received = self.election.votes_received,
                .cluster_members = members,
            },
            .conductor = try self.conductor.captureState(allocator),
        };
    }

    /// Restore a previously captured restart state.
    pub fn restoreState(self: *ConsensusModule, state: *const ConsensusModuleState) !void {
        if (state.election.cluster_members.len != self.election.cluster_members.len) {
            return error.ClusterMembershipMismatch;
        }

        self.is_running = state.is_running;
        self.election.state = state.election.state;
        self.election.leader_member_id = state.election.leader_member_id;
        self.election.candidate_term_id = state.election.candidate_term_id;
        self.election.leader_ship_term_id = state.election.leader_ship_term_id;
        self.election.log_position = state.election.log_position;
        self.election.election_deadline_ns = state.election.election_deadline_ns;
        self.election.votes_received = state.election.votes_received;
        @memcpy(self.election.cluster_members, state.election.cluster_members);
        try self.conductor.restoreState(&state.conductor);
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
    module.election.onNewLeadershipTerm(1, 0, 0, 1000);

    // Drive — conductor should sync to follower role
    _ = try module.doWork(1000);
    try std.testing.expectEqual(ElectionState.follower_ready, module.electionState());
    try std.testing.expectEqual(ClusterRole.follower, module.role());
    try std.testing.expectEqual(@as(i32, 0), module.leaderMemberId());
}

test "ConsensusModule follower heartbeat timeout triggers failover election" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var node0 = try ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &members,
    });
    defer node0.deinit();
    var node1 = try ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &members,
    });
    defer node1.deinit();
    var node2 = try ConsensusModule.init(allocator, .{
        .member_id = 2,
        .cluster_members = &members,
    });
    defer node2.deinit();

    node0.start();
    node1.start();
    node2.start();

    _ = try node0.doWork(1000);
    const election_deadline = node0.election.election_deadline_ns + 1;
    _ = try node0.doWork(election_deadline);
    node0.election.onVote(node0.election.candidate_term_id, 0, 1, true);
    _ = try node0.doWork(election_deadline + 100);
    try std.testing.expectEqual(ClusterRole.leader, node0.role());

    const leader_term = node0.leaderShipTermId();
    node1.election.onNewLeadershipTerm(leader_term, 0, 0, election_deadline + 100);
    node2.election.onNewLeadershipTerm(leader_term, 0, 0, election_deadline + 100);
    _ = try node1.doWork(election_deadline + 101);
    _ = try node2.doWork(election_deadline + 101);
    try std.testing.expectEqual(ClusterRole.follower, node1.role());
    try std.testing.expectEqual(ClusterRole.follower, node2.role());

    node0.stop();

    const failover_time = election_deadline + 100 + election_mod.LEADER_HEARTBEAT_TIMEOUT_NS + 1;
    _ = try node1.doWork(failover_time);
    _ = try node2.doWork(failover_time);
    try std.testing.expectEqual(ElectionState.canvass, node1.electionState());
    try std.testing.expectEqual(ElectionState.canvass, node2.electionState());

    const node1_ballot_time = node1.election.election_deadline_ns + 1;
    _ = try node1.doWork(node1_ballot_time);
    _ = try node2.doWork(node1_ballot_time);
    try std.testing.expectEqual(ElectionState.candidate_ballot, node1.electionState());

    const granted = node2.election.onRequestVote(
        node1.election.candidate_term_id,
        node1.election.leaderShipTermId(),
        node1.election.log_position,
        1,
    );
    try std.testing.expect(granted);

    node1.election.onVote(node1.election.candidate_term_id, 1, 2, true);
    _ = try node1.doWork(node1_ballot_time + 100);
    try std.testing.expectEqual(ElectionState.leader_ready, node1.electionState());
    try std.testing.expectEqual(ClusterRole.leader, node1.role());
    try std.testing.expectEqual(@as(i32, 1), node1.leaderMemberId());
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
    try std.testing.expectEqual(@as(i64, @intCast(data.len)), module.conductor.log.appendPosition());
    try std.testing.expectEqual(@as(i64, @intCast(data.len)), module.conductor.log.commitPosition());
    try std.testing.expectEqualSlices(u8, "hello cluster", module.conductor.log.entryAt(0).?.data);
}

test "ConsensusModule follower catch up preserves progress through failover" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var leader = try ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &members,
    });
    defer leader.deinit();
    var follower = try ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &members,
    });
    defer follower.deinit();
    var voter = try ConsensusModule.init(allocator, .{
        .member_id = 2,
        .cluster_members = &members,
    });
    defer voter.deinit();

    leader.start();
    follower.start();
    voter.start();

    _ = try leader.doWork(1000);
    const ballot_time = leader.election.election_deadline_ns + 1;
    _ = try leader.doWork(ballot_time);
    leader.election.onVote(leader.election.candidate_term_id, 0, 1, true);
    _ = try leader.doWork(ballot_time + 100);
    try std.testing.expectEqual(ClusterRole.leader, leader.role());

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40125");
    defer allocator.free(response_channel);
    try leader.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 20,
            .cluster_session_id = 1,
            .response_stream_id = 9,
            .response_channel = response_channel,
        },
    });
    _ = try leader.doWork(ballot_time + 200);
    _ = leader.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    const payload = try allocator.dupe(u8, "failover");
    defer allocator.free(payload);
    try leader.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = ballot_time + 300,
            .data = payload,
        },
    });
    _ = try leader.doWork(ballot_time + 300);
    _ = leader.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    const catch_up_time = ballot_time + 310;
    try follower.catchUpFromLeader(&leader, catch_up_time);
    try std.testing.expectEqual(leader.conductor.log.appendPosition(), follower.conductor.log.appendPosition());
    try std.testing.expectEqual(leader.conductor.commit_position, follower.conductor.commit_position);
    try std.testing.expectEqual(@as(usize, 1), follower.conductor.sessionCount());

    leader.stop();

    const failover_time = catch_up_time + election_mod.LEADER_HEARTBEAT_TIMEOUT_NS + 1;
    _ = try follower.doWork(failover_time);
    try std.testing.expectEqual(ElectionState.canvass, follower.electionState());

    const follower_ballot_time = follower.election.election_deadline_ns + 1;
    _ = try follower.doWork(follower_ballot_time);
    const granted = voter.election.onRequestVote(
        follower.election.candidate_term_id,
        follower.election.leaderShipTermId(),
        follower.election.log_position,
        1,
    );
    try std.testing.expect(granted);
    follower.election.onVote(follower.election.candidate_term_id, 1, 2, true);
    _ = try follower.doWork(follower_ballot_time + 100);
    try std.testing.expectEqual(ClusterRole.leader, follower.role());

    const payload_two = try allocator.dupe(u8, "resume");
    defer allocator.free(payload_two);
    try follower.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = follower_ballot_time + 200,
            .data = payload_two,
        },
    });
    _ = try follower.doWork(follower_ballot_time + 200);
    _ = follower.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    try std.testing.expectEqualSlices(u8, "failover", follower.conductor.log.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "resume", follower.conductor.log.entryAt(8).?.data);
}

test "ConsensusModule state round trip survives restart" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };
    var module = try ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &members,
    });
    defer module.deinit();
    module.start();

    _ = try module.doWork(1000);
    const ballot_time = module.election.election_deadline_ns + 1;
    _ = try module.doWork(ballot_time);
    module.election.onVote(module.election.candidate_term_id, 0, 1, true);
    _ = try module.doWork(ballot_time + 100);

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40126");
    defer allocator.free(response_channel);
    try module.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 30,
            .cluster_session_id = 1,
            .response_stream_id = 10,
            .response_channel = response_channel,
        },
    });
    _ = try module.doWork(ballot_time + 200);
    _ = module.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    const first = try allocator.dupe(u8, "persist");
    defer allocator.free(first);
    try module.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = ballot_time + 300,
            .data = first,
        },
    });
    _ = try module.doWork(ballot_time + 300);
    _ = module.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    var state = try module.captureState(allocator);
    defer state.deinit(allocator);

    var restored = try ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &members,
    });
    defer restored.deinit();
    try restored.restoreState(&state);

    try std.testing.expect(restored.isRunning());
    try std.testing.expectEqual(module.role(), restored.role());
    try std.testing.expectEqual(module.leaderShipTermId(), restored.leaderShipTermId());
    try std.testing.expectEqual(module.conductor.log.appendPosition(), restored.conductor.log.appendPosition());
    try std.testing.expectEqual(@as(usize, 1), restored.conductor.sessionCount());

    const second = try allocator.dupe(u8, "again");
    defer allocator.free(second);
    try restored.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = ballot_time + 400,
            .data = second,
        },
    });
    _ = try restored.doWork(ballot_time + 400);
    _ = restored.pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);

    try std.testing.expectEqualSlices(u8, "persist", restored.conductor.log.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "again", restored.conductor.log.entryAt(7).?.data);
}
