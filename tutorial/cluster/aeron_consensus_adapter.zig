// EXERCISE: Chapter 6.6 — Java Aeron Cluster consensus adapter
// Reference: docs/tutorial/06-cluster/06-consensus-adapter.md
//
// Implement the SBE consensus message dispatch and map RequestVote/Vote
// events into the election state machine.

pub const ConsensusAdapter = struct {
    pub fn onMessage(self: *ConsensusAdapter, payload: []const u8) !usize {
        _ = self;
        _ = payload;
        @panic("TODO: implement ConsensusAdapter.onMessage");
    }
};
