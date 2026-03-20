// Aeron Cluster Demo — 3-node in-process simulation
// All nodes run in the same process, communicating through direct function calls

const std = @import("std");
const aeron = @import("aeron");
const cluster = aeron.cluster.consensus;
const election_mod = aeron.cluster.election;
const log_mod = aeron.cluster.log;
const conductor_mod = aeron.cluster.conductor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Aeron Cluster Demo ===\n\n", .{});

    // Phase 1: Create 3 cluster nodes
    std.debug.print("--- Phase 1: Initialize 3-node cluster ---\n", .{});
    const members = [_]cluster.MemberConfig{
        .{ .member_id = 0 },
        .{ .member_id = 1 },
        .{ .member_id = 2 },
    };

    var nodes: [3]cluster.ConsensusModule = undefined;
    for (0..3) |i| {
        nodes[i] = try cluster.ConsensusModule.init(allocator, .{
            .member_id = @intCast(i),
            .cluster_members = &members,
        });
        nodes[i].start();
        std.debug.print("  Node {d} initialized\n", .{i});
    }
    defer for (&nodes) |*n| n.deinit();

    // Phase 2: Run election — advance time through init → canvass → candidate_ballot
    std.debug.print("\n--- Phase 2: Leader Election ---\n", .{});
    var now_ns: i64 = 0;

    // Tick all nodes through init → canvass
    for (&nodes) |*n| _ = try n.doWork(now_ns);
    now_ns += 1000;
    for (0..3) |i| {
        std.debug.print("  Node {d}: state={s}\n", .{ i, @tagName(nodes[i].electionState()) });
    }

    // Advance past canvass timeout (5 seconds) for node 0 to become candidate
    now_ns = election_mod.STARTUP_CANVASS_TIMEOUT_NS + 1;
    for (&nodes) |*n| _ = try n.doWork(now_ns);
    for (0..3) |i| {
        std.debug.print("  Node {d}: state={s}\n", .{ i, @tagName(nodes[i].electionState()) });
    }

    // Nodes 1 and 2 vote for node 0
    // Node 0 is in candidate_ballot, nodes 1,2 receive vote request
    _ = nodes[1].election.onRequestVote(
        nodes[0].election.candidate_term_id,
        nodes[0].election.leader_ship_term_id,
        nodes[0].election.log_position,
        0, // candidate is node 0
    );
    _ = nodes[2].election.onRequestVote(
        nodes[0].election.candidate_term_id,
        nodes[0].election.leader_ship_term_id,
        nodes[0].election.log_position,
        0,
    );

    // Node 0 receives the votes
    nodes[0].election.onVote(nodes[0].election.candidate_term_id, 0, 1, true);
    nodes[0].election.onVote(nodes[0].election.candidate_term_id, 0, 2, true);

    // Tick — node 0 should become leader
    now_ns += 1000;
    for (&nodes) |*n| _ = try n.doWork(now_ns);

    // Notify followers of new leadership term
    nodes[1].election.onNewLeadershipTerm(
        nodes[0].election.leaderShipTermId(),
        nodes[0].election.log_position,
        0,
    );
    nodes[2].election.onNewLeadershipTerm(
        nodes[0].election.leaderShipTermId(),
        nodes[0].election.log_position,
        0,
    );
    now_ns += 1000;
    for (&nodes) |*n| _ = try n.doWork(now_ns);

    std.debug.print("\n  Election result:\n", .{});
    for (0..3) |i| {
        std.debug.print("    Node {d}: {s}, leader={d}\n", .{
            i,
            @tagName(nodes[i].electionState()),
            nodes[i].leaderMemberId(),
        });
    }

    // Phase 3: Client session and message processing
    std.debug.print("\n--- Phase 3: Client Session ---\n", .{});

    // Connect a session to the leader
    const response_channel = try allocator.dupe(u8, "aeron:udp?endpoint=client:40123");
    defer allocator.free(response_channel);

    try nodes[0].enqueueCommand(.{
        .session_connect = .{
            .correlation_id = 1,
            .cluster_session_id = 100,
            .response_stream_id = 1,
            .response_channel = response_channel,
        },
    });
    _ = try nodes[0].doWork(now_ns);

    var response_count: i32 = 0;
    response_count = nodes[0].pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);
    std.debug.print("  Session connected (responses: {d})\n", .{response_count});

    // Phase 4: Log replication
    std.debug.print("\n--- Phase 4: Log Replication ---\n", .{});

    // Create log leader and followers
    var leader_log = log_mod.ClusterLog.init(allocator);
    defer leader_log.deinit();
    var log_leader = try log_mod.LogLeader.init(allocator, &leader_log, 3);
    defer log_leader.deinit();
    var follower0 = log_mod.LogFollower.init(allocator, 1);
    defer follower0.deinit();
    var follower1 = log_mod.LogFollower.init(allocator, 2);
    defer follower1.deinit();

    // Append 5 messages to leader log
    const messages = [_][]const u8{ "hello", "world", "aeron", "cluster", "zig" };
    for (messages, 0..) |msg, idx| {
        const pos = try leader_log.append(msg, @intCast(now_ns + @as(i64, @intCast(idx)) * 1000));
        std.debug.print("  Leader append: \"{s}\" at position {d}\n", .{ msg, pos });

        // Replicate to followers
        const f0_pos = try follower0.onAppendRequest(1, msg, @intCast(now_ns));
        const f1_pos = try follower1.onAppendRequest(1, msg, @intCast(now_ns));
        const data_len: i64 = @intCast(msg.len);
        log_leader.onAppendPosition(1, f0_pos + data_len);
        log_leader.onAppendPosition(2, f1_pos + data_len);
    }

    // Propagate commit position
    follower0.onCommitPosition(leader_log.commitPosition());
    follower1.onCommitPosition(leader_log.commitPosition());

    std.debug.print("\n  Log state:\n", .{});
    std.debug.print("    Leader:     append={d} commit={d}\n", .{ leader_log.appendPosition(), leader_log.commitPosition() });
    std.debug.print("    Follower 1: append={d} commit={d}\n", .{ follower0.appendPosition(), follower0.commitPosition() });
    std.debug.print("    Follower 2: append={d} commit={d}\n", .{ follower1.appendPosition(), follower1.commitPosition() });

    // Phase 5: Leader failover simulation
    std.debug.print("\n--- Phase 5: Leader Failover ---\n", .{});
    std.debug.print("  Killing node 0 (leader)...\n", .{});
    nodes[0].stop();

    // Node 1 times out waiting for leader heartbeat and starts election
    now_ns += election_mod.ELECTION_TIMEOUT_NS + 1;

    // Reset node 1's election to canvass (simulating heartbeat timeout)
    nodes[1].election.state = election_mod.ElectionState.canvass;
    nodes[1].election.election_deadline_ns = now_ns - 1; // already expired
    _ = try nodes[1].doWork(now_ns);

    std.debug.print("  Node 1 state: {s}\n", .{@tagName(nodes[1].electionState())});

    // Node 2 votes for node 1
    _ = nodes[2].election.onRequestVote(
        nodes[1].election.candidate_term_id,
        nodes[1].election.leader_ship_term_id,
        nodes[1].election.log_position,
        1,
    );
    nodes[1].election.onVote(nodes[1].election.candidate_term_id, 1, 2, true);

    now_ns += 1000;
    _ = try nodes[1].doWork(now_ns);

    // Notify node 2 of new leader
    nodes[2].election.onNewLeadershipTerm(
        nodes[1].election.leaderShipTermId(),
        nodes[1].election.log_position,
        1,
    );
    _ = try nodes[2].doWork(now_ns);

    std.debug.print("\n  Failover result:\n", .{});
    for (1..3) |i| {
        std.debug.print("    Node {d}: {s}, leader={d}\n", .{
            i,
            @tagName(nodes[i].electionState()),
            nodes[i].leaderMemberId(),
        });
    }

    // Phase 6: Send message to new leader
    std.debug.print("\n--- Phase 6: Message to New Leader ---\n", .{});
    const msg_data = try allocator.dupe(u8, "post-failover message");
    defer allocator.free(msg_data);

    try nodes[1].enqueueCommand(.{
        .session_message = .{
            .cluster_session_id = 100,
            .timestamp = now_ns,
            .data = msg_data,
        },
    });
    _ = try nodes[1].doWork(now_ns);
    response_count = nodes[1].pollResponses(&struct {
        pub fn handle(_: *const conductor_mod.Response) void {}
    }.handle);
    std.debug.print("  Message committed on new leader (responses: {d})\n", .{response_count});

    std.debug.print("\n=== Demo Complete ===\n\n", .{});
}
