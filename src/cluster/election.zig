// Aeron Cluster — Raft leader election state machine
// Manages cluster member state, voting, and leader election transitions.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/Election.java

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Election timeout before transitioning from canvass to candidate ballot
pub const ELECTION_TIMEOUT_NS: i64 = 1_000_000_000; // 1 second

/// Startup canvass timeout for initial discovery
pub const STARTUP_CANVASS_TIMEOUT_NS: i64 = 5_000_000_000; // 5 seconds

/// Leader heartbeat timeout for followers to detect leader failure
pub const LEADER_HEARTBEAT_TIMEOUT_NS: i64 = 500_000_000; // 500ms

// =============================================================================
// ElectionState enum
// =============================================================================

/// ElectionState — the state machine progression for leader election.
pub const ElectionState = enum {
    /// Initial startup state
    init,
    /// Canvassing for existing leader or preparing for election
    canvass,
    /// Running ballot as a candidate
    candidate_ballot,
    /// Waiting for leader election as a follower
    follower_ballot,
    /// Elected leader, replicating log to followers
    leader_log_replication,
    /// Leader ready to accept requests
    leader_ready,
    /// Follower ready to accept leader commands
    follower_ready,
};

// =============================================================================
// MemberState struct
// =============================================================================

/// MemberState — tracks voting state for a cluster member.
pub const MemberState = struct {
    /// Unique member ID in the cluster
    member_id: i32,
    /// Latest known log position from this member
    log_position: i64 = 0,
    /// Latest known leadership term from this member
    leader_ship_term_id: i64 = 0,
    /// Whether this member granted a vote in current ballot
    is_vote_granted: bool = false,
};

// =============================================================================
// Election struct
// =============================================================================

/// Election — Raft election state machine for cluster leader selection.
// LESSON(election): Raft election timeout is randomized per member to avoid split-vote
// deadlocks; a Follower becomes Candidate when its timer fires without a heartbeat.
// See docs/tutorial/06-cluster/02-election.md
pub const Election = struct {
    /// Current election state
    state: ElectionState,
    /// This node's member ID
    member_id: i32,
    /// Current known leader member ID (-1 = unknown)
    leader_member_id: i32,
    /// Term being voted on in candidate ballot
    candidate_term_id: i64,
    /// Current leadership term
    leader_ship_term_id: i64,
    /// This node's current log position
    log_position: i64,
    /// Deadline (in nanoseconds) for current election phase
    election_deadline_ns: i64,
    /// All cluster members with their state
    cluster_members: std.ArrayListUnmanaged(MemberState),
    /// Count of votes received in current ballot
    votes_received: u32,
    /// Memory allocator for heap allocations
    allocator: std.mem.Allocator,

    // =========================================================================
    // Initialization and Cleanup
    // =========================================================================

    /// Initialize a new Election state machine.
    pub fn init(allocator: std.mem.Allocator, member_id: i32, initial_cluster_size: u32) !Election {
        var members = std.ArrayListUnmanaged(MemberState){};
        errdefer members.deinit(allocator);

        var i: u32 = 0;
        while (i < initial_cluster_size) : (i += 1) {
            try members.append(allocator, .{
                .member_id = @intCast(i),
                .log_position = 0,
                .leader_ship_term_id = 0,
                .is_vote_granted = false,
            });
        }

        return Election{
            .state = ElectionState.init,
            .member_id = member_id,
            .leader_member_id = -1,
            .candidate_term_id = 0,
            .leader_ship_term_id = 0,
            .log_position = 0,
            .election_deadline_ns = 0,
            .cluster_members = members,
            .votes_received = 0,
            .allocator = allocator,
        };
    }

    /// Free allocated resources.
    pub fn deinit(self: *Election) void {
        self.cluster_members.deinit(self.allocator);
    }

    // =========================================================================
    // State Accessors
    // =========================================================================

    /// Get current election state.
    pub fn currentState(self: *const Election) ElectionState {
        return self.state;
    }

    /// Get current leader member ID.
    pub fn leaderMemberId(self: *const Election) i32 {
        return self.leader_member_id;
    }

    /// Get current leadership term.
    pub fn leaderShipTermId(self: *const Election) i64 {
        return self.leader_ship_term_id;
    }

    // =========================================================================
    // State Machine
    // =========================================================================

    /// Execute one tick of the election state machine.
    /// Returns 1 if state changed, 0 if no change.
    pub fn doWork(self: *Election, now_ns: i64) i32 {
        const old_state = self.state;

        switch (self.state) {
            ElectionState.init => {
                // Transition to canvass, set initial timeout
                self.state = ElectionState.canvass;
                self.election_deadline_ns = now_ns + STARTUP_CANVASS_TIMEOUT_NS;
            },

            ElectionState.canvass => {
                // Wait for timeout or discovery of leader
                if (now_ns >= self.election_deadline_ns) {
                    // Timeout: start ballot as candidate
                    self.candidate_term_id += 1;
                    self.votes_received = 1; // Vote for self
                    self.state = ElectionState.candidate_ballot;
                    self.election_deadline_ns = now_ns + ELECTION_TIMEOUT_NS;
                }
            },

            ElectionState.candidate_ballot => {
                // Check if we have quorum
                if (self.hasQuorum()) {
                    // Won election: transition to leader
                    self.leader_member_id = self.member_id;
                    self.leader_ship_term_id = self.candidate_term_id;
                    self.state = ElectionState.leader_log_replication;
                    // Immediately advance to leader_ready
                    self.state = ElectionState.leader_ready;
                } else if (now_ns >= self.election_deadline_ns) {
                    // Timeout: restart canvass
                    self.state = ElectionState.canvass;
                    self.election_deadline_ns = now_ns + ELECTION_TIMEOUT_NS;
                }
            },

            ElectionState.follower_ballot => {
                // Wait for leader or timeout
                if (now_ns >= self.election_deadline_ns) {
                    // Timeout: restart canvass
                    self.state = ElectionState.canvass;
                    self.election_deadline_ns = now_ns + ELECTION_TIMEOUT_NS;
                }
            },

            ElectionState.leader_ready => {
                // Stable state, no action
            },

            ElectionState.follower_ready => {
                if (now_ns >= self.election_deadline_ns) {
                    self.state = ElectionState.canvass;
                    self.leader_member_id = -1;
                    self.election_deadline_ns = now_ns + ELECTION_TIMEOUT_NS;
                }
            },

            ElectionState.leader_log_replication => {
                // Should transition immediately to leader_ready in candidate_ballot
                // but if we get here, move to ready
                self.state = ElectionState.leader_ready;
            },
        }

        return if (old_state != self.state) 1 else 0;
    }

    // =========================================================================
    // Vote Handling
    // =========================================================================

    /// Process a RequestVote RPC from a candidate.
    /// Returns true if this node grants the vote.
    // LESSON(election): RequestVote safety rules: grant only if candidate's log is at least
    // as up-to-date as ours, and we haven't voted for a different candidate this term.
    // See docs/tutorial/06-cluster/02-election.md
    pub fn onRequestVote(
        self: *Election,
        candidate_term_id: i64,
        log_leader_ship_term_id: i64,
        log_position: i64,
        candidate_member_id: i32,
    ) bool {
        // Check if candidate has a newer or equal log
        const has_newer_or_equal_log = log_leader_ship_term_id > self.leader_ship_term_id or
            (log_leader_ship_term_id == self.leader_ship_term_id and log_position >= self.log_position);

        // Check if in voteable state
        const can_vote = self.state == ElectionState.init or
            self.state == ElectionState.canvass or
            self.state == ElectionState.candidate_ballot;

        if (has_newer_or_equal_log and can_vote) {
            // Grant vote: become follower, update to candidate's term
            self.state = ElectionState.follower_ballot;
            self.leader_member_id = candidate_member_id;
            self.candidate_term_id = candidate_term_id;
            self.election_deadline_ns = 0; // Will be set by caller
            return true;
        }

        return false;
    }

    /// Process a vote response from a follower.
    /// Increments vote count if conditions are met.
    pub fn onVote(
        self: *Election,
        candidate_term_id: i64,
        candidate_member_id: i32,
        follower_member_id: i32,
        vote: bool,
    ) void {
        _ = follower_member_id; // Unused for now

        // Only count positive votes for our current ballot
        if (vote and
            candidate_term_id == self.candidate_term_id and
            candidate_member_id == self.member_id and
            self.state == ElectionState.candidate_ballot)
        {
            self.votes_received += 1;
        }
    }

    /// Process a NewLeadershipTerm notification from the leader.
    pub fn onNewLeadershipTerm(
        self: *Election,
        leader_ship_term_id: i64,
        log_position: i64,
        leader_member_id: i32,
        now_ns: i64,
    ) void {
        self.state = ElectionState.follower_ready;
        self.leader_ship_term_id = leader_ship_term_id;
        self.log_position = log_position;
        self.leader_member_id = leader_member_id;
        self.election_deadline_ns = now_ns + LEADER_HEARTBEAT_TIMEOUT_NS;
    }

    /// Process a leader heartbeat and extend the follower timeout.
    pub fn onLeaderHeartbeat(
        self: *Election,
        leader_ship_term_id: i64,
        log_position: i64,
        leader_member_id: i32,
        now_ns: i64,
    ) void {
        if (leader_ship_term_id >= self.leader_ship_term_id) {
            self.state = ElectionState.follower_ready;
            self.leader_ship_term_id = leader_ship_term_id;
            self.log_position = log_position;
            self.leader_member_id = leader_member_id;
            self.election_deadline_ns = now_ns + LEADER_HEARTBEAT_TIMEOUT_NS;
        }
    }

    /// Update canvass position from a follower.
    pub fn onCanvassPosition(
        self: *Election,
        log_leader_ship_term_id: i64,
        log_position: i64,
        follower_member_id: i32,
    ) void {
        for (self.cluster_members.items) |*member| {
            if (member.member_id == follower_member_id) {
                member.leader_ship_term_id = log_leader_ship_term_id;
                member.log_position = log_position;
                return;
            }
        }
    }

    /// Add a new member to the cluster if not already present.
    pub fn onDiscoveryMessage(self: *Election, member_id: i32) !void {
        for (self.cluster_members.items) |member| {
            if (member.member_id == member_id) return;
        }
        try self.cluster_members.append(self.allocator, .{
            .member_id = member_id,
        });
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /// Check if we have reached quorum threshold.
    fn hasQuorum(self: *const Election) bool {
        return self.votes_received >= self.quorumThreshold();
    }

    /// Calculate quorum threshold for current cluster size.
    fn quorumThreshold(self: *const Election) u32 {
        const size = self.cluster_members.items.len;
        if (size == 0) return 1;
        return @as(u32, @intCast(@divTrunc(size, 2))) + 1;
    }

    /// Static version for given size.
    fn calculateQuorumThreshold(cluster_size: u32) u32 {
        if (cluster_size == 0) return 1;
        return (cluster_size / 2) + 1;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "election init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    try std.testing.expectEqual(ElectionState.init, election.state);
    try std.testing.expectEqual(@as(i32, -1), election.leader_member_id);
    try std.testing.expectEqual(@as(u32, 0), election.votes_received);
}

test "quorum threshold" {
    // 3-node cluster: threshold should be 2
    const threshold_3 = Election.calculateQuorumThreshold(3);
    try std.testing.expectEqual(@as(u32, 2), threshold_3);

    // 5-node cluster: threshold should be 3
    const threshold_5 = Election.calculateQuorumThreshold(5);
    try std.testing.expectEqual(@as(u32, 3), threshold_5);
}

test "election state machine: init to canvass" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    const changed = election.doWork(1000);
    try std.testing.expectEqual(@as(i32, 1), changed);
    try std.testing.expectEqual(ElectionState.canvass, election.state);
}

test "election state machine: canvass to candidate_ballot" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    // Transition to canvass
    _ = election.doWork(1000);
    try std.testing.expectEqual(ElectionState.canvass, election.state);

    // Let deadline pass to start candidate ballot
    const deadline = election.election_deadline_ns + 1;
    _ = election.doWork(deadline);

    try std.testing.expectEqual(ElectionState.candidate_ballot, election.state);
    try std.testing.expectEqual(@as(u32, 1), election.votes_received); // Vote for self
}

test "election state machine: candidate wins with quorum" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    // Transition to canvass
    _ = election.doWork(1000);

    // Transition to candidate_ballot
    const deadline = election.election_deadline_ns + 1;
    _ = election.doWork(deadline);
    try std.testing.expectEqual(ElectionState.candidate_ballot, election.state);

    // Receive vote from node 1 (now we have 2 votes)
    election.onVote(election.candidate_term_id, election.member_id, 1, true);
    try std.testing.expectEqual(@as(u32, 2), election.votes_received);

    // Run doWork - should achieve quorum and become leader
    _ = election.doWork(deadline + 1000);
    try std.testing.expectEqual(ElectionState.leader_ready, election.state);
    try std.testing.expectEqual(@as(i32, 0), election.leader_member_id);
}

test "onRequestVote grants vote for higher term" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    const granted = election.onRequestVote(
        1, // higher term
        0, // log term
        0, // log position
        1, // candidate
    );

    try std.testing.expectEqual(true, granted);
    try std.testing.expectEqual(ElectionState.follower_ballot, election.state);
    try std.testing.expectEqual(@as(i32, 1), election.leader_member_id);
}

test "onRequestVote rejects stale term" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    // Set current leadership term
    election.leader_ship_term_id = 5;

    const granted = election.onRequestVote(
        3, // lower term
        2, // log term
        100, // log position
        1, // candidate
    );

    try std.testing.expectEqual(false, granted);
    try std.testing.expectEqual(ElectionState.init, election.state); // State unchanged
}

test "onNewLeadershipTerm transitions to follower_ready" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 0, 3);
    defer election.deinit();

    election.onNewLeadershipTerm(5, 1000, 1, 2000);

    try std.testing.expectEqual(ElectionState.follower_ready, election.state);
    try std.testing.expectEqual(@as(i64, 5), election.leader_ship_term_id);
    try std.testing.expectEqual(@as(i64, 1000), election.log_position);
    try std.testing.expectEqual(@as(i32, 1), election.leader_member_id);
    try std.testing.expectEqual(@as(i64, 2000 + LEADER_HEARTBEAT_TIMEOUT_NS), election.election_deadline_ns);
}

test "follower times out leader heartbeat and restarts canvass" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 1, 3);
    defer election.deinit();

    election.onNewLeadershipTerm(5, 1000, 0, 2000);
    try std.testing.expectEqual(ElectionState.follower_ready, election.state);

    const changed = election.doWork(2000 + LEADER_HEARTBEAT_TIMEOUT_NS + 1);
    try std.testing.expectEqual(@as(i32, 1), changed);
    try std.testing.expectEqual(ElectionState.canvass, election.state);
    try std.testing.expectEqual(@as(i32, -1), election.leader_member_id);
}

test "leader heartbeat extends follower deadline" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var election = try Election.init(allocator, 1, 3);
    defer election.deinit();

    election.onNewLeadershipTerm(5, 1000, 0, 2000);
    const original_deadline = election.election_deadline_ns;
    election.onLeaderHeartbeat(5, 1004, 0, 2200);

    try std.testing.expectEqual(ElectionState.follower_ready, election.state);
    try std.testing.expectEqual(@as(i64, 1004), election.log_position);
    try std.testing.expect(election.election_deadline_ns > original_deadline);
}

test "three node election full simulation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create 3-node cluster
    var node0 = try Election.init(allocator, 0, 3);
    defer node0.deinit();
    var node1 = try Election.init(allocator, 1, 3);
    defer node1.deinit();
    var node2 = try Election.init(allocator, 2, 3);
    defer node2.deinit();

    const now = 1000;

    // All nodes transition to canvass
    _ = node0.doWork(now);
    _ = node1.doWork(now);
    _ = node2.doWork(now);

    // Advance past canvass timeout
    const candidate_time = node0.election_deadline_ns + 1;
    _ = node0.doWork(candidate_time);
    _ = node1.doWork(candidate_time);
    _ = node2.doWork(candidate_time);

    // node0 should be in candidate_ballot
    try std.testing.expectEqual(ElectionState.candidate_ballot, node0.state);

    // node1 and node2 should grant votes to node0
    const granted1 = node1.onRequestVote(node0.candidate_term_id, node0.leader_ship_term_id, node0.log_position, 0);
    const granted2 = node2.onRequestVote(node0.candidate_term_id, node0.leader_ship_term_id, node0.log_position, 0);

    try std.testing.expectEqual(true, granted1);
    try std.testing.expectEqual(true, granted2);

    // node0 processes votes from node1 and node2
    node0.onVote(node0.candidate_term_id, 0, 1, true);
    node0.onVote(node0.candidate_term_id, 0, 2, true);

    // node0 should have 3 votes total (1 for self + 1 from node1 + 1 from node2)
    try std.testing.expectEqual(@as(u32, 3), node0.votes_received);

    // doWork should promote to leader (3 > 3/2 = 1.5, so 3 > 1)
    _ = node0.doWork(candidate_time + 100);
    try std.testing.expectEqual(ElectionState.leader_ready, node0.state);
    try std.testing.expectEqual(@as(i32, 0), node0.leader_member_id);
}
