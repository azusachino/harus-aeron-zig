// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/LogReplicationTest.java
// Aeron version: 1.50.2
// Coverage: follower replicates log entries, commit position advances

const std = @import("std");
const aeron = @import("aeron");

test "LogReplication: follower receives multiple appends in sequence" {
    const allocator = std.testing.allocator;
    var follower = aeron.cluster.log.LogFollower.init(allocator, 1);
    defer follower.deinit();

    // Append 5 entries in sequence
    const expected_positions: [5]i64 = .{ 0, 3, 6, 11, 15 };
    for (0..5) |i| {
        const data = switch (i) {
            0 => "one",
            1 => "two",
            2 => "three",
            3 => "four",
            4 => "five",
            else => unreachable,
        };
        const pos = try follower.onAppendRequest(1, data, @intCast(1000 + i));

        // Verify each append position matches expected offset
        try std.testing.expectEqual(expected_positions[i], pos);
    }

    // Final append position should be sum of all data lengths
    const total_len: i64 = 3 + 3 + 5 + 4 + 4; // one, two, three, four, five
    try std.testing.expectEqual(total_len, follower.appendPosition());
}

test "LogReplication: commit position advances only after explicit onCommitPosition" {
    const allocator = std.testing.allocator;
    var follower = aeron.cluster.log.LogFollower.init(allocator, 1);
    defer follower.deinit();

    // Append 3 entries
    _ = try follower.onAppendRequest(1, "entry1", 1000);
    const pos2 = try follower.onAppendRequest(1, "entry2", 1001);
    const pos3 = try follower.onAppendRequest(1, "entry3", 1002);

    // commitPosition should still be 0
    try std.testing.expectEqual(@as(i64, 0), follower.commitPosition());
    try std.testing.expectEqual(@as(i64, 18), follower.appendPosition()); // 6+6+6

    // Advance commit to pos2
    follower.onCommitPosition(pos2 + 6);
    try std.testing.expectEqual(@as(i64, 12), follower.commitPosition());

    // Advance commit to pos3
    follower.onCommitPosition(pos3 + 6);
    try std.testing.expectEqual(@as(i64, 18), follower.commitPosition());
}

test "LogReplication: leader tracks multiple follower ACKs" {
    const allocator = std.testing.allocator;
    var log = aeron.cluster.log.ClusterLog.init(allocator);
    defer log.deinit();

    var leader = try aeron.cluster.log.LogLeader.init(allocator, &log, 3);
    defer leader.deinit();

    // Leader appends an entry
    _ = try log.append("data", 1000);
    try std.testing.expectEqual(@as(i64, 4), log.appendPosition());

    // Both followers ACK the append at position 4
    leader.onAppendPosition(0, 4);
    leader.onAppendPosition(1, 4);

    // Quorum (2 of 3 followers) reached, commit should advance
    try std.testing.expectEqual(@as(i64, 4), log.commitPosition());
}

test "LogReplication: append returns correct log position" {
    const allocator = std.testing.allocator;
    var follower = aeron.cluster.log.LogFollower.init(allocator, 1);
    defer follower.deinit();

    // First append at position 0
    const pos1 = try follower.onAppendRequest(1, "hello", 1000);
    try std.testing.expectEqual(@as(i64, 0), pos1);

    // Second append at position 5
    const pos2 = try follower.onAppendRequest(1, "world", 2000);
    try std.testing.expectEqual(@as(i64, 5), pos2);

    // Third append at position 10
    const pos3 = try follower.onAppendRequest(1, "test", 3000);
    try std.testing.expectEqual(@as(i64, 10), pos3);
}
