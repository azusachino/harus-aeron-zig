const std = @import("std");
const codecs = @import("aeron").cluster.aeron_consensus_codecs;

test "consensus templates use upstream IDs and block lengths" {
    try std.testing.expectEqual(@as(u16, 50), @intFromEnum(codecs.Template.canvass_position));
    try std.testing.expectEqual(@as(u16, 51), @intFromEnum(codecs.Template.request_vote));
    try std.testing.expectEqual(@as(u16, 52), @intFromEnum(codecs.Template.vote));
    try std.testing.expectEqual(@as(u16, 53), @intFromEnum(codecs.Template.new_leadership_term));
    try std.testing.expectEqual(@as(u16, 54), @intFromEnum(codecs.Template.append_position));
    try std.testing.expectEqual(@as(u16, 55), @intFromEnum(codecs.Template.commit_position));
    try std.testing.expectEqual(@as(u16, 56), @intFromEnum(codecs.Template.catchup_position));
    try std.testing.expectEqual(@as(u16, 57), @intFromEnum(codecs.Template.stop_catchup));
    try std.testing.expectEqual(@as(u16, 21), codecs.AppendPositionBlockLength);
    try std.testing.expectEqual(@as(u16, 96), codecs.NewLeadershipTermBlockLength);
}
