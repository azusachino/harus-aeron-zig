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
const trading = @import("trading");

const INGRESS_STREAM_ID: i32 = 101;
const EGRESS_STREAM_ID: i32 = 102;
const INTERNAL_STREAM_ID: i32 = 103;
const INTERNAL_MAGIC: u32 = 0x5A434C31; // ZCL1
const INTERNAL_HEARTBEAT: u8 = 1;
const INTERNAL_ORDER: u8 = 2;
const JOURNAL_MAX_ORDER_LENGTH: usize = 16 * 1024;

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

    fn init(allocator: std.mem.Allocator, book: *trading.OrderBook, path: []const u8) !Journal {
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
                const order = parseOrder(bytes[offset .. offset + order_length]) catch return error.CorruptJournal;
                _ = book.submit(order) catch return error.CorruptJournal;
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
    leader_member_id: i32,
    endpoints: []const u8,
    book: trading.OrderBook,
    journal: Journal,
    replaying: bool = false,
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    peer_publications: std.ArrayListUnmanaged(PeerPublication) = .empty,
    internal_outputs: std.ArrayListUnmanaged(InternalOutput) = .empty,
    internal_subscription_request_id: i64,
    last_leader_heartbeat_ms: i64,
    election_timeout_ms: i64,
    last_heartbeat_sent_ms: i64 = 0,
    last_connected_peer_count: i32 = -1,
    next_session_id: i64 = 1_000,
    internal_tx_count: u64 = 0,
    internal_rx_count: u64 = 0,
    internal_order_rx_count: u64 = 0,

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
        if (payload.len < 13 or read(u32, payload[0..4]) != INTERNAL_MAGIC) return error.InvalidInternalMessage;
        self.internal_rx_count += 1;
        const kind = payload[4];
        const source_member_id = read(i32, payload[5..9]);
        switch (kind) {
            INTERNAL_HEARTBEAT => {
                const now_ms = aeron.time.milliTimestamp();
                const leader_is_stale = now_ms - self.last_leader_heartbeat_ms >= self.election_timeout_ms;
                if (source_member_id != self.member_id and
                    (source_member_id < self.leader_member_id or leader_is_stale))
                {
                    const previous_leader = self.leader_member_id;
                    self.leader_member_id = source_member_id;
                    if (previous_leader != source_member_id) {
                        std.debug.print("ZIG_CLUSTER_LEADER_CHANGE member={d} leader={d} source=heartbeat\n", .{ self.member_id, source_member_id });
                    }
                }
                if (source_member_id == self.leader_member_id) {
                    self.last_leader_heartbeat_ms = now_ms;
                    if (self.internal_rx_count <= 3) {
                        std.debug.print("ZIG_CLUSTER_INTERNAL_RX member={d} kind=heartbeat source={d}\n", .{ self.member_id, source_member_id });
                    }
                }
            },
            INTERNAL_ORDER => {
                if (source_member_id != self.leader_member_id) return error.StaleInternalLeader;
                if (payload.len < 25) return error.InvalidInternalMessage;
                const order_length = @as(usize, @intCast(read(u32, payload[21..25])));
                if (25 + order_length > payload.len) return error.InvalidInternalMessage;
                _ = self.applyOrder(payload[25 .. 25 + order_length]) catch |err| switch (err) {
                    error.DuplicateOrder => {},
                    else => return err,
                };
                self.internal_order_rx_count += 1;
                if (self.internal_order_rx_count <= 3) {
                    std.debug.print("ZIG_CLUSTER_INTERNAL_RX member={d} kind=order source={d} count={d}\n", .{ self.member_id, source_member_id, self.internal_order_rx_count });
                }
            },
            else => return error.UnsupportedInternalMessage,
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

        const assigned_session_id = if (self.member_id == self.leader_member_id) self.next_session_id else 0;
        if (assigned_session_id != 0) self.next_session_id += 1;
        if (assigned_session_id != 0) {
            try self.sessions.append(self.allocator, .{
                .cluster_session_id = assigned_session_id,
                .publication_request_id = publication_request_id,
            });
        }

        var event_buffer = try self.allocator.alloc(u8, 512);
        errdefer self.allocator.free(event_buffer);
        const code: codecs.EventCode = if (self.member_id == self.leader_member_id) .ok else .redirect;
        const event_length = try codecs.encodeSessionEvent(
            event_buffer,
            assigned_session_id,
            correlation_id,
            1,
            self.leader_member_id,
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
        if (self.member_id != self.leader_member_id or payload.len < codecs.SESSION_HEADER_LENGTH) return;
        const session_id = read(i64, payload[16..24]);
        const order_payload = payload[codecs.SESSION_HEADER_LENGTH..];
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
        try self.queueReplication(order_payload);
    }

    fn applyOrder(self: *Node, order_payload: []const u8) !trading.SubmitResult {
        const order = try parseOrder(order_payload);
        const result = try self.book.submit(order);
        if (!self.replaying) try self.journal.append(order_payload);
        return result;
    }

    fn queueReplication(self: *Node, order_payload: []const u8) !void {
        for (self.peer_publications.items) |peer| {
            const buffer = try self.allocator.alloc(u8, 25 + order_payload.len);
            errdefer self.allocator.free(buffer);
            std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
            buffer[4] = INTERNAL_ORDER;
            std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
            std.mem.writeInt(i64, buffer[9..17], self.next_session_id, .little);
            std.mem.writeInt(i32, buffer[17..21], self.leader_member_id, .little);
            std.mem.writeInt(u32, buffer[21..25], @intCast(order_payload.len), .little);
            @memcpy(buffer[25..], order_payload);
            try self.internal_outputs.append(self.allocator, .{
                .publication_request_id = peer.publication_request_id,
                .buffer = buffer,
            });
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
        if (self.member_id != self.leader_member_id and now_ms - self.last_leader_heartbeat_ms >= self.election_timeout_ms + @as(i64, self.member_id) * 250) {
            self.leader_member_id = self.member_id;
            self.last_leader_heartbeat_ms = now_ms;
            std.debug.print("ZIG_CLUSTER_LEADER_CHANGE member={d} leader={d}\n", .{ self.member_id, self.leader_member_id });
        }
        if (self.member_id == self.leader_member_id and now_ms - self.last_heartbeat_sent_ms >= 100) {
            self.last_heartbeat_sent_ms = now_ms;
            for (self.peer_publications.items) |peer| {
                const buffer = try self.allocator.alloc(u8, 13);
                std.mem.writeInt(u32, buffer[0..4], INTERNAL_MAGIC, .little);
                buffer[4] = INTERNAL_HEARTBEAT;
                std.mem.writeInt(i32, buffer[5..9], self.member_id, .little);
                std.mem.writeInt(i32, buffer[9..13], self.leader_member_id, .little);
                try self.internal_outputs.append(self.allocator, .{
                    .publication_request_id = peer.publication_request_id,
                    .buffer = buffer,
                });
            }
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
    const leader_member_id = envInt("CLUSTER_LEADER_MEMBER_ID", 0);
    const port = envInt("INGRESS_PORT", 9010 + member_id);
    // MediaDriver currently exposes one receive socket. Keep the internal stream
    // on the ingress port by default; deployments may override this only when
    // they provide a driver with multiple receive endpoints.
    const internal_port = envInt("INTERNAL_PORT", port);
    const aeron_dir = env("AERON_DIR", "/dev/shm/aeron");
    const endpoints = env("CLUSTER_ENDPOINTS", "0=zig-node-0:9010,1=zig-node-1:9011,2=zig-node-2:9012");
    const internal_endpoints = env("CLUSTER_INTERNAL_ENDPOINTS", "0=zig-node-0:9010,1=zig-node-1:9011,2=zig-node-2:9012");
    const election_timeout_ms = @as(i64, @intCast(envInt("ELECTION_TIMEOUT_MS", 5_000)));
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
    var journal = try Journal.init(allocator, &book, journal_path);
    errdefer journal.deinit();
    const now_ms = aeron.time.milliTimestamp();
    var node = Node{
        .allocator = allocator,
        .aeron = &client,
        .member_id = member_id,
        .leader_member_id = leader_member_id,
        .endpoints = endpoints,
        .book = book,
        .journal = journal,
        .peer_publications = peer_publications,
        .internal_subscription_request_id = internal_subscription_request,
        .last_leader_heartbeat_ms = now_ms,
        .election_timeout_ms = election_timeout_ms,
    };
    defer node.deinit();

    std.debug.print("ZIG_CLUSTER_REPLAY member={d} orders={d} path={s}\n", .{ member_id, journal.replayed_orders, journal_path });
    std.debug.print("ZIG_CLUSTER_READY member={d} leader={d} ingress={s} internal={s}\n", .{ member_id, leader_member_id, ingress_channel, internal_channel });
    while (true) {
        _ = client.doWork();
        _ = client.poll(subscription_request, onFragment, @ptrCast(&node), 100);
        _ = client.poll(internal_subscription_request, onInternalFragment, @ptrCast(&node), 100);
        try node.tick(aeron.time.milliTimestamp());
        node.flush();
        std.Thread.yield() catch {};
    }
}
