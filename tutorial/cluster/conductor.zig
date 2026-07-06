// EXERCISE: Chapter 6.4 — Cluster Conductor
// Reference: docs/tutorial/06-cluster/04-cluster-conductor.md
//
// Your task: implement `ClusterConductor.serializeState` — write the durable
// recovery state (role, term/session ids, sessions, log) into a snapshot blob.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const ClusterConductor = struct {
    pub fn serializeState(self: *const ClusterConductor, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = allocator;
        @panic("TODO: implement ClusterConductor.serializeState");
    }
};

test "Cluster conductor snapshot serialization" {
    // const blob = try conductor.serializeState(allocator);
    // defer allocator.free(blob);
}
