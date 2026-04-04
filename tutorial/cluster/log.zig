// EXERCISE: Chapter 6.3 — Cluster Log
// Reference: docs/tutorial/06-cluster/03-log-replication.md
//
// Your task: implement `isPositionCommitted` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ClusterLog = struct {
    pub fn isPositionCommitted(follower_positions: []const i64, target_position: i64, cluster_size: u32) bool {
        _ = follower_positions;
        _ = target_position;
        _ = cluster_size;
        @panic("TODO: implement ClusterLog.isPositionCommitted");
    }
};

test "Log quorum check" {
    // try std.testing.expect(ClusterLog.isPositionCommitted(&[_]i64{100, 100}, 100, 3));
}
