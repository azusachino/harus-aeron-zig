// Cluster status display.
// Displays cluster membership, current leader, election state.
const std = @import("std");
const cluster_mod = @import("../cluster/cluster.zig");
const election_mod = @import("../cluster/election.zig");
const conductor_mod = @import("../cluster/conductor.zig");

pub fn run(_: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Placeholder: create a sample cluster context until state files are available
    const members = [_]cluster_mod.MemberConfig{
        .{ .member_id = 0, .host = "node-0", .client_port = 9010 },
        .{ .member_id = 1, .host = "node-1", .client_port = 9011 },
        .{ .member_id = 2, .host = "node-2", .client_port = 9012 },
    };

    const ctx = cluster_mod.ClusterContext{
        .member_id = 0,
        .cluster_members = &members,
    };

    var module = cluster_mod.ConsensusModule.init(allocator, ctx) catch {
        stdout.interface.print("Error: could not initialize cluster context\n", .{}) catch return;
        return;
    };
    defer module.deinit();
    module.start();

    stdout.interface.print("Cluster Status\n", .{}) catch return;
    stdout.interface.print("==============\n\n", .{}) catch return;

    stdout.interface.print("Member ID: {d}\n", .{ctx.member_id}) catch return;
    stdout.interface.print("Current Role: {s}\n", .{
        switch (module.role()) {
            .follower => "Follower",
            .leader => "Leader",
            .candidate => "Candidate",
        },
    }) catch return;
    stdout.interface.print("Election State: {s}\n", .{
        switch (module.electionState()) {
            .init => "Init",
            .canvass => "Canvass",
            .follower_ballot => "Follower Ballot",
            .candidate_ballot => "Candidate Ballot",
            .leader_log_replication => "Leader Log Replication",
            .leader_ready => "Leader Ready",
            .follower_ready => "Follower Ready",
        },
    }) catch return;
    stdout.interface.print("Leader Member ID: {d}\n", .{module.leaderMemberId()}) catch return;
    stdout.interface.print("Leadership Term: {d}\n", .{module.leaderShipTermId()}) catch return;

    stdout.interface.print("\nCluster Members\n", .{}) catch return;
    stdout.interface.print("ID  HOST        CLIENT_PORT\n", .{}) catch return;
    stdout.interface.print("--- --------- -----------\n", .{}) catch return;

    for (ctx.cluster_members) |m| {
        stdout.interface.print("{d:>3} {s:<10} {d:>11}\n", .{ m.member_id, m.host, m.client_port }) catch return;
    }

    stdout.interface.print("\nNote: Cluster state is placeholder. Real state comes from cluster state files.\n", .{}) catch return;
}
