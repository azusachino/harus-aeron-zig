// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ElectionTest.java
// Aeron version: 1.50.2
// Coverage: canvass phase, vote request, vote granted, leader elected

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("log_replication_test.zig");
    _ = @import("failover_test.zig");
}

test "Election: full canvass → candidate → leader flow (3-node)" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 0, 3);
    defer election.deinit();

    const now = 1000;

    // State machine: init → canvass
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.init, election.state);
    _ = election.doWork(now);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.canvass, election.state);

    // canvass → candidate_ballot (after timeout)
    const ballot_time = election.election_deadline_ns + 1;
    _ = election.doWork(ballot_time);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.candidate_ballot, election.state);
    try std.testing.expectEqual(@as(u32, 1), election.votes_received); // Self vote

    // Receive votes from members 1 and 2
    election.onVote(election.candidate_term_id, election.member_id, 1, true);
    try std.testing.expectEqual(@as(u32, 2), election.votes_received);
    election.onVote(election.candidate_term_id, election.member_id, 2, true);
    try std.testing.expectEqual(@as(u32, 3), election.votes_received);

    // Quorum reached: become leader
    _ = election.doWork(ballot_time + 100);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.leader_ready, election.state);
    try std.testing.expectEqual(@as(i32, 0), election.leader_member_id);
}

test "Election: vote rejected for stale term" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 1, 3);
    defer election.deinit();

    // Set current leadership term to 5
    election.leader_ship_term_id = 5;
    election.state = .candidate_ballot;
    election.candidate_term_id = 6;
    election.votes_received = 1;

    // Receive a vote for an older candidate_term_id (3 < 6)
    election.onVote(3, 0, 2, true);

    // Vote should be rejected and not counted
    try std.testing.expectEqual(@as(u32, 1), election.votes_received);
}

test "Election: single-node cluster becomes leader with minimal votes" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 0, 1);
    defer election.deinit();

    try std.testing.expectEqual(@as(usize, 1), election.cluster_members.items.len);

    const now = 1000;
    _ = election.doWork(now);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.canvass, election.state);

    const ballot_time = election.election_deadline_ns + 1;
    _ = election.doWork(ballot_time);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.candidate_ballot, election.state);

    // Single node has self vote, quorum is 1, should immediately achieve it
    _ = election.doWork(ballot_time + 1);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.leader_ready, election.state);
    try std.testing.expectEqual(@as(i32, 0), election.leader_member_id);
}

test "Election: follower receives RequestVote while candidate" {
    const allocator = std.testing.allocator;
    var candidate = try aeron.cluster.election.Election.init(allocator, 0, 3);
    defer candidate.deinit();
    var challenger = try aeron.cluster.election.Election.init(allocator, 1, 3);
    defer challenger.deinit();

    const now = 1000;
    _ = candidate.doWork(now);
    const ballot_time = candidate.election_deadline_ns + 1;
    _ = candidate.doWork(ballot_time);

    try std.testing.expectEqual(aeron.cluster.election.ElectionState.candidate_ballot, candidate.state);

    // Challenger sends RequestVote with higher term
    const granted = candidate.onRequestVote(
        candidate.candidate_term_id + 1,
        candidate.leader_ship_term_id,
        candidate.log_position,
        challenger.member_id,
    );

    // Candidate should accept vote and transition to follower_ballot
    try std.testing.expectEqual(true, granted);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.follower_ballot, candidate.state);
    try std.testing.expectEqual(@as(i32, 1), candidate.leader_member_id);
}

test "Election: onCanvassPosition updates member state" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 0, 3);
    defer election.deinit();

    // Initial state: all members have log_position = 0
    try std.testing.expectEqual(@as(i64, 0), election.cluster_members.items[1].log_position);
    try std.testing.expectEqual(@as(i64, 0), election.cluster_members.items[1].leader_ship_term_id);

    // Update member 1's canvass position
    election.onCanvassPosition(2, 1024, 1);

    // Verify member state is updated
    try std.testing.expectEqual(@as(i64, 1024), election.cluster_members.items[1].log_position);
    try std.testing.expectEqual(@as(i64, 2), election.cluster_members.items[1].leader_ship_term_id);
}
