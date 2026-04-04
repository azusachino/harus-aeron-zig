// EXERCISE: Chapter 5.4 — Archive Replayer
// Reference: docs/tutorial/05-archive/04-replayer.md
//
// Your task: implement `Replayer.doWork` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Replayer = struct {
    pub fn doWork(self: *Replayer) i32 {
        _ = self;
        @panic("TODO: implement Replayer.doWork");
    }
};

test "Replayer duty cycle" {
    // var replayer = Replayer{};
    // _ = replayer.doWork();
}
