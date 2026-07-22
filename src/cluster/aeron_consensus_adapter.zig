//! Bridge authentic Aeron Cluster consensus frames into the Zig election state.
//!
//! This layer intentionally has no socket or Compose concerns. It accepts one
//! complete Aeron fragment and writes at most one response fragment, making it
//! usable by the networked member once consensus subscriptions are wired.

const std = @import("std");
const election_mod = @import("election.zig");
const codecs = @import("aeron_consensus_codecs.zig");

// LESSON(cluster-consensus-adapter): Keep Java's SBE framing separate from the
// election state machine so transport tests can prove wire compatibility before
// log replay and service execution are introduced. See
// docs/tutorial/06-cluster/01-cluster-protocol.md
pub const ConsensusAdapter = struct {
    election: election_mod.Election,
    member_id: i32,
    protocol_version: i32 = 15,
    last_append_position: ?codecs.AppendPosition = null,
    last_commit_position: ?codecs.CommitPosition = null,
    last_catchup_position: ?codecs.CatchupPosition = null,
    last_catchup_endpoint: [256]u8 = [_]u8{0} ** 256,
    last_catchup_endpoint_len: usize = 0,
    last_stop_catchup: ?codecs.StopCatchup = null,

    pub fn init(allocator: std.mem.Allocator, member_id: i32, cluster_size: u32) !ConsensusAdapter {
        return .{
            .election = try election_mod.Election.init(allocator, member_id, cluster_size),
            .member_id = member_id,
        };
    }

    pub fn deinit(self: *ConsensusAdapter) void {
        self.election.deinit();
    }

    /// Process a consensus fragment. A positive return value is the encoded
    /// response length; zero means the message only changed local state.
    // LESSON(cluster-consensus-adapter): One complete Aeron fragment maps to
    // one consensus event; a positive return value is a response fragment.
    pub fn onMessage(self: *ConsensusAdapter, payload: []const u8, response: []u8, now_ns: i64) !usize {
        const header = try codecs.decodeHeader(payload);
        switch (header.template_id) {
            .canvass_position => {
                const message = try codecs.decodeCanvassPosition(payload);
                self.election.onCanvassPosition(
                    message.log_leadership_term_id,
                    message.log_position,
                    message.follower_member_id,
                );
            },
            .request_vote => {
                const message = try codecs.decodeRequestVote(payload);
                const granted = self.election.onRequestVote(
                    message.candidate_term_id,
                    message.log_leadership_term_id,
                    message.log_position,
                    message.candidate_member_id,
                    now_ns,
                );
                return codecs.encodeVote(response, .{
                    .candidate_term_id = message.candidate_term_id,
                    .log_leadership_term_id = message.log_leadership_term_id,
                    .log_position = message.log_position,
                    .candidate_member_id = message.candidate_member_id,
                    .follower_member_id = self.member_id,
                    .vote = if (granted) 1 else 0,
                });
            },
            .vote => {
                const message = try codecs.decodeVote(payload);
                self.election.onVote(
                    message.candidate_term_id,
                    message.candidate_member_id,
                    message.follower_member_id,
                    message.vote != 0,
                );
            },
            .new_leadership_term => {
                const message = try codecs.decodeNewLeadershipTerm(payload);
                self.election.onNewLeadershipTerm(
                    message.leadership_term_id,
                    message.log_position,
                    message.leader_member_id,
                    now_ns,
                );
            },
            .append_position => {
                self.last_append_position = try codecs.decodeAppendPosition(payload);
            },
            .commit_position => {
                const message = try codecs.decodeCommitPosition(payload);
                self.last_commit_position = message;
                self.election.onLeaderHeartbeat(
                    message.leadership_term_id,
                    message.log_position,
                    message.leader_member_id,
                    now_ns,
                );
            },
            .catchup_position => {
                const message = try codecs.decodeCatchupPosition(payload);
                if (message.catchup_endpoint.len > self.last_catchup_endpoint.len) return error.EndpointTooLong;
                @memcpy(self.last_catchup_endpoint[0..message.catchup_endpoint.len], message.catchup_endpoint);
                self.last_catchup_endpoint_len = message.catchup_endpoint.len;
                self.last_catchup_position = .{
                    .leadership_term_id = message.leadership_term_id,
                    .log_position = message.log_position,
                    .follower_member_id = message.follower_member_id,
                    .catchup_endpoint = self.last_catchup_endpoint[0..message.catchup_endpoint.len],
                };
            },
            .stop_catchup => {
                self.last_stop_catchup = try codecs.decodeStopCatchup(payload);
            },
        }
        return 0;
    }
};

test "consensus adapter maps Java RequestVote to a Java Vote" {
    var follower = try ConsensusAdapter.init(std.testing.allocator, 1, 3);
    defer follower.deinit();

    var request: [codecs.HEADER_LENGTH + codecs.RequestVoteBlockLength]u8 = undefined;
    _ = try codecs.encodeRequestVote(&request, .{
        .log_leadership_term_id = 0,
        .log_position = 0,
        .candidate_term_id = 1,
        .candidate_member_id = 0,
        .protocol_version = 15,
    });
    var vote: [codecs.HEADER_LENGTH + codecs.VoteBlockLength]u8 = undefined;
    const response_length = try follower.onMessage(&request, &vote, 1);
    try std.testing.expectEqual(@as(usize, codecs.HEADER_LENGTH + codecs.VoteBlockLength), response_length);
    const response = try codecs.decodeVote(vote[0..response_length]);
    try std.testing.expectEqual(@as(i32, 0), response.candidate_member_id);
    try std.testing.expectEqual(@as(i32, 1), response.follower_member_id);
    try std.testing.expectEqual(@as(i32, 1), response.vote);
}
