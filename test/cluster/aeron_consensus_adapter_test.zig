const std = @import("std");
const adapter_mod = @import("aeron").cluster.aeron_consensus_adapter;
const codecs = @import("aeron").cluster.aeron_consensus_codecs;
const election = @import("aeron").cluster.election;

test "adapter rejects a malformed consensus block" {
    var adapter = try adapter_mod.ConsensusAdapter.init(std.testing.allocator, 1, 3);
    defer adapter.deinit();
    var request: [codecs.HEADER_LENGTH + codecs.RequestVoteBlockLength]u8 = undefined;
    _ = try codecs.encodeRequestVote(&request, .{
        .log_leadership_term_id = 0,
        .log_position = 0,
        .candidate_term_id = 1,
        .candidate_member_id = 0,
        .protocol_version = 15,
    });
    request[0] = 0;
    var response: [128]u8 = undefined;
    try std.testing.expectError(error.BlockLengthMismatch, adapter.onMessage(&request, &response, 0));
}

test "adapter accepts Java replication and catchup notifications" {
    var adapter = try adapter_mod.ConsensusAdapter.init(std.testing.allocator, 2, 3);
    defer adapter.deinit();
    var response: [256]u8 = undefined;

    var append: [codecs.HEADER_LENGTH + codecs.AppendPositionBlockLength]u8 = undefined;
    _ = try codecs.encodeAppendPosition(&append, .{
        .leadership_term_id = 7,
        .log_position = 128,
        .follower_member_id = 2,
        .flags = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), try adapter.onMessage(&append, &response, 1));
    try std.testing.expectEqual(@as(i64, 128), adapter.last_append_position.?.log_position);

    var commit: [codecs.HEADER_LENGTH + codecs.CommitPositionBlockLength]u8 = undefined;
    _ = try codecs.encodeCommitPosition(&commit, .{
        .leadership_term_id = 7,
        .log_position = 128,
        .leader_member_id = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), try adapter.onMessage(&commit, &response, 2));
    try std.testing.expectEqual(@as(i64, 128), adapter.last_commit_position.?.log_position);
    try std.testing.expectEqual(election.ElectionState.follower_ready, adapter.election.currentState());

    const endpoint = "aeron:udp?endpoint=zig-node-2:9023";
    var catchup: [256]u8 = undefined;
    const catchup_length = try codecs.encodeCatchupPosition(&catchup, .{
        .leadership_term_id = 7,
        .log_position = 64,
        .follower_member_id = 2,
        .catchup_endpoint = endpoint,
    });
    try std.testing.expectEqual(@as(usize, 0), try adapter.onMessage(catchup[0..catchup_length], &response, 3));
    try std.testing.expectEqualStrings(endpoint, adapter.last_catchup_endpoint[0..adapter.last_catchup_endpoint_len]);

    var stop: [codecs.HEADER_LENGTH + codecs.StopCatchupBlockLength]u8 = undefined;
    _ = try codecs.encodeStopCatchup(&stop, .{ .leadership_term_id = 7, .follower_member_id = 2 });
    try std.testing.expectEqual(@as(usize, 0), try adapter.onMessage(&stop, &response, 4));
    try std.testing.expectEqual(@as(i32, 2), adapter.last_stop_catchup.?.follower_member_id);
}
