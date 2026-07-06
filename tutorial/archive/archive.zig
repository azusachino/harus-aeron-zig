// EXERCISE: Chapter 5.6 — Archive Main
// Reference: docs/tutorial/05-archive/06-archive-main.md
//
// Your task: implement `ArchiveProxy.startRecording` — encode a StartRecording
// request and enqueue it toward the archive conductor.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ArchiveProxy = struct {
    pub fn startRecording(
        self: *ArchiveProxy,
        correlation_id: i64,
        stream_id: i32,
        channel: []const u8,
        source_identity: []const u8,
    ) !void {
        _ = self;
        _ = correlation_id;
        _ = stream_id;
        _ = channel;
        _ = source_identity;
        @panic("TODO: implement ArchiveProxy.startRecording");
    }
};

test "Archive proxy start recording" {
    // var proxy = ArchiveProxy{};
    // try proxy.startRecording(1, 1001, "aeron:udp?endpoint=localhost:9010", "source");
}
