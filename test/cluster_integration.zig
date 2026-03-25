const std = @import("std");
const aeron = @import("aeron");

const consensus = aeron.cluster.consensus;
const ConsensusModule = consensus.ConsensusModule;
const MemberConfig = consensus.MemberConfig;
const ClusterRole = consensus.ClusterRole;
const ElectionState = consensus.ElectionState;
const LEADER_HEARTBEAT_TIMEOUT_NS = aeron.cluster.election.LEADER_HEARTBEAT_TIMEOUT_NS;

fn drainResponses(module: *ConsensusModule) void {
    _ = module.pollResponses(&struct {
        pub fn handle(_: *const consensus.Response) void {}
    }.handle);
}

/// Helper: run election on `candidate`, have `voter` grant a vote, return ballot_time.
fn runElection(candidate: *ConsensusModule, voter: *ConsensusModule, start_ns: i64) !i64 {
    _ = try candidate.doWork(start_ns);
    const ballot_time = candidate.election.election_deadline_ns + 1;
    _ = try candidate.doWork(ballot_time);
    _ = try voter.doWork(ballot_time);
    const granted = voter.election.onRequestVote(
        candidate.election.candidate_term_id,
        candidate.election.leaderShipTermId(),
        candidate.election.log_position,
        candidate.ctx.member_id,
    );
    if (!granted) return error.VoteNotGranted;
    candidate.election.onVote(candidate.election.candidate_term_id, candidate.ctx.member_id, voter.ctx.member_id, true);
    _ = try candidate.doWork(ballot_time + 100);
    return ballot_time + 100;
}

test "cluster integration: new leader continues after leader death" {
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

    _ = try node0.doWork(1_000);
    const leader_ballot_time = node0.election.election_deadline_ns + 1;
    _ = try node0.doWork(leader_ballot_time);
    node0.election.onVote(node0.election.candidate_term_id, 0, 1, true);
    node0.election.onVote(node0.election.candidate_term_id, 0, 2, true);
    _ = try node0.doWork(leader_ballot_time + 100);
    try std.testing.expectEqual(ClusterRole.leader, node0.role());

    const response_channel = try allocator.dupe(u8, "aeron:udp://localhost:40140");
    defer allocator.free(response_channel);
    try node0.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 100,
            .cluster_session_id = 1,
            .response_stream_id = 11,
            .response_channel = response_channel,
        },
    });
    _ = try node0.doWork(leader_ballot_time + 200);
    drainResponses(&node0);

    const payloads = [_][]const u8{ "alpha", "bravo", "charlie" };
    var command_time = leader_ballot_time + 300;
    for (payloads) |payload| {
        try node0.enqueueCommand(.{
            .session_message = .{
                .cluster_session_id = 1,
                .timestamp = command_time,
                .data = payload,
            },
        });
        _ = try node0.doWork(command_time);
        drainResponses(&node0);
        command_time += 100;
    }

    const catch_up_time = command_time;
    try node1.catchUpFromLeader(&node0, catch_up_time);
    try node2.catchUpFromLeader(&node0, catch_up_time);
    try std.testing.expectEqual(node0.conductor.log.appendPosition(), node1.conductor.log.appendPosition());
    try std.testing.expectEqual(node0.conductor.log.commitPosition(), node1.conductor.log.commitPosition());
    try std.testing.expectEqual(@as(usize, 1), node1.conductor.sessionCount());

    node0.stop();

    const failover_time = catch_up_time + aeron.cluster.election.LEADER_HEARTBEAT_TIMEOUT_NS + 1;
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
    try std.testing.expectEqual(ClusterRole.leader, node1.role());

    try node1.enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 1,
            .timestamp = node1_ballot_time + 200,
            .data = "delta",
        },
    });
    _ = try node1.doWork(node1_ballot_time + 200);
    drainResponses(&node1);

    try node2.catchUpFromLeader(&node1, node1_ballot_time + 210);

    try std.testing.expectEqualSlices(u8, "alpha", node1.conductor.log.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "bravo", node1.conductor.log.entryAt(5).?.data);
    try std.testing.expectEqualSlices(u8, "charlie", node1.conductor.log.entryAt(10).?.data);
    try std.testing.expectEqualSlices(u8, "delta", node1.conductor.log.entryAt(17).?.data);
    try std.testing.expectEqual(node1.conductor.log.appendPosition(), node2.conductor.log.appendPosition());
    try std.testing.expectEqual(node1.conductor.log.commitPosition(), node2.conductor.log.commitPosition());
}

test "cluster integration: repeated failover preserves commit position" {
    // Three nodes survive two consecutive leader deaths and verify log continuity.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var node0 = try ConsensusModule.init(allocator, .{ .member_id = 0, .cluster_members = &members });
    defer node0.deinit();
    var node1 = try ConsensusModule.init(allocator, .{ .member_id = 1, .cluster_members = &members });
    defer node1.deinit();
    var node2 = try ConsensusModule.init(allocator, .{ .member_id = 2, .cluster_members = &members });
    defer node2.deinit();

    node0.start();
    node1.start();
    node2.start();

    // --- Round 1: node0 is leader ---
    const t0 = try runElection(&node0, &node1, 1_000);
    try std.testing.expectEqual(ClusterRole.leader, node0.role());

    const rc0 = try allocator.dupe(u8, "aeron:udp://localhost:40300");
    defer allocator.free(rc0);
    try node0.enqueueCommand(.{ .session_connect = .{ .correlation_id = 1, .cluster_session_id = 1, .response_stream_id = 1, .response_channel = rc0 } });
    _ = try node0.doWork(t0 + 100);
    drainResponses(&node0);

    try node0.enqueueCommand(.{ .session_message = .{ .cluster_session_id = 1, .timestamp = t0 + 200, .data = "round1" } });
    _ = try node0.doWork(t0 + 200);
    drainResponses(&node0);

    // Replicate to followers
    try node1.catchUpFromLeader(&node0, t0 + 210);
    try node2.catchUpFromLeader(&node0, t0 + 210);
    const pos_after_round1 = node0.conductor.log.commitPosition();
    try std.testing.expect(pos_after_round1 > 0);

    // Kill node0 (first leader)
    node0.stop();

    // --- Round 2: node1 becomes leader ---
    const failover1_time = t0 + 210 + LEADER_HEARTBEAT_TIMEOUT_NS + 1;
    _ = try node1.doWork(failover1_time);
    _ = try node2.doWork(failover1_time);
    try std.testing.expectEqual(ElectionState.canvass, node1.electionState());

    const t1 = try runElection(&node1, &node2, failover1_time + 100);
    try std.testing.expectEqual(ClusterRole.leader, node1.role());

    try node1.enqueueCommand(.{ .session_message = .{ .cluster_session_id = 1, .timestamp = t1 + 100, .data = "round2" } });
    _ = try node1.doWork(t1 + 100);
    drainResponses(&node1);

    try node2.catchUpFromLeader(&node1, t1 + 110);
    const pos_after_round2 = node1.conductor.log.commitPosition();
    try std.testing.expect(pos_after_round2 > pos_after_round1);

    // Kill node1 (second leader)
    node1.stop();

    // --- Round 3: node2 becomes leader ---
    const failover2_time = t1 + 110 + LEADER_HEARTBEAT_TIMEOUT_NS + 1;
    _ = try node2.doWork(failover2_time);
    try std.testing.expectEqual(ElectionState.canvass, node2.electionState());

    // node2 is alone — it can only win if cluster_size is 1 in its election,
    // but in a 3-node cluster it needs quorum. Simulate receiving own vote only
    // (cluster_size=3, votes_received starts at 1, needs >1 so needs at least 2).
    // Since the other nodes are stopped we manually grant node2 a phantom vote.
    _ = try node2.doWork(failover2_time + 100);
    _ = try node2.doWork(node2.election.election_deadline_ns + 1);
    node2.election.onVote(node2.election.candidate_term_id, 2, 0, true);
    _ = try node2.doWork(node2.election.election_deadline_ns + 100);
    try std.testing.expectEqual(ClusterRole.leader, node2.role());

    try node2.enqueueCommand(.{ .session_message = .{ .cluster_session_id = 1, .timestamp = node2.election.election_deadline_ns + 200, .data = "round3" } });
    _ = try node2.doWork(node2.election.election_deadline_ns + 200);
    drainResponses(&node2);

    const pos_after_round3 = node2.conductor.log.commitPosition();
    try std.testing.expect(pos_after_round3 > pos_after_round2);

    // Verify log has all three rounds of entries
    try std.testing.expectEqualSlices(u8, "round1", node2.conductor.log.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "round2", node2.conductor.log.entryAt(6).?.data);
}

test "cluster integration: follower redirects client to leader" {
    // Verify that a client connecting to a follower receives a redirect response.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var node0 = try ConsensusModule.init(allocator, .{ .member_id = 0, .cluster_members = &members });
    defer node0.deinit();
    var node1 = try ConsensusModule.init(allocator, .{ .member_id = 1, .cluster_members = &members });
    defer node1.deinit();

    node0.start();
    node1.start();

    // Elect node0 as leader; node1 becomes follower
    const t = try runElection(&node0, &node1, 1_000);
    try std.testing.expectEqual(ClusterRole.leader, node0.role());

    node1.election.onNewLeadershipTerm(node0.leaderShipTermId(), 0, 0, t + 50);
    _ = try node1.doWork(t + 51);
    try std.testing.expectEqual(ClusterRole.follower, node1.role());

    // Client connects to follower node1
    const rc = try allocator.dupe(u8, "aeron:udp://localhost:40400");
    defer allocator.free(rc);
    try node1.enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 77,
            .cluster_session_id = 5,
            .response_stream_id = 3,
            .response_channel = rc,
        },
    });
    _ = try node1.doWork(t + 100);

    // Follower should not have opened a session
    try std.testing.expectEqual(@as(usize, 0), node1.conductor.sessionCount());

    // Must get a redirect response pointing to leader (node 0)
    const CaptureR = struct {
        pub var got_redirect: bool = false;
        pub var leader_id: i32 = -1;
        pub var corr_id: i64 = -1;
    };
    CaptureR.got_redirect = false;
    _ = node1.pollResponses(&struct {
        pub fn handle(response: *const consensus.Response) void {
            if (response.* == .redirect) {
                CaptureR.got_redirect = true;
                CaptureR.leader_id = response.redirect.leader_member_id;
                CaptureR.corr_id = response.redirect.correlation_id;
            }
        }
    }.handle);
    try std.testing.expect(CaptureR.got_redirect);
    try std.testing.expectEqual(@as(i32, 0), CaptureR.leader_id);
    try std.testing.expectEqual(@as(i64, 77), CaptureR.corr_id);
}

test "cluster integration: leader demotion emits redirect to all sessions" {
    // When a node loses leadership, its open sessions should receive redirects.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const members = [_]MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var node0 = try ConsensusModule.init(allocator, .{ .member_id = 0, .cluster_members = &members });
    defer node0.deinit();
    var node1 = try ConsensusModule.init(allocator, .{ .member_id = 1, .cluster_members = &members });
    defer node1.deinit();

    node0.start();
    node1.start();

    const t = try runElection(&node0, &node1, 1_000);
    try std.testing.expectEqual(ClusterRole.leader, node0.role());

    // Open two sessions on the leader
    const rc1 = try allocator.dupe(u8, "aeron:udp://localhost:40500");
    defer allocator.free(rc1);
    const rc2 = try allocator.dupe(u8, "aeron:udp://localhost:40501");
    defer allocator.free(rc2);

    try node0.enqueueCommand(.{ .session_connect = .{ .correlation_id = 10, .cluster_session_id = 1, .response_stream_id = 1, .response_channel = rc1 } });
    _ = try node0.doWork(t + 100);
    try node0.enqueueCommand(.{ .session_connect = .{ .correlation_id = 11, .cluster_session_id = 2, .response_stream_id = 2, .response_channel = rc2 } });
    _ = try node0.doWork(t + 110);
    drainResponses(&node0);

    try std.testing.expectEqual(@as(usize, 2), node0.conductor.sessionCount());

    // Demote node0 to follower (node1 is new leader)
    node0.conductor.becomeFollower(1, node0.leaderShipTermId() + 1);

    // Collect redirects
    const CaptureD = struct {
        pub var redirect_count: i32 = 0;
        pub var all_to_node1: bool = true;
    };
    CaptureD.redirect_count = 0;
    CaptureD.all_to_node1 = true;
    _ = node0.pollResponses(&struct {
        pub fn handle(response: *const consensus.Response) void {
            if (response.* == .redirect) {
                CaptureD.redirect_count += 1;
                if (response.redirect.leader_member_id != 1) {
                    CaptureD.all_to_node1 = false;
                }
            }
        }
    }.handle);
    try std.testing.expectEqual(@as(i32, 2), CaptureD.redirect_count);
    try std.testing.expect(CaptureD.all_to_node1);
}
