const std = @import("std");
const aeron = @import("aeron");

const consensus = aeron.cluster.consensus;
const ConsensusModule = consensus.ConsensusModule;
const MemberConfig = consensus.MemberConfig;
const ClusterRole = consensus.ClusterRole;
const ElectionState = consensus.ElectionState;

fn drainResponses(module: *ConsensusModule) void {
    _ = module.pollResponses(&struct {
        pub fn handle(_: *const consensus.Response) void {}
    }.handle);
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
