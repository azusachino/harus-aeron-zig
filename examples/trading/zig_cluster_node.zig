//! Networked Zig BTC_USDT cluster sample member.
//!
//! This is the first process-boundary implementation of the Zig cluster
//! sample. It speaks the Java Aeron Cluster client session/egress protocol,
//! runs one deterministic leader, and persists the accepted order stream in
//! each member's mounted journal. The three-member Compose topology is
//! intentionally useful before full consensus replication: followers redirect
//! clients and remain real Aeron processes, while this small election loop is
//! not yet Raft parity.

const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const codecs = aeron.cluster.client_codecs;
const election_mod = aeron.cluster.election;
const Election = election_mod.Election;
const log_mod = aeron.cluster.log;
const cluster_protocol = aeron.cluster.protocol;
const trading = @import("trading");

const INGRESS_STREAM_ID: i32 = 101;
const EGRESS_STREAM_ID: i32 = 102;
const INTERNAL_STREAM_ID: i32 = 103;
const INTERNAL_MAGIC: u32 = 0x5A434C31; // ZCL1
const INTERNAL_HEARTBEAT: u8 = 1;
const INTERNAL_REQUEST_VOTE: u8 = 3;
const INTERNAL_VOTE: u8 = 4;
const INTERNAL_NEW_LEADERSHIP_TERM: u8 = 5;
const INTERNAL_APPEND_REQUEST: u8 = 6;
const INTERNAL_APPEND_POSITION: u8 = 7;
const INTERNAL_COMMIT_POSITION: u8 = 8;
const CLUSTER_SIZE: u32 = 3;
const JOURNAL_MAX_ORDER_LENGTH: usize = 16 * 1024;
// LESSON(log-replication): AppendPosition acks and idle retransmission both run
// on this cadence; slower than the leader heartbeat so retransmission only
// fires once a gap has had time to be closed by a normal in-order append.
const APPEND_ACK_INTERVAL_MS: i64 = 200;
const RETRANSMIT_INTERVAL_MS: i64 = 250;
// Cap entries resent per peer per tick so a badly lagging follower cannot
// make the leader flood the internal channel in one duty cycle.
const MAX_RETRANSMIT_ENTRIES: usize = 64;

fn env(comptime name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.mem.span(value);
}

fn envInt(comptime name: [:0]const u8, fallback: i32) i32 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(i32, std.mem.span(value), 10) catch fallback;
}

fn read(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(bytes.ptr)), .little);
}

fn write(comptime T: type, buffer: []u8, value: T) void {
    std.mem.writeInt(T, @as(*[@sizeOf(T)]u8, @ptrCast(buffer.ptr)), value, .little);
}

fn encodeAppendRequest(buffer: []u8, header: cluster_protocol.AppendRequestHeader) void {
    write(i64, buffer[0..8], header.leader_ship_term_id);
    write(i64, buffer[8..16], header.log_position);
    write(i64, buffer[16..24], header.timestamp);
    write(i32, buffer[24..28], header.leader_member_id);
}

fn decodeAppendRequest(buffer: []const u8) cluster_protocol.AppendRequestHeader {
    return .{
        .leader_ship_term_id = read(i64, buffer[0..8]),
        .log_position = read(i64, buffer[8..16]),
        .timestamp = read(i64, buffer[16..24]),
        .leader_member_id = read(i32, buffer[24..28]),
    };
}

fn encodeAppendPosition(buffer: []u8, header: cluster_protocol.AppendPositionHeader) void {
    write(i64, buffer[0..8], header.leader_ship_term_id);
    write(i64, buffer[8..16], header.log_position);
    write(i32, buffer[16..20], header.follower_member_id);
}

fn decodeAppendPosition(buffer: []const u8) cluster_protocol.AppendPositionHeader {
    return .{
        .leader_ship_term_id = read(i64, buffer[0..8]),
        .log_position = read(i64, buffer[8..16]),
        .follower_member_id = read(i32, buffer[16..20]),
    };
}

fn encodeCommitPosition(buffer: []u8, header: cluster_protocol.CommitPositionHeader) void {
    write(i64, buffer[0..8], header.leader_ship_term_id);
    write(i64, buffer[8..16], header.log_position);
    write(i32, buffer[16..20], header.leader_member_id);
}

fn decodeCommitPosition(buffer: []const u8) cluster_protocol.CommitPositionHeader {
    return .{
        .leader_ship_term_id = read(i64, buffer[0..8]),
        .log_position = read(i64, buffer[8..16]),
        .leader_member_id = read(i32, buffer[16..20]),
    };
}

fn nowNs() i64 {
    return @intCast(aeron.time.nanoTimestamp());
}

fn varField(buffer: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* + 4 > buffer.len) return null;
    const length = @as(usize, @intCast(read(u32, buffer[offset.*..][0..4])));
    offset.* += 4;
    if (offset.* + length > buffer.len) return null;
    const value = buffer[offset.* .. offset.* + length];
    offset.* += length;
    return value;
}

fn endpointFor(member_id: i32, endpoints: []const u8) ?[]const u8 {
    var entries = std.mem.splitScalar(u8, endpoints, ',');
    while (entries.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const parsed_id = std.fmt.parseInt(i32, entry[0..equals], 10) catch continue;
        if (parsed_id == member_id and equals + 1 < entry.len) return entry[equals + 1 ..];
    }
    return null;
}

fn resolveEndpoint(endpoint: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.InvalidPeerEndpoint;
    if (colon == 0 or colon + 1 >= endpoint.len) return error.InvalidPeerEndpoint;
    const port = try std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10);
    _ = try aeron.net.Address.resolveIp(endpoint[0..colon], port);
}

fn waitForPeerEndpoints(member_id: i32, endpoints: []const u8) !void {
    for (0..3) |peer_index| {
        const peer_id: i32 = @intCast(peer_index);
        if (peer_id == member_id) continue;
        const endpoint = endpointFor(peer_id, endpoints) orelse return error.MissingPeerEndpoint;
        var attempts: usize = 0;
        while (attempts < 300) : (attempts += 1) {
            resolveEndpoint(endpoint) catch {
                var delay: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&delay, null);
                continue;
            };
            std.debug.print("ZIG_CLUSTER_PEER_RESOLVED member={d} peer={d} endpoint={s}\n", .{ member_id, peer_id, endpoint });
            break;
        } else return error.PeerEndpointUnavailable;
    }
}

const Output = struct {
    publication_request_id: i64,
    buffer: []u8,
};

const InternalOutput = struct {
    publication_request_id: i64,
    buffer: []u8,
};

const PeerPublication = struct {
    member_id: i32,
    publication_request_id: i64,
    // Leader-side bookkeeping only: highest log position this peer has
    // acked, used to decide what to retransmit and whether quorum commit
    // can advance. Meaningless (and unused) while this node is a follower.
    acked_log_position: i64 = 0,
    last_retransmit_ms: i64 = 0,
};

const Session = struct {
    cluster_session_id: i64,
    publication_request_id: i64,
};

/// Journal — append-only durable order input for the process-boundary sample.
///
/// The journal is intentionally small and explicit: every accepted order is
/// length-prefixed, flushed, and replayed before the node announces readiness.
/// It makes the sample's persistent volume meaningful without pretending to be
/// Aeron Archive or a production snapshot format.
const Journal = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    replayed_orders: usize = 0,

    fn init(allocator: std.mem.Allocator, book: *trading.OrderBook, log: *log_mod.ClusterLog, path: []const u8) !Journal {
        try std.Io.Dir.cwd().createDirPath(aeron.io.io(), std.fs.path.dirname(path) orelse ".");
        var file = std.Io.Dir.cwd().openFile(aeron.io.io(), path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(aeron.io.io(), path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close(aeron.io.io());

        const file_size = @as(usize, @intCast(try file.length(aeron.io.io())));
        if (file_size > 0) {
            const bytes = try allocator.alloc(u8, file_size);
            defer allocator.free(bytes);
            const read_length = try file.readPositionalAll(aeron.io.io(), bytes, 0);
            if (read_length != file_size) return error.IncompleteJournal;

            var replayed_orders: usize = 0;
            var offset: usize = 0;
            while (offset < bytes.len) {
                if (bytes.len - offset < 4) return error.IncompleteJournal;
                const order_length = @as(usize, @intCast(read(u32, bytes[offset..][0..4])));
                offset += 4;
                if (order_length == 0 or order_length > JOURNAL_MAX_ORDER_LENGTH or order_length > bytes.len - offset) {
                    return error.CorruptJournal;
                }
                const order_payload = bytes[offset .. offset + order_length];
                const order = parseOrder(order_payload) catch return error.CorruptJournal;
                _ = book.submit(order) catch return error.CorruptJournal;
                // Replay drives the replication log to the same byte position
                // a live AppendRequest would have reached, so a restarted
                // member reports the correct log_position to peers immediately.
                _ = log.append(order_payload, 0) catch return error.CorruptJournal;
                replayed_orders += 1;
                offset += order_length;
            }
            var writer_buffer: [1]u8 = undefined;
            var writer = file.writer(aeron.io.io(), &writer_buffer);
            try writer.seekTo(file_size);
            return .{ .allocator = allocator, .file = file, .replayed_orders = replayed_orders };
        }
        var writer_buffer: [1]u8 = undefined;
        var writer = file.writer(aeron.io.io(), &writer_buffer);
        try writer.seekTo(file_size);
        return .{ .allocator = allocator, .file = file };
    }

    fn append(self: *Journal, order_payload: []const u8) !void {
        if (order_payload.len == 0 or order_payload.len > JOURNAL_MAX_ORDER_LENGTH) return error.OrderTooLarge;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(order_payload.len), .little);
        try self.file.writeStreamingAll(aeron.io.io(), &length);
        try self.file.writeStreamingAll(aeron.io.io(), order_payload);
        try self.file.sync(aeron.io.io());
    }

    fn deinit(self: *Journal) void {
        self.file.close(aeron.io.io());
    }
};

fn parseOrder(order_payload: []const u8) !trading.Order {
    var fields = std.mem.splitScalar(u8, order_payload, '|');
    const symbol = fields.next() orelse return error.InvalidOrder;
    const order_id = std.fmt.parseInt(u64, fields.next() orelse return error.BadOrderId, 10) catch return error.BadOrderId;
    const side_text = fields.next() orelse return error.BadSide;
    const price = std.fmt.parseInt(i64, fields.next() orelse return error.BadPrice, 10) catch return error.BadPrice;
    const quantity = std.fmt.parseInt(i64, fields.next() orelse return error.BadQuantity, 10) catch return error.BadQuantity;
    if (!std.mem.eql(u8, symbol, trading.SYMBOL)) return error.WrongSymbol;
    const side: trading.Side = if (std.mem.eql(u8, side_text, "BID")) .bid else if (std.mem.eql(u8, side_text, "ASK")) .ask else return error.BadSide;
    return .{ .order_id = order_id, .side = side, .price = price, .quantity = quantity };
}

const Node = struct {
    allocator: std.mem.Allocator,
    aeron: *aeron.Aeron,
    member_id: i32,
    election: Election,
    last_election_state: election_mod.ElectionState = .init,
    endpoints: []const u8,
    book: trading.OrderBook,
    journal: Journal,
    replaying: bool = false,
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    peer_publications: std.ArrayListUnmanaged(PeerPublication) = .empty,
    internal_outputs: std.ArrayListUnmanaged(InternalOutput) = .empty,
    internal_subscription_request_id: i64,
    last_heartbeat_sent_ms: i64 = 0,
    last_connected_peer_count: i32 = -1,
    next_session_id: i64 = 1_000,
    internal_tx_count: u64 = 0,
    internal_rx_count: u64 = 0,
    internal_order_rx_count: u64 = 0,
    // LESSON(log-replication): `log` tracks byte-accurate append/commit
    // positions independent of election.log_position (which counts applied
    // orders, not bytes, and only feeds Raft vote comparisons). Quorum
    // tracking lives on each PeerPublication rather than log.zig's
    // LogLeader, which assumes the leader is always the highest member id.
    log: log_mod.ClusterLog,
    last_append_ack_sent_ms: i64 = 0,
    last_commit_broadcast_position: i64 = -1,

    fn handleFragment(self: *Node, payload: []const u8) !void {
        const header = try codecs.decodeMessageHeader(payload);
        switch (header.template_id) {
            .session_connect_request => try self.handleConnect(payload),
            .session_message_header => try self.handleMessage(payload),
            .session_keep_alive, .session_close_request => {},
            else => return error.UnsupportedClusterMessage,
        }
    }

    fn handleInternalFragment(self: *Node, payload: []const u8) !void {
        if (payload.len < 9 or read(u32, payload[0..4]) != INTERNAL_MAGIC) return error.InvalidInternalMessage;
        self.internal_rx_count += 1;
        const kind = payload[4];
        const source_member_id = read(i32, payload[5..9]);
        const now_ns = nowNs();
        switch (kind) {
            INTERNAL_HEARTBEAT => {
                if (payload.len < 25) return error.InvalidInternalMessage;
                const leadership_term_id = read(i64, payload[9..17]);
                const log_position = read(i64, payload[17..25]);
                self.election.onLeaderHeartbeat(leadership_term_id, log_position, source_member_id, now_ns);
                if (self.internal_rx_count <= 3) {
                    std.debug.print("ZIG_CLUSTER_INTERNAL_RX member={d} kind=heartbeat source={d}\n", .{ self.member_id, source_member_id });
                }
            },
            INTERNAL_REQUEST_VOTE => {
                if (payload.len < 33) return error.InvalidInternalMessage;
                const candidate_term_id = read(i64, payload[9..17]);
                const log_leader_ship_term_id = read(i64, payload[17..25]);
                const log_position = read(i64, payload[25..33]);
                const granted = self.election.onRequestVote(candidate_term_id, log_leader_ship_term_id, log_position, source_member_id, now_ns);
                try self.sendVote(source_member_id, candidate_term_id, granted);
            },
            INTERNAL_VOTE => {
                if (payload.len < 25) return error.InvalidInternalMessage;
                const candidate_term_id = read(i64, payload[9..17]);
                const candidate_member_id = read(i32, payload[17..21]);
                const vote = read(i32, payload[21..25]) != 0;
                self.election.onVote(candidate_term_id, candidate_member_id, source_member_id, vote);
            },
            INTERNAL_NEW_LEADERSHIP_TERM => {
                if (payload.len < 25) return error.InvalidInternalMessage;
                const leader_ship_term_id = read(i64, payload[9..17]);
                const log_position = read(i64, payload[17..25]);
                self.election.onNewLeadershipTerm(leader_ship_term_id, log_position, source_member_id, now_ns);
                std.debug.print("ZIG_CLUSTER_LEADER_CHANGE member={d} leader={d} term={d} source=new_leadership_term\n", .{ self.member_id, source_member_id, leader_ship_term_id });
            },
            INTERNAL_APPEND_REQUEST => {
                if (payload.len < 41) return error.InvalidInternalMessage;
                const header = decodeAppendRequest(payload[9..37]);
                const order_length = @as(usize, @intCast(read(u32, payload[37..41])));
                if (41 + order_length > payload.len) return error.InvalidInternalMessage;
                try self.handleAppendRequest(source_member_id, header, payload[41 .. 41 + order_length]);
            },
            INTERNAL_APPEND_POSITION => {
                if (payload.len < 29) return error.InvalidInternalMessage;
                const header = decodeAppendPosition(payload[9..29]);
                if (self.member_id == self.election.leaderMemberId()) {
                    for (self.peer_publications.items) |*peer| {
                        if (peer.member_id == header.follower_member_id) {
                            peer.acked_log_position = header.log_position;
                            break;
                        }
                    }
                    self.checkCommitAdvance();
                }
            },
            INTERNAL_COMMIT_POSITION => {
                if (payload.len < 29) return error.InvalidInternalMessage;
                const header = decodeCommitPosition(payload[9..29]);
                if (source_member_id == self.election.leaderMemberId()) {
                    self.log.advanceCommitPosition(header.log_position);
                }
            },
            else => return error.UnsupportedInternalMessage,
        }
    }

    /// Apply a leader-replicated log entry. Entries whose position does not
    /// match our current append_position are either duplicates (already
    /// applied — ignored) or a gap (leader will close it via retransmission
    /// once our AppendPosition ack reports our stalled position).
    fn handleAppendRequest(self: *Node, source_member_id: i32, header: cluster_protocol.AppendRequestHeader, order_payload: []const u8) !void {
        if (source_member_id != self.election.leaderMemberId()) return error.StaleInternalLeader;
        if (header.leader_ship_term_id < self.election.leaderShipTermId()) return; // stale term, ignore
        if (header.log_position == self.log.appendPosition()) {
            _ = self.applyOrder(order_payload) catch |err| switch (err) {
                error.DuplicateOrder => {},
                else => return err,
            };
            self.internal_order_rx_count += 1;
            if (self.internal_order_rx_count <= 3) {
                std.debug.print("ZIG_CLUSTER_INTERNAL_RX member={d} kind=append source={d} position={d}\n", .{ self.member_id, source_member_id, header.log_position });
            }
        }
        // Ack our current position either way: on the happy path this
        // reports the newly advanced position; on a gap it reports the
        // stalled position so the leader knows where to resume sending from.
        try self.sendAppendPositionAck(source_member_id);
    }

    /// Recompute commit position from this node's own append position plus
    /// every peer's last-known ack, exactly mirroring log.zig's LogLeader
    /// quorum rule but keyed to the peer set this member actually has
    /// (log.zig's LogLeader wrongly assumes the leader holds the highest
    /// member id in the cluster).
    fn checkCommitAdvance(self: *Node) void {
        var positions: [CLUSTER_SIZE]i64 = undefined;
        var count: usize = 0;
        positions[count] = self.log.appendPosition();
        count += 1;
        for (self.peer_publications.items) |peer| {
            positions[count] = peer.acked_log_position;
            count += 1;
        }
        const slice = positions[0..count];
        std.mem.sort(i64, slice, {}, struct {
            fn greaterThan(_: void, a: i64, b: i64) bool {
                return a > b;
            }
        }.greaterThan);
        const quorum_threshold: usize = (CLUSTER_SIZE / 2) + 1;
        if (slice.len >= quorum_threshold) {
            self.log.advanceCommitPosition(slice[quorum_threshold - 1]);
        }
    }

    fn sendAppendRequestTo(self: *Node, publication_request_id: i64, position: i64, order_payload: []const u8) !void {
        const buffer = try self.allocator.alloc(u8, 41 + order_payload.len);
        errdefer self.allocator.free(buffer);
        std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
        buffer[4] = INTERNAL_APPEND_REQUEST;
        std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
        encodeAppendRequest(buffer[9..37], .{
            .leader_ship_term_id = self.election.leaderShipTermId(),
            .log_position = position,
            .timestamp = nowNs(),
            .leader_member_id = self.member_id,
        });
        std.mem.writeInt(u32, buffer[37..41], @intCast(order_payload.len), .little);
        @memcpy(buffer[41..], order_payload);
        try self.internal_outputs.append(self.allocator, .{
            .publication_request_id = publication_request_id,
            .buffer = buffer,
        });
    }

    fn sendAppendPositionAck(self: *Node, leader_member_id: i32) !void {
        const publication_request_id = self.peerPublicationRequestId(leader_member_id) orelse return;
        const buffer = try self.allocator.alloc(u8, 29);
        std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
        buffer[4] = INTERNAL_APPEND_POSITION;
        std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
        encodeAppendPosition(buffer[9..29], .{
            .leader_ship_term_id = self.election.leaderShipTermId(),
            .log_position = self.log.appendPosition(),
            .follower_member_id = self.member_id,
        });
        try self.internal_outputs.append(self.allocator, .{
            .publication_request_id = publication_request_id,
            .buffer = buffer,
        });
    }

    fn broadcastCommitPosition(self: *Node, position: i64) !void {
        for (self.peer_publications.items) |peer| {
            const buffer = try self.allocator.alloc(u8, 29);
            std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
            buffer[4] = INTERNAL_COMMIT_POSITION;
            std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
            encodeCommitPosition(buffer[9..29], .{
                .leader_ship_term_id = self.election.leaderShipTermId(),
                .log_position = position,
                .leader_member_id = self.member_id,
            });
            try self.internal_outputs.append(self.allocator, .{
                .publication_request_id = peer.publication_request_id,
                .buffer = buffer,
            });
        }
    }

    fn peerPublicationRequestId(self: *const Node, target_member_id: i32) ?i64 {
        for (self.peer_publications.items) |peer| {
            if (peer.member_id == target_member_id) return peer.publication_request_id;
        }
        return null;
    }

    fn sendVote(self: *Node, target_member_id: i32, candidate_term_id: i64, vote: bool) !void {
        const publication_request_id = self.peerPublicationRequestId(target_member_id) orelse return;
        const buffer = try self.allocator.alloc(u8, 25);
        std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
        buffer[4] = INTERNAL_VOTE;
        std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
        std.mem.writeInt(i64, buffer[9..17], candidate_term_id, .little);
        std.mem.writeInt(i32, buffer[17..21], target_member_id, .little);
        std.mem.writeInt(i32, buffer[21..25], if (vote) 1 else 0, .little);
        try self.internal_outputs.append(self.allocator, .{
            .publication_request_id = publication_request_id,
            .buffer = buffer,
        });
    }

    fn broadcastRequestVote(self: *Node) !void {
        for (self.peer_publications.items) |peer| {
            const buffer = try self.allocator.alloc(u8, 33);
            std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
            buffer[4] = INTERNAL_REQUEST_VOTE;
            std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
            std.mem.writeInt(i64, buffer[9..17], self.election.candidate_term_id, .little);
            std.mem.writeInt(i64, buffer[17..25], self.election.leader_ship_term_id, .little);
            std.mem.writeInt(i64, buffer[25..33], self.election.log_position, .little);
            try self.internal_outputs.append(self.allocator, .{
                .publication_request_id = peer.publication_request_id,
                .buffer = buffer,
            });
        }
    }

    fn broadcastNewLeadershipTerm(self: *Node) !void {
        for (self.peer_publications.items) |peer| {
            const buffer = try self.allocator.alloc(u8, 25);
            std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
            buffer[4] = INTERNAL_NEW_LEADERSHIP_TERM;
            std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
            std.mem.writeInt(i64, buffer[9..17], self.election.leaderShipTermId(), .little);
            std.mem.writeInt(i64, buffer[17..25], self.election.log_position, .little);
            try self.internal_outputs.append(self.allocator, .{
                .publication_request_id = peer.publication_request_id,
                .buffer = buffer,
            });
        }
    }

    fn handleConnect(self: *Node, payload: []const u8) !void {
        if (payload.len < codecs.MESSAGE_HEADER_LENGTH + 16) return error.InvalidConnectRequest;
        const correlation_id = read(i64, payload[8..16]);
        const response_stream_id = read(i32, payload[16..20]);
        var offset: usize = 24;
        const response_channel = varField(payload, &offset) orelse return error.InvalidConnectRequest;
        _ = varField(payload, &offset) orelse return error.InvalidConnectRequest;
        _ = varField(payload, &offset) orelse return error.InvalidConnectRequest;

        const response_channel_copy = try self.allocator.dupe(u8, response_channel);
        errdefer self.allocator.free(response_channel_copy);
        const publication_request_id = try self.aeron.addPublication(response_channel_copy, response_stream_id);

        const leader_member_id = self.election.leaderMemberId();
        const assigned_session_id = if (self.member_id == leader_member_id) self.next_session_id else 0;
        if (assigned_session_id != 0) self.next_session_id += 1;
        if (assigned_session_id != 0) {
            try self.sessions.append(self.allocator, .{
                .cluster_session_id = assigned_session_id,
                .publication_request_id = publication_request_id,
            });
        }

        var event_buffer = try self.allocator.alloc(u8, 512);
        errdefer self.allocator.free(event_buffer);
        const code: codecs.EventCode = if (self.member_id == leader_member_id) .ok else .redirect;
        const event_length = try codecs.encodeSessionEvent(
            event_buffer,
            assigned_session_id,
            correlation_id,
            1,
            leader_member_id,
            code,
            self.endpoints,
        );
        event_buffer = try self.allocator.realloc(event_buffer, event_length);
        try self.outputs.append(self.allocator, .{
            .publication_request_id = publication_request_id,
            .buffer = event_buffer,
        });
        self.allocator.free(response_channel_copy);
    }

    fn handleMessage(self: *Node, payload: []const u8) !void {
        if (self.member_id != self.election.leaderMemberId() or payload.len < codecs.SESSION_HEADER_LENGTH) return;
        const session_id = read(i64, payload[16..24]);
        const order_payload = payload[codecs.SESSION_HEADER_LENGTH..];
        const position = self.log.appendPosition();
        const result = self.applyOrder(order_payload) catch |err| switch (err) {
            error.DuplicateOrder => return self.queueResponse(session_id, 0, "REJECTED|duplicate-order"),
            error.InvalidOrder => return self.queueResponse(session_id, 0, "REJECTED|invalid-order"),
            error.WrongSymbol => return self.queueResponse(session_id, 0, "REJECTED|wrong-symbol"),
            error.BadOrderId => return self.queueResponse(session_id, 0, "REJECTED|bad-order-id"),
            error.BadPrice => return self.queueResponse(session_id, 0, "REJECTED|bad-price"),
            error.BadQuantity => return self.queueResponse(session_id, 0, "REJECTED|bad-quantity"),
            error.BadSide => return self.queueResponse(session_id, 0, "REJECTED|bad-side"),
            else => return err,
        };
        var fields = std.mem.splitScalar(u8, order_payload, '|');
        _ = fields.next() orelse return error.InvalidOrder;
        const order_id = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidOrder, 10) catch return error.BadOrderId;

        var result_buffer: [128]u8 = undefined;
        const result_text = try std.fmt.bufPrint(&result_buffer, "FILLED|{d}|RESTING|{d}", .{ result.filled_quantity, result.resting_quantity });
        try self.queueResponse(session_id, order_id, result_text);
        try self.broadcastAppendRequest(position, order_payload);
    }

    fn applyOrder(self: *Node, order_payload: []const u8) !trading.SubmitResult {
        const order = try parseOrder(order_payload);
        const result = try self.book.submit(order);
        if (!self.replaying) try self.journal.append(order_payload);
        _ = try self.log.append(order_payload, nowNs());
        self.election.log_position += 1;
        return result;
    }

    fn broadcastAppendRequest(self: *Node, position: i64, order_payload: []const u8) !void {
        for (self.peer_publications.items) |peer| {
            try self.sendAppendRequestTo(peer.publication_request_id, position, order_payload);
        }
    }

    fn tick(self: *Node, now_ms: i64) !void {
        var connected_peer_count: i32 = 0;
        for (self.peer_publications.items) |peer| {
            if (self.aeron.publicationForRequest(peer.publication_request_id)) |publication| {
                if (publication.isConnected()) connected_peer_count += 1;
            }
        }
        if (connected_peer_count != self.last_connected_peer_count) {
            self.last_connected_peer_count = connected_peer_count;
            std.debug.print("ZIG_CLUSTER_PEERS member={d} connected={d}/{d}\n", .{ self.member_id, connected_peer_count, self.peer_publications.items.len });
        }

        const now_ns = nowNs();
        _ = self.election.doWork(now_ns);
        const state = self.election.currentState();
        if (state != self.last_election_state) {
            switch (state) {
                .candidate_ballot => try self.broadcastRequestVote(),
                .leader_ready => {
                    if (self.last_election_state != .leader_ready) {
                        std.debug.print("ZIG_CLUSTER_LEADER_CHANGE member={d} leader={d} term={d} source=election\n", .{ self.member_id, self.member_id, self.election.leaderShipTermId() });
                        try self.broadcastNewLeadershipTerm();
                        // New term: forget what we thought each peer had
                        // acked so retransmission re-syncs everyone from
                        // wherever they actually are, not wherever the
                        // previous term left off.
                        for (self.peer_publications.items) |*peer| peer.acked_log_position = 0;
                        self.last_commit_broadcast_position = -1;
                    }
                },
                else => {},
            }
            self.last_election_state = state;
        }

        if (self.member_id == self.election.leaderMemberId() and now_ms - self.last_heartbeat_sent_ms >= 100) {
            self.last_heartbeat_sent_ms = now_ms;
            for (self.peer_publications.items) |peer| {
                const buffer = try self.allocator.alloc(u8, 25);
                std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
                buffer[4] = INTERNAL_HEARTBEAT;
                std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
                std.mem.writeInt(i64, buffer[9..17], self.election.leaderShipTermId(), .little);
                std.mem.writeInt(i64, buffer[17..25], self.election.log_position, .little);
                try self.internal_outputs.append(self.allocator, .{
                    .publication_request_id = peer.publication_request_id,
                    .buffer = buffer,
                });
            }
        }

        if (self.member_id == self.election.leaderMemberId()) {
            for (self.peer_publications.items) |*peer| {
                if (peer.acked_log_position < self.log.appendPosition() and now_ms - peer.last_retransmit_ms >= RETRANSMIT_INTERVAL_MS) {
                    peer.last_retransmit_ms = now_ms;
                    var sent: usize = 0;
                    for (self.log.entriesFrom(peer.acked_log_position)) |entry| {
                        if (sent >= MAX_RETRANSMIT_ENTRIES) break;
                        try self.sendAppendRequestTo(peer.publication_request_id, entry.position, entry.data);
                        sent += 1;
                    }
                }
            }
            if (self.log.commitPosition() != self.last_commit_broadcast_position) {
                self.last_commit_broadcast_position = self.log.commitPosition();
                try self.broadcastCommitPosition(self.last_commit_broadcast_position);
            }
        } else if (self.election.leaderMemberId() != -1 and now_ms - self.last_append_ack_sent_ms >= APPEND_ACK_INTERVAL_MS) {
            self.last_append_ack_sent_ms = now_ms;
            try self.sendAppendPositionAck(self.election.leaderMemberId());
        }
    }

    fn queueResponse(self: *Node, session_id: i64, order_id: u64, result: []const u8) !void {
        if (session_id == 0) return error.UnknownSession;
        var publication_request_id: ?i64 = null;
        for (self.sessions.items) |session| {
            if (session.cluster_session_id == session_id) {
                publication_request_id = session.publication_request_id;
                break;
            }
        }
        const response_publication_request_id = publication_request_id orelse return error.UnknownSession;
        var response_text: [256]u8 = undefined;
        const response_payload = try std.fmt.bufPrint(&response_text, "BTC_USDT|{d}|{s}", .{ order_id, result });
        const buffer = try self.allocator.alloc(u8, codecs.SESSION_HEADER_LENGTH + response_payload.len);
        errdefer self.allocator.free(buffer);
        const header_length = try codecs.encodeSessionMessageHeader(buffer, 1, session_id, 0);
        @memcpy(buffer[header_length..], response_payload);
        try self.outputs.append(self.allocator, .{
            .publication_request_id = response_publication_request_id,
            .buffer = buffer,
        });
    }

    fn flush(self: *Node) void {
        var index: usize = 0;
        while (index < self.outputs.items.len) {
            const output = self.outputs.items[index];
            const publication = self.aeron.publicationForRequest(output.publication_request_id) orelse {
                index += 1;
                continue;
            };
            switch (publication.offer(output.buffer)) {
                .ok => {
                    self.allocator.free(output.buffer);
                    _ = self.outputs.swapRemove(index);
                },
                .closed => {
                    self.allocator.free(output.buffer);
                    _ = self.outputs.swapRemove(index);
                },
                else => index += 1,
            }
        }
        var internal_index: usize = 0;
        while (internal_index < self.internal_outputs.items.len) {
            const output = self.internal_outputs.items[internal_index];
            const publication = self.aeron.publicationForRequest(output.publication_request_id) orelse {
                internal_index += 1;
                continue;
            };
            switch (publication.offer(output.buffer)) {
                .ok, .closed => {
                    self.internal_tx_count += 1;
                    if (self.internal_tx_count <= 3) {
                        std.debug.print("ZIG_CLUSTER_INTERNAL_TX member={d} count={d}\n", .{ self.member_id, self.internal_tx_count });
                    }
                    self.allocator.free(output.buffer);
                    _ = self.internal_outputs.swapRemove(internal_index);
                },
                else => internal_index += 1,
            }
        }
    }

    fn deinit(self: *Node) void {
        for (self.outputs.items) |output| self.allocator.free(output.buffer);
        self.outputs.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.internal_outputs.items) |output| self.allocator.free(output.buffer);
        self.internal_outputs.deinit(self.allocator);
        self.peer_publications.deinit(self.allocator);
        self.journal.deinit();
        self.book.deinit();
        self.election.deinit();
        self.log.deinit();
    }
};

fn onFragment(_: *const frame.DataHeader, payload: []const u8, ctx: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(ctx));
    node.handleFragment(payload) catch |err| std.log.warn("zig cluster member={} ignored ingress err={s}", .{ node.member_id, @errorName(err) });
}

fn onInternalFragment(_: *const frame.DataHeader, payload: []const u8, ctx: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(ctx));
    node.handleInternalFragment(payload) catch |err| std.log.warn("zig cluster member={} ignored internal err={s}", .{ node.member_id, @errorName(err) });
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const member_id = envInt("CLUSTER_MEMBER_ID", 0);
    const port = envInt("INGRESS_PORT", 9010 + member_id);
    // MediaDriver currently exposes one receive socket. Keep the internal stream
    // on the ingress port by default; deployments may override this only when
    // they provide a driver with multiple receive endpoints.
    const internal_port = envInt("INTERNAL_PORT", port);
    const aeron_dir = env("AERON_DIR", "/dev/shm/aeron");
    const endpoints = env("CLUSTER_ENDPOINTS", "0=zig-node-0:9010,1=zig-node-1:9011,2=zig-node-2:9012");
    const internal_endpoints = env("CLUSTER_INTERNAL_ENDPOINTS", "0=zig-node-0:9010,1=zig-node-1:9011,2=zig-node-2:9012");
    const ingress_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint=0.0.0.0:{d}", .{port});
    defer allocator.free(ingress_channel);
    const internal_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint=0.0.0.0:{d}", .{internal_port});
    defer allocator.free(internal_channel);
    const journal_path = env("CLUSTER_JOURNAL_PATH", "/data/orders.log");

    try waitForPeerEndpoints(member_id, internal_endpoints);

    const driver = try aeron.driver.MediaDriver.create(allocator, .{ .aeron_dir = aeron_dir });
    // Keep member-local publication session ids disjoint. The current receiver
    // indexes images by (session, stream), so overlapping member ranges would
    // merge two peer links into one image.
    driver.setInitialSessionId(1_000 + member_id * 100);
    try driver.start();
    defer {
        driver.close();
        driver.destroy();
    }
    var client = try aeron.Aeron.init(allocator, .{ .aeron_dir = aeron_dir });
    defer client.deinit();
    client.embedded_driver = driver;
    const subscription_request = try client.addSubscription(ingress_channel, INGRESS_STREAM_ID);
    const internal_subscription_request = try client.addSubscription(internal_channel, INTERNAL_STREAM_ID);
    var peer_publications = std.ArrayListUnmanaged(PeerPublication).empty;
    for (0..3) |peer_index| {
        const peer_id: i32 = @intCast(peer_index);
        if (peer_id == member_id) continue;
        const peer_endpoint = endpointFor(peer_id, internal_endpoints) orelse return error.MissingPeerEndpoint;
        const peer_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint={s}", .{peer_endpoint});
        defer allocator.free(peer_channel);
        const publication_request_id = try client.addPublication(peer_channel, INTERNAL_STREAM_ID);
        try peer_publications.append(allocator, .{
            .member_id = peer_id,
            .publication_request_id = publication_request_id,
        });
    }
    var book = trading.OrderBook.init(allocator);
    errdefer book.deinit();
    var log = log_mod.ClusterLog.init(allocator);
    errdefer log.deinit();
    var journal = try Journal.init(allocator, &book, &log, journal_path);
    errdefer journal.deinit();
    var election = try Election.init(allocator, member_id, CLUSTER_SIZE);
    errdefer election.deinit();
    election.log_position = @intCast(journal.replayed_orders);
    var node = Node{
        .allocator = allocator,
        .aeron = &client,
        .member_id = member_id,
        .election = election,
        .endpoints = endpoints,
        .book = book,
        .journal = journal,
        .peer_publications = peer_publications,
        .internal_subscription_request_id = internal_subscription_request,
        .log = log,
    };
    defer node.deinit();

    std.debug.print("ZIG_CLUSTER_REPLAY member={d} orders={d} path={s}\n", .{ member_id, journal.replayed_orders, journal_path });
    std.debug.print("ZIG_CLUSTER_READY member={d} leader={d} ingress={s} internal={s}\n", .{ member_id, node.election.leaderMemberId(), ingress_channel, internal_channel });
    while (true) {
        _ = client.doWork();
        _ = client.poll(subscription_request, onFragment, @ptrCast(&node), 100);
        _ = client.poll(internal_subscription_request, onInternalFragment, @ptrCast(&node), 100);
        try node.tick(aeron.time.milliTimestamp());
        node.flush();
        std.Thread.yield() catch {};
    }
}
