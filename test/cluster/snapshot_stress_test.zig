// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ClusterNodeTest.java
// Aeron version: 1.50.2
// Coverage: stress test for snapshots under failure conditions

const std = @import("std");
const aeron = @import("aeron");

test "ConsensusModule: snapshot interrupted mid-way by discovery of new leader" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 1,
        .cluster_members = &.{
            .{ .member_id = 0 },
            .{ .member_id = 1 },
            .{ .member_id = 2 },
        },
    });
    defer module.deinit();

    // Verify initial state
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.none, module.conductor.snapshot_state);

    // Enqueue snapshot_begin command
    try module.conductor.enqueueCommand(.{
        .snapshot_begin = .{
            .leadership_term_id = 1,
            .log_position = 1024,
            .timestamp = 1000,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();

    // Snapshot in progress
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.taking, module.conductor.snapshot_state);

    // Interrupt: discover a different leader
    try module.onDiscoveryMessage(2);

    // The snapshot_state should remain "taking" unless explicitly transitioned
    // (In a real cluster, a new leader would send snapshot_end with higher term)
    // For this test, enqueue a new snapshot_begin with higher term to simulate leader change
    try module.conductor.enqueueCommand(.{
        .snapshot_begin = .{
            .leadership_term_id = 2,
            .log_position = 2048,
            .timestamp = 2000,
            .member_id = 2,
        },
    });
    _ = try module.conductor.doWork();

    // Still in taking state (idempotent)
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.taking, module.conductor.snapshot_state);

    // Now enqueue snapshot_end to complete
    try module.conductor.enqueueCommand(.{
        .snapshot_end = .{
            .leadership_term_id = 2,
            .log_position = 2048,
            .member_id = 2,
        },
    });
    _ = try module.conductor.doWork();

    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.completed, module.conductor.snapshot_state);
}

test "ConsensusModule: snapshot completes successfully" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &.{
            .{ .member_id = 0 },
        },
    });
    defer module.deinit();

    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.none, module.conductor.snapshot_state);

    // Enqueue snapshot_begin
    try module.conductor.enqueueCommand(.{
        .snapshot_begin = .{
            .leadership_term_id = 1,
            .log_position = 512,
            .timestamp = 1000,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.taking, module.conductor.snapshot_state);

    // Snapshot would normally do work here (writing to archive, etc.)
    // For this test, we just verify the state transitions

    // Enqueue snapshot_end
    try module.conductor.enqueueCommand(.{
        .snapshot_end = .{
            .leadership_term_id = 1,
            .log_position = 512,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.completed, module.conductor.snapshot_state);
}

test "ConsensusModule: sequential snapshots transition properly" {
    const allocator = std.testing.allocator;
    var module = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
        .member_id = 0,
        .cluster_members = &.{
            .{ .member_id = 0 },
        },
    });
    defer module.deinit();

    // First snapshot: begin → end
    try module.conductor.enqueueCommand(.{
        .snapshot_begin = .{
            .leadership_term_id = 1,
            .log_position = 100,
            .timestamp = 1000,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.taking, module.conductor.snapshot_state);

    try module.conductor.enqueueCommand(.{
        .snapshot_end = .{
            .leadership_term_id = 1,
            .log_position = 100,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.completed, module.conductor.snapshot_state);

    // Second snapshot: begin → taking state
    try module.conductor.enqueueCommand(.{
        .snapshot_begin = .{
            .leadership_term_id = 2,
            .log_position = 200,
            .timestamp = 2000,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();

    // Should transition back to taking state
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.taking, module.conductor.snapshot_state);

    // Complete second snapshot
    try module.conductor.enqueueCommand(.{
        .snapshot_end = .{
            .leadership_term_id = 2,
            .log_position = 200,
            .member_id = 0,
        },
    });
    _ = try module.conductor.doWork();
    try std.testing.expectEqual(aeron.cluster.conductor.SnapshotState.completed, module.conductor.snapshot_state);
}
