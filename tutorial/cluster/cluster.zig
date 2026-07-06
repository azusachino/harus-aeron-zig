// EXERCISE: Chapter 6.5 — Consensus Module
// Reference: docs/tutorial/06-cluster/05-cluster-main.md
//
// Your task: implement `ConsensusModule.doWork` — drive the election state
// machine, then sync the resulting role onto the conductor each duty cycle.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ConsensusModule = struct {
    pub fn doWork(self: *ConsensusModule, now_ns: i64) !i32 {
        _ = self;
        _ = now_ns;
        @panic("TODO: implement ConsensusModule.doWork");
    }
};

test "Consensus module duty cycle" {
    // var module = ConsensusModule{};
    // _ = try module.doWork(1000);
}
