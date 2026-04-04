// EXERCISE: Chapter 6.2 — Cluster Election
// Reference: docs/tutorial/06-cluster/02-election.md
//
// Your task: implement `onRequestVote` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Election = struct {
    pub fn onRequestVote(self: *Election, candidate_id: i32, term: i64) bool {
        _ = self;
        _ = candidate_id;
        _ = term;
        @panic("TODO: implement Election.onRequestVote");
    }
};

test "Election vote granting" {
    // var election = Election{};
    // _ = election.onRequestVote(1, 5);
}
