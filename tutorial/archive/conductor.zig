// EXERCISE: Chapter 5.5 — Archive Conductor
// Reference: docs/tutorial/05-archive/05-archive-conductor.md
//
// Your task: implement `ArchiveConductor.onStartRecording` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ArchiveConductor = struct {
    pub fn onStartRecording(self: *ArchiveConductor, channel: []const u8, stream_id: i32) void {
        _ = self;
        _ = channel;
        _ = stream_id;
        @panic("TODO: implement ArchiveConductor.onStartRecording");
    }
};

test "Archive conductor start recording" {
    // var conductor = ArchiveConductor{};
    // conductor.onStartRecording("aeron:udp?...", 1001);
}
