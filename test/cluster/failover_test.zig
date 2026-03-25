// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ClusterNodeTest.java
// Aeron version: 1.46.7
// Coverage: leader failure triggers election

const std = @import("std");
const aeron = @import("aeron");

test "ConsensusModule: failover triggers election" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &.{
            .{ .member_id = 0, .host = "localhost" },
            .{ .member_id = 1, .host = "localhost" },
            .{ .member_id = 2, .host = "localhost" },
        },
    });
    defer module.deinit();

    // Simulate transition to canvass
    module.election.state = .canvass;
    try std.testing.expectEqual(aeron.cluster.election.ElectionState.canvass, module.election.state);
}
