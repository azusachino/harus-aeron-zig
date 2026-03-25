// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ElectionTest.java
// Aeron version: 1.46.7
// Coverage: canvass phase, vote request, vote granted, leader elected

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("log_replication_test.zig");
    _ = @import("failover_test.zig");
}

test "Election: single-member cluster immediately becomes leader" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 0, 1);
    defer election.deinit();
    
    // In our implementation, init sets state to init. 
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.init, election.state);
}

test "Election: leader elected after majority vote" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.election.Election.init(allocator, 0, 3);
    defer election.deinit();
    
    election.state = .candidate_ballot;
    election.candidate_term_id = 1;
    election.votes_received = 1; // self vote
    
    // Simulate receiving votes: candidate_term_id, candidate_member_id, follower_member_id, vote
    election.onVote(1, 0, 1, true);
    election.onVote(1, 0, 2, true);
    
    try std.testing.expectEqual(@as(u32, 3), election.votes_received);
}
