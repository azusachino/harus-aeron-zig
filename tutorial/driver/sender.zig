// EXERCISE: Chapter 3.1 — Sender Agent
// Reference: docs/tutorial/03-driver/01-sender.md
//
// Your task: implement the Sender's `doWork` loop.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Sender = struct {
    pub fn doWork(self: *Sender) i32 {
        _ = self;
        @panic("TODO: implement Sender.doWork");
    }
};

test "Sender duty cycle" {
    // var sender = Sender{};
    // _ = sender.doWork();
}
