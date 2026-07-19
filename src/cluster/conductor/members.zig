//! Cluster peer/member-list management for ClusterConductor: static peer
//! configuration parsing, passive member registration, and answering
//! query_member_list commands with the SBE-shaped active/passive member
//! response (ClusterMembersExtendedResponse, id=43).

const std = @import("std");
const time = @import("../../time.zig");
const protocol_mod = @import("../protocol.zig");
const types = @import("types.zig");
const conductor_mod = @import("../conductor.zig");
const ClusterConductor = conductor_mod.ClusterConductor;

/// Register a known peer member. Replaces any existing entry for the same member_id.
pub fn addPeer(self: *ClusterConductor, peer: types.ActiveMember) !void {
    for (self.peers.items) |*existing| {
        if (existing.member_id == peer.member_id) {
            existing.deinit(self.allocator);
            existing.* = peer;
            return;
        }
    }
    try self.peers.append(self.allocator, peer);
}

/// Add peers from a static clusterMemberEndpoints string.
/// Format: "0,ingress:port,consensus:port,log:port,catchup:port,archive:port|1,..."
/// Matches vendor/aeron io.aeron.cluster.ClusterMember.parse().
pub fn addPeersFromConfig(self: *ClusterConductor, endpoints_string: []const u8) !void {
    var member_iter = std.mem.splitScalar(u8, endpoints_string, '|');
    while (member_iter.next()) |member_str| {
        if (member_str.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, member_str, ',');
        const id_str = field_iter.next() orelse return error.InvalidClusterMember;
        const ingress = field_iter.next() orelse return error.InvalidClusterMember;
        const consensus = field_iter.next() orelse return error.InvalidClusterMember;
        const log_ep = field_iter.next() orelse return error.InvalidClusterMember;
        const catchup = field_iter.next() orelse return error.InvalidClusterMember;
        const archive = field_iter.next() orelse return error.InvalidClusterMember;

        const parsed_member_id = try std.fmt.parseInt(i32, id_str, 10);

        // Skip self — we don't add ourselves to the peer list
        if (parsed_member_id == self.member_id) continue;

        try addPeer(self, .{
            .leadership_term_id = 0,
            .log_position = 0,
            .time_of_last_append_ns = 0,
            .member_id = parsed_member_id,
            .ingress_endpoint = try self.allocator.dupe(u8, ingress),
            .consensus_endpoint = try self.allocator.dupe(u8, consensus),
            .log_endpoint = try self.allocator.dupe(u8, log_ep),
            .catchup_endpoint = try self.allocator.dupe(u8, catchup),
            .archive_endpoint = try self.allocator.dupe(u8, archive),
        });
    }
}

/// Handle add_passive_member command.
/// Parses the 5 comma-separated endpoints and adds the node to the passive_peers list.
pub fn handleAddPassiveMember(self: *ClusterConductor, cmd: types.AddPassiveMemberCmd) !void {
    if (cmd.member_id == self.member_id) return; // Don't add self to passive list

    var field_iter = std.mem.splitScalar(u8, cmd.member_endpoints, ',');
    const ingress = field_iter.next() orelse return error.InvalidClusterMember;
    const consensus = field_iter.next() orelse return error.InvalidClusterMember;
    const log_ep = field_iter.next() orelse return error.InvalidClusterMember;
    const catchup = field_iter.next() orelse return error.InvalidClusterMember;
    const archive = field_iter.next() orelse return error.InvalidClusterMember;

    const peer = types.ActiveMember{
        .leadership_term_id = self.leader_ship_term_id,
        .log_position = self.commit_position,
        .time_of_last_append_ns = @truncate(time.nanoTimestamp()),
        .member_id = cmd.member_id,
        .ingress_endpoint = try self.allocator.dupe(u8, ingress),
        .consensus_endpoint = try self.allocator.dupe(u8, consensus),
        .log_endpoint = try self.allocator.dupe(u8, log_ep),
        .catchup_endpoint = try self.allocator.dupe(u8, catchup),
        .archive_endpoint = try self.allocator.dupe(u8, archive),
    };

    for (self.passive_peers.items) |*existing| {
        if (existing.member_id == cmd.member_id) {
            existing.deinit(self.allocator);
            existing.* = peer;
            return;
        }
    }
    try self.passive_peers.append(self.allocator, peer);
}

/// Handle query_member_list command.
/// Returns a ClusterMembersResponse matching SBE ClusterMembersExtendedResponse (id=43).
/// Passive members are included as per SBE spec.
pub fn handleQueryMemberList(self: *ClusterConductor, cmd: protocol_mod.QueryMemberList) !void {
    const now_ns: i64 = @truncate(time.nanoTimestamp());
    // self + all known peers
    const count = 1 + self.peers.items.len;
    var active = try self.allocator.alloc(types.ActiveMember, count);
    var built: usize = 0;
    errdefer {
        for (active[0..built]) |*m| m.deinit(self.allocator);
        self.allocator.free(active);
    }
    active[0] = types.ActiveMember{
        .leadership_term_id = self.leader_ship_term_id,
        .log_position = self.commit_position,
        .time_of_last_append_ns = now_ns,
        .member_id = self.member_id,
        .ingress_endpoint = try self.allocator.dupe(u8, ""),
        .consensus_endpoint = try self.allocator.dupe(u8, ""),
        .log_endpoint = try self.allocator.dupe(u8, ""),
        .catchup_endpoint = try self.allocator.dupe(u8, ""),
        .archive_endpoint = try self.allocator.dupe(u8, ""),
    };
    built = 1;
    for (self.peers.items, 1..) |*peer, i| {
        active[i] = types.ActiveMember{
            .leadership_term_id = peer.leadership_term_id,
            .log_position = peer.log_position,
            .time_of_last_append_ns = peer.time_of_last_append_ns,
            .member_id = peer.member_id,
            .ingress_endpoint = try self.allocator.dupe(u8, peer.ingress_endpoint),
            .consensus_endpoint = try self.allocator.dupe(u8, peer.consensus_endpoint),
            .log_endpoint = try self.allocator.dupe(u8, peer.log_endpoint),
            .catchup_endpoint = try self.allocator.dupe(u8, peer.catchup_endpoint),
            .archive_endpoint = try self.allocator.dupe(u8, peer.archive_endpoint),
        };
        built += 1;
    }

    const passive_count = self.passive_peers.items.len;
    var passive = try self.allocator.alloc(types.ActiveMember, passive_count);
    var p_built: usize = 0;
    errdefer {
        for (passive[0..p_built]) |*m| m.deinit(self.allocator);
        self.allocator.free(passive);
    }

    for (self.passive_peers.items) |*peer| {
        passive[p_built] = types.ActiveMember{
            .leadership_term_id = peer.leadership_term_id,
            .log_position = peer.log_position,
            .time_of_last_append_ns = peer.time_of_last_append_ns,
            .member_id = peer.member_id,
            .ingress_endpoint = try self.allocator.dupe(u8, peer.ingress_endpoint),
            .consensus_endpoint = try self.allocator.dupe(u8, peer.consensus_endpoint),
            .log_endpoint = try self.allocator.dupe(u8, peer.log_endpoint),
            .catchup_endpoint = try self.allocator.dupe(u8, peer.catchup_endpoint),
            .archive_endpoint = try self.allocator.dupe(u8, peer.archive_endpoint),
        };
        p_built += 1;
    }

    try self.response_queue.append(self.allocator, .{
        .member_list = types.ClusterMembersResponse{
            .correlation_id = cmd.correlation_id,
            .current_time_ns = now_ns,
            .leader_member_id = self.leader_member_id,
            .member_id = self.member_id,
            .active_members = active,
            .passive_members = passive,
        },
    });
}
