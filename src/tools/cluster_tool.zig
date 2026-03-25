// Cluster status display.
// Displays cluster membership, current leader, election state.
// Reads from cluster state files (cluster-members.dat, cluster-election.dat, etc.)
const std = @import("std");
const cluster_mod = @import("../cluster/cluster.zig");
const election_mod = @import("../cluster/election.zig");
const conductor_mod = @import("../cluster/conductor.zig");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    stdout.interface.print("Cluster Status — {s}\n", .{aeron_dir}) catch return;
    stdout.interface.print("=================\n\n", .{}) catch return;

    // Try to open cluster state directory
    var cluster_dir = std.fs.openDirAbsolute(aeron_dir, .{}) catch |err| {
        stdout.interface.print("Could not open aeron directory: {any}\n", .{err}) catch return;
        return;
    };
    defer cluster_dir.close();

    // Check for cluster-members.dat
    const members_file = cluster_dir.openFile("cluster-members.dat", .{}) catch {
        stdout.interface.print("No cluster state found (cluster not active).\n", .{}) catch return;
        return;
    };
    defer members_file.close();

    // Placeholder: read cluster state from files when structures are defined
    // For now, parse basic metadata if available
    const file_size = members_file.getEndPos() catch 0;
    if (file_size > 0) {
        stdout.interface.print("Cluster members file size: {d} bytes\n", .{file_size}) catch return;
        stdout.interface.print("(Cluster state structures not yet fully integrated into tools)\n", .{}) catch return;
    } else {
        stdout.interface.print("Cluster state appears empty.\n", .{}) catch return;
    }

    stdout.interface.print("\nNote: Full cluster state requires cluster-members.dat and election state parsing.\n", .{}) catch return;
}

test "cluster: handles missing cluster state gracefully" {
    const test_dir = "/tmp/harus-aeron-cluster-test";
    defer std.fs.deleteTreeAbsolute(test_dir) catch {};
    try std.fs.makeDirAbsolute(test_dir);

    run(test_dir);
}
