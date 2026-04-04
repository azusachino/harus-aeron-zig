// EXERCISE: Chapter 3.2 — Receiver Agent
// Reference: docs/tutorial/03-driver/02-receiver.md
//
// Your task: implement the Receiver's `onDataPacket` handler.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Receiver = struct {
    pub fn doWork(self: *Receiver) i32 {
        _ = self;
        @panic("TODO: implement Receiver.doWork");
    }
};

test "Receiver duty cycle" {
    // var receiver = Receiver{};
    // _ = receiver.doWork();
}
