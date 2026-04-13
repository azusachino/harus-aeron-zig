// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ClusterNodeTest.java
// Aeron version: 1.50.2
// Coverage: leader failure triggers election

const std = @import("std");
const aeron = @import("aeron");

test "ConsensusModule: starts in init, transitions to canvass via doWork" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &.{
            .{ .member_id = 0 },
            .{ .member_id = 1 },
            .{ .member_id = 2 },
        },
    });
    defer module.deinit();

    // Not running yet
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.init, module.electionState());

    module.start();

    // Drive doWork to transition init → canvass
    _ = try module.doWork(1000);
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.canvass, module.electionState());
}

test "ConsensusModule: leader loss triggers election restart" {
    const allocator = std.testing.allocator;

    // Set up a 3-node cluster
    var node0 = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &.{
            .{ .member_id = 0 },
            .{ .member_id = 1 },
            .{ .member_id = 2 },
        },
    });
    defer node0.deinit();

    var node1 = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &.{
            .{ .member_id = 0 },
            .{ .member_id = 1 },
            .{ .member_id = 2 },
        },
    });
    defer node1.deinit();

    // Node 0 is established leader
    node0.election.state = .leader_ready;
    node0.election.leader_member_id = 0;
    node0.election.leader_ship_term_id = 3;

    // Node 1 knows about the leader
    node1.election.state = .follower_ready;
    node1.election.leader_member_id = 0;
    node1.election.leader_ship_term_id = 3;
    node1.conductor.role = .follower;
    node1.conductor.leader_member_id = 0;
    node1.conductor.leader_ship_term_id = 3;

    // Discovery of a different node (simulates leader loss detection)
    try node1.onDiscoveryMessage(2);

    // Node1 election state should reflect that node 0 may have failed
    // Set it to follower_ready initially; now trigger canvass via timeout
    const now = 1000;
    node1.election.election_deadline_ns = now - 1; // Already expired
    node1.start();
    _ = try node1.doWork(now);

    // Should transition back to canvass when timeout is detected
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.canvass, node1.electionState());
}

test "ConsensusModule: follower correctly identifies it is not the leader" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &.{
            .{ .member_id = 0 },
            .{ .member_id = 1 },
            .{ .member_id = 2 },
        },
    });
    defer module.deinit();

    module.election.state = .follower_ready;
    module.election.leader_member_id = 0;

    // Try to enqueue a session connect (which requires leader)
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

    module.conductor.role = .follower;
    module.conductor.leader_member_id = 0;

    _ = try module.conductor.doWork();

    // Follower must reject session connect and emit redirect
    var got_redirect = false;
    var redirected_to: i32 = -1;

    for (module.conductor.response_queue.items) |*response| {
        if (response.* == .redirect) {
            got_redirect = true;
            redirected_to = response.redirect.leader_member_id;
        }
    }

    try std.testing.expect(got_redirect);
    try std.testing.expectEqual(@as(i32, 0), redirected_to);
}
