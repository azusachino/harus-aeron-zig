// Aeron Cluster — Log replication for Raft consensus
// Manages log entries, leader replication state, and follower synchronization.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-cluster/src/main/java/io/aeron/cluster/log

const std = @import("std");

// =============================================================================
// LogEntry struct
// =============================================================================

/// LogEntry — a single entry in the cluster log.
pub const LogEntry = struct {
    /// Byte offset in the log where this entry begins
    position: i64,
    /// Cluster timestamp when entry was appended
    timestamp: i64,
    /// Entry payload data (owned by the log)
    data: []const u8,
};

/// LogEntryState — owned snapshot form of a log entry for restart/catch-up flows.
pub const LogEntryState = struct {
    position: i64,
    timestamp: i64,
    data: []u8,
};

/// ClusterLogState — owned snapshot of a cluster log.
pub const ClusterLogState = struct {
    leader_ship_term_id: i64,
    append_position: i64,
    commit_position: i64,
    entries: []LogEntryState,

    pub fn deinit(self: *ClusterLogState, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.data);
        }
        allocator.free(self.entries);
        self.entries = &.{};
    }
};

// =============================================================================
// ClusterLog struct
// =============================================================================

/// ClusterLog — leader-side log for appending entries and tracking commit position.
// LESSON(log-replication): The leader sends AppendRequest; followers ACK with
// AppendPosition; the commit index advances only when a quorum has ACKed.
// See docs/tutorial/06-cluster/03-log-replication.md
pub const ClusterLog = struct {
    /// All log entries
    entries: std.ArrayList(LogEntry),
    /// Next byte offset where new entries will be appended
    append_position: i64 = 0,
    /// Highest position replicated to a quorum of followers
    commit_position: i64 = 0,
    /// Current leadership term
    leader_ship_term_id: i64 = 0,
    /// Memory allocator for heap allocations
    allocator: std.mem.Allocator,

    // =========================================================================
    // Initialization and Cleanup
    // =========================================================================

    /// Initialize a new empty ClusterLog.
    pub fn init(allocator: std.mem.Allocator) ClusterLog {
        return .{
            .entries = .{},
            .append_position = 0,
            .commit_position = 0,
            .leader_ship_term_id = 0,
            .allocator = allocator,
        };
    }

    /// Free all log entries and the entry list.
    pub fn deinit(self: *ClusterLog) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    // =========================================================================
    // Log Operations
    // =========================================================================

    /// Append a new entry to the log.
    /// Deep-copies the data and advances append_position by data.len.
    /// Returns the log position of the appended entry.
    // LESSON(log-replication): Appended entries are first durable on the leader, then
    // replicated to followers via AppendRequest; commit_position lags append_position.
    // See docs/tutorial/06-cluster/03-log-replication.md
    pub fn append(self: *ClusterLog, data: []const u8, timestamp: i64) !i64 {
        const owned_data = try self.allocator.dupe(u8, data);
        const entry = LogEntry{
            .position = self.append_position,
            .timestamp = timestamp,
            .data = owned_data,
        };
        try self.entries.append(self.allocator, entry);
        const prev_position = self.append_position;
        self.append_position += @intCast(data.len);
        return prev_position;
    }

    /// Remove all entries and reset positions.
    pub fn clear(self: *ClusterLog) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.entries.clearRetainingCapacity();
        self.append_position = 0;
        self.commit_position = 0;
        self.leader_ship_term_id = 0;
    }

    /// Get the current append position (next offset for new entries).
    pub fn appendPosition(self: *const ClusterLog) i64 {
        return self.append_position;
    }

    /// Get the current commit position (replicated to a quorum).
    pub fn commitPosition(self: *const ClusterLog) i64 {
        return self.commit_position;
    }

    /// Advance the commit position to min(position, append_position).
    pub fn advanceCommitPosition(self: *ClusterLog, position: i64) void {
        self.commit_position = @min(position, self.append_position);
    }

    /// Get a slice of all entries from the given position onward.
    /// Returns an empty slice if position is at or beyond append_position.
    pub fn entriesFrom(self: *const ClusterLog, position: i64) []const LogEntry {
        if (position >= self.append_position) {
            return &[_]LogEntry{};
        }
        // Find the first entry at or after the given position
        var start_idx: usize = 0;
        for (self.entries.items, 0..) |entry, idx| {
            if (entry.position >= position) {
                start_idx = idx;
                break;
            }
        }
        return self.entries.items[start_idx..];
    }

    /// Find the entry at the exact position, or null if not found.
    pub fn entryAt(self: *const ClusterLog, position: i64) ?LogEntry {
        for (self.entries.items) |entry| {
            if (entry.position == position) {
                return entry;
            }
        }
        return null;
    }

    /// Capture a deep-copy snapshot of the log for recovery and handoff.
    pub fn captureState(self: *const ClusterLog, allocator: std.mem.Allocator) !ClusterLogState {
        var entries = try allocator.alloc(LogEntryState, self.entries.items.len);
        var copied: usize = 0;
        errdefer {
            for (entries[0..copied]) |entry| {
                allocator.free(entry.data);
            }
            allocator.free(entries);
        }

        for (self.entries.items, 0..) |entry, idx| {
            entries[idx] = .{
                .position = entry.position,
                .timestamp = entry.timestamp,
                .data = try allocator.dupe(u8, entry.data),
            };
            copied += 1;
        }

        return .{
            .leader_ship_term_id = self.leader_ship_term_id,
            .append_position = self.append_position,
            .commit_position = self.commit_position,
            .entries = entries,
        };
    }

    /// Restore the log from a previously captured snapshot.
    pub fn restoreState(self: *ClusterLog, state: *const ClusterLogState) !void {
        self.clear();
        self.leader_ship_term_id = state.leader_ship_term_id;

        for (state.entries) |entry| {
            if (entry.position != self.append_position) {
                return error.CorruptLogState;
            }
            _ = try self.append(entry.data, entry.timestamp);
        }

        if (self.append_position != state.append_position) {
            return error.CorruptLogState;
        }

        self.advanceCommitPosition(state.commit_position);
    }

    /// Replace local log contents with the leader's committed view.
    pub fn syncWithLeader(self: *ClusterLog, leader_log: *const ClusterLog) !void {
        var state = try leader_log.captureState(self.allocator);
        defer state.deinit(self.allocator);
        try self.restoreState(&state);
    }
};

// =============================================================================
// FollowerState struct
// =============================================================================

/// FollowerState — tracks a single follower's replication progress from the leader.
pub const FollowerState = struct {
    /// Unique member ID of the follower
    member_id: i32,
    /// Last log position acknowledged by this follower
    append_position: i64 = 0,
    /// Whether this follower has caught up to the leader
    is_caught_up: bool = false,
};

// =============================================================================
// LogLeader struct
// =============================================================================

/// LogLeader — leader-side replication tracker for managing follower synchronization.
pub const LogLeader = struct {
    /// Reference to the cluster log
    log: *ClusterLog,
    /// State of each follower in the cluster
    followers: std.ArrayList(FollowerState),
    /// Total cluster size
    cluster_size: u32,
    /// Memory allocator for heap allocations
    allocator: std.mem.Allocator,

    // =========================================================================
    // Initialization and Cleanup
    // =========================================================================

    /// Initialize a new LogLeader.
    /// Allocates follower states for all members except the leader.
    pub fn init(allocator: std.mem.Allocator, log: *ClusterLog, cluster_size: u32) !LogLeader {
        var followers: std.ArrayList(FollowerState) = .{};
        // Follower IDs are 0..cluster_size excluding the leader (assumed to be self)
        for (0..cluster_size - 1) |i| {
            try followers.append(allocator, .{
                .member_id = @intCast(i),
                .append_position = 0,
                .is_caught_up = false,
            });
        }
        return .{
            .log = log,
            .followers = followers,
            .cluster_size = cluster_size,
            .allocator = allocator,
        };
    }

    /// Free the follower list.
    pub fn deinit(self: *LogLeader) void {
        self.followers.deinit(self.allocator);
    }

    /// Update a follower's append position and check if quorum has advanced.
    pub fn onAppendPosition(self: *LogLeader, follower_member_id: i32, log_position: i64) void {
        for (self.followers.items) |*follower| {
            if (follower.member_id == follower_member_id) {
                follower.append_position = log_position;
                break;
            }
        }
        self.checkCommitAdvance();
    }

    /// Check if a quorum of followers have acknowledged positions that allow commit to advance.
    pub fn checkCommitAdvance(self: *LogLeader) void {
        // Collect all positions: leader's append_position + all followers' append_positions
        var positions: std.ArrayList(i64) = .{};
        defer positions.deinit(self.allocator);

        positions.append(self.allocator, self.log.append_position) catch unreachable;
        for (self.followers.items) |follower| {
            positions.append(self.allocator, follower.append_position) catch unreachable;
        }

        // Sort positions in descending order
        std.mem.sort(i64, positions.items, {}, struct {
            fn compare(_: void, a: i64, b: i64) bool {
                return a > b;
            }
        }.compare);

        // The position at quorum_threshold - 1 is the new commit position
        const quorum_threshold: usize = (self.cluster_size + 1) / 2;
        if (positions.items.len >= quorum_threshold) {
            const new_commit_position = positions.items[quorum_threshold - 1];
            self.log.advanceCommitPosition(new_commit_position);
        }
    }

    /// Look up the state of a specific follower by member ID.
    pub fn followerState(self: *const LogLeader, member_id: i32) ?FollowerState {
        for (self.followers.items) |follower| {
            if (follower.member_id == member_id) {
                return follower;
            }
        }
        return null;
    }
};

// =============================================================================
// LogFollower struct
// =============================================================================

/// LogFollower — follower-side log receiver for replication from the leader.
pub const LogFollower = struct {
    /// Local copy of the replicated log
    log: ClusterLog,
    /// This follower's member ID
    member_id: i32,
    /// The leader's member ID
    leader_member_id: i32,
    /// Memory allocator for heap allocations
    allocator: std.mem.Allocator,

    // =========================================================================
    // Initialization and Cleanup
    // =========================================================================

    /// Initialize a new LogFollower.
    pub fn init(allocator: std.mem.Allocator, member_id: i32) LogFollower {
        return .{
            .log = ClusterLog.init(allocator),
            .member_id = member_id,
            .leader_member_id = 0,
            .allocator = allocator,
        };
    }

    /// Free the local log.
    pub fn deinit(self: *LogFollower) void {
        self.log.deinit();
    }

    /// Process an append request from the leader.
    /// Appends the data to the local log and returns the position for the ACK.
    pub fn onAppendRequest(self: *LogFollower, leader_ship_term_id: i64, data: []const u8, timestamp: i64) !i64 {
        self.log.leader_ship_term_id = leader_ship_term_id;
        return try self.log.append(data, timestamp);
    }

    /// Process a commit position update from the leader.
    pub fn onCommitPosition(self: *LogFollower, position: i64) void {
        self.log.advanceCommitPosition(position);
    }

    /// Replace the follower log with a fresh copy of the leader state.
    pub fn catchUpFromLeader(self: *LogFollower, leader_member_id: i32, leader_log: *const ClusterLog) !void {
        self.leader_member_id = leader_member_id;
        try self.log.syncWithLeader(leader_log);
    }

    /// Get the current append position.
    pub fn appendPosition(self: *const LogFollower) i64 {
        return self.log.appendPosition();
    }

    /// Get the current commit position.
    pub fn commitPosition(self: *const LogFollower) i64 {
        return self.log.commitPosition();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "cluster log append and position tracking" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(i64, 0), log.appendPosition());
    try std.testing.expectEqual(@as(i64, 0), log.commitPosition());

    const pos1 = try log.append("hello", 1000);
    try std.testing.expectEqual(@as(i64, 0), pos1);
    try std.testing.expectEqual(@as(i64, 5), log.appendPosition());

    const pos2 = try log.append("world", 2000);
    try std.testing.expectEqual(@as(i64, 5), pos2);
    try std.testing.expectEqual(@as(i64, 10), log.appendPosition());

    const pos3 = try log.append("test", 3000);
    try std.testing.expectEqual(@as(i64, 10), pos3);
    try std.testing.expectEqual(@as(i64, 14), log.appendPosition());
}

test "cluster log commit advance" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    _ = try log.append("data", 1000);
    _ = try log.append("more", 2000);

    try std.testing.expectEqual(@as(i64, 0), log.commitPosition());
    log.advanceCommitPosition(4);
    try std.testing.expectEqual(@as(i64, 4), log.commitPosition());
    log.advanceCommitPosition(100);
    try std.testing.expectEqual(@as(i64, 8), log.commitPosition());
}

test "cluster log entries from position" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    _ = try log.append("first", 1000);
    _ = try log.append("second", 2000);
    _ = try log.append("third", 3000);

    var slice = log.entriesFrom(0);
    try std.testing.expectEqual(@as(usize, 3), slice.len);

    slice = log.entriesFrom(5);
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(i64, 5), slice[0].position);

    slice = log.entriesFrom(100);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "cluster log entry at position" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    _ = try log.append("a", 1000);
    _ = try log.append("bb", 2000);
    _ = try log.append("ccc", 3000);

    const entry0 = log.entryAt(0);
    try std.testing.expect(entry0 != null);
    try std.testing.expectEqual(@as(i64, 1000), entry0.?.timestamp);

    const entry1 = log.entryAt(1);
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqual(@as(i64, 2000), entry1.?.timestamp);

    const entry_missing = log.entryAt(100);
    try std.testing.expect(entry_missing == null);
}

test "log leader tracks follower positions" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    var leader = try LogLeader.init(std.testing.allocator, &log, 3);
    defer leader.deinit();

    try std.testing.expectEqual(@as(usize, 2), leader.followers.items.len);

    const follower0 = leader.followerState(0);
    try std.testing.expect(follower0 != null);
    try std.testing.expectEqual(@as(i64, 0), follower0.?.append_position);
}

test "log leader quorum commit advance" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    var leader = try LogLeader.init(std.testing.allocator, &log, 3);
    defer leader.deinit();

    // Leader appends entry (position 0, length 5)
    _ = try log.append("entry", 1000);

    // Simulate both followers ACKing position 5
    leader.onAppendPosition(0, 5);
    leader.onAppendPosition(1, 5);

    // Quorum (2 out of 3) should have replicated, so commit advances to 5
    try std.testing.expectEqual(@as(i64, 5), log.commitPosition());
}

test "log follower append request" {
    var follower = LogFollower.init(std.testing.allocator, 1);
    defer follower.deinit();

    const pos = try follower.onAppendRequest(1, "data", 2000);
    try std.testing.expectEqual(@as(i64, 0), pos);
    try std.testing.expectEqual(@as(i64, 4), follower.appendPosition());
}

test "log follower commit position" {
    var follower = LogFollower.init(std.testing.allocator, 1);
    defer follower.deinit();

    _ = try follower.onAppendRequest(1, "data", 1000);
    try std.testing.expectEqual(@as(i64, 0), follower.commitPosition());

    follower.onCommitPosition(4);
    try std.testing.expectEqual(@as(i64, 4), follower.commitPosition());
}

test "full replication simulation" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    var leader = try LogLeader.init(std.testing.allocator, &log, 3);
    defer leader.deinit();

    var follower0 = LogFollower.init(std.testing.allocator, 0);
    defer follower0.deinit();

    var follower1 = LogFollower.init(std.testing.allocator, 1);
    defer follower1.deinit();

    // Leader appends 5 entries
    for (0..5) |i| {
        const data = switch (i) {
            0 => "one",
            1 => "two",
            2 => "three",
            3 => "four",
            4 => "five",
            else => unreachable,
        };
        _ = try log.append(data, @intCast(1000 + i));
    }

    // Each follower appends the same entries and ACKs
    for (0..5) |i| {
        const data = switch (i) {
            0 => "one",
            1 => "two",
            2 => "three",
            3 => "four",
            4 => "five",
            else => unreachable,
        };
        const pos0 = try follower0.onAppendRequest(1, data, @intCast(1000 + i));
        const pos1 = try follower1.onAppendRequest(1, data, @intCast(1000 + i));
        const data_len: i64 = @intCast(data.len);
        leader.onAppendPosition(0, pos0 + data_len);
        leader.onAppendPosition(1, pos1 + data_len);
    }

    // Followers receive commit position updates from the leader
    follower0.onCommitPosition(log.commitPosition());
    follower1.onCommitPosition(log.commitPosition());

    try std.testing.expectEqual(log.appendPosition(), leader.log.appendPosition());
    try std.testing.expectEqual(log.commitPosition(), follower0.commitPosition());
}

test "cluster log deinit frees all entries" {
    const gpa = std.testing.allocator;

    var log = ClusterLog.init(gpa);
    _ = try log.append("entry1", 1000);
    _ = try log.append("entry2", 2000);
    _ = try log.append("entry3", 3000);
    log.deinit();

    // If there are leaks, the test framework will detect them
}

test "cluster log state round trip preserves positions" {
    var log = ClusterLog.init(std.testing.allocator);
    defer log.deinit();

    log.leader_ship_term_id = 7;
    _ = try log.append("alpha", 1000);
    _ = try log.append("beta", 2000);
    log.advanceCommitPosition(9);

    var state = try log.captureState(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var restored = ClusterLog.init(std.testing.allocator);
    defer restored.deinit();
    try restored.restoreState(&state);

    try std.testing.expectEqual(@as(i64, 7), restored.leader_ship_term_id);
    try std.testing.expectEqual(log.appendPosition(), restored.appendPosition());
    try std.testing.expectEqual(log.commitPosition(), restored.commitPosition());
    try std.testing.expectEqualSlices(u8, "alpha", restored.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "beta", restored.entryAt(5).?.data);
}

test "log follower catch up from leader replaces stale local state" {
    var leader = ClusterLog.init(std.testing.allocator);
    defer leader.deinit();
    leader.leader_ship_term_id = 3;
    _ = try leader.append("one", 1000);
    _ = try leader.append("two", 1001);
    leader.advanceCommitPosition(6);

    var follower = LogFollower.init(std.testing.allocator, 1);
    defer follower.deinit();
    _ = try follower.onAppendRequest(1, "old", 900);
    follower.onCommitPosition(3);

    try follower.catchUpFromLeader(0, &leader);

    try std.testing.expectEqual(@as(i32, 0), follower.leader_member_id);
    try std.testing.expectEqual(leader.appendPosition(), follower.appendPosition());
    try std.testing.expectEqual(leader.commitPosition(), follower.commitPosition());
    try std.testing.expectEqualSlices(u8, "one", follower.log.entryAt(0).?.data);
    try std.testing.expectEqualSlices(u8, "two", follower.log.entryAt(3).?.data);
}
