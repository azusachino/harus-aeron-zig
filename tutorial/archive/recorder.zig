// EXERCISE: Chapter 5.3 — Archive Recorder
// Reference: docs/tutorial/05-archive/03-recorder.md
//
// Your task: implement `Recorder.onFragment` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Recorder = struct {
    pub fn onFragment(self: *Recorder, buffer: []const u8) void {
        _ = self;
        _ = buffer;
        @panic("TODO: implement Recorder.onFragment");
    }
};

test "Recorder fragment handling" {
    // var recorder = Recorder{};
    // recorder.onFragment("data");
}
