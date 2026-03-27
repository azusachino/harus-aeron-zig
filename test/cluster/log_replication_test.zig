// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/LogReplicationTest.java
// Aeron version: 1.50.2
// Coverage: follower replicates log entries, commit position advances

const std = @import("std");
const aeron = @import("aeron");

test "LogReplication: follower commit position advances after append" {
    const allocator = std.testing.allocator;
    var follower = aeron.cluster.log.LogFollower.init(allocator, 1);
    defer follower.deinit();

    try std.testing.expectEqual(@as(i64, 0), follower.commitPosition());

    // Append data to advance append_position
    _ = try follower.onAppendRequest(1, "test data", 1000);

    const pos = follower.appendPosition();
    try std.testing.expect(pos > 0);

    follower.onCommitPosition(pos);
    try std.testing.expectEqual(pos, follower.commitPosition());
}
