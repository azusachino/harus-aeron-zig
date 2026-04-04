// EXERCISE: Chapter 6.1 — Cluster Protocol
// Reference: docs/tutorial/06-cluster/01-cluster-protocol.md
//
// Your task: implement cluster message encoding.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ClusterProtocol = struct {
    pub const SESSION_CONNECT_MSG_TYPE: i32 = 201;
};

test "Cluster protocol constants" {
    try std.testing.expectEqual(@as(i32, 201), ClusterProtocol.SESSION_CONNECT_MSG_TYPE);
}
