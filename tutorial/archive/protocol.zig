// EXERCISE: Chapter 5.1 — Archive Protocol
// Reference: docs/tutorial/05-archive/01-archive-protocol.md
//
// Your task: implement archive message encoding.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ArchiveProtocol = struct {
    pub const MSG_TYPE_ID: i32 = 500;
};

test "Archive protocol constants" {
    try std.testing.expectEqual(@as(i32, 500), ArchiveProtocol.MSG_TYPE_ID);
}
