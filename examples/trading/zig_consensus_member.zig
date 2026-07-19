//! Networked Zig member adapter for the authentic Aeron Cluster consensus stream.
//!
//! This process is the mixed-topology stepping stone: it binds one UDP
//! endpoint, subscribes to Java's consensus stream 108, decodes SBE schema
//! 111 frames, and broadcasts typed vote responses to configured peers. It
//! records Java member-control notifications and observes/applies the Java log
//! stream into a local BTC_USDT journal. Catchup transfer, Archive recovery,
//! snapshots, and full clustered-service leadership are still not claimed.

const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const codecs = aeron.cluster.aeron_consensus_codecs;
const adapter_mod = aeron.cluster.aeron_consensus_adapter;
const trading = @import("trading");

const CONSENSUS_STREAM_ID: i32 = 108;
const LOG_STREAM_ID: i32 = 100;

fn env(comptime name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.mem.span(value);
}

fn envInt(comptime name: [:0]const u8, fallback: i32) i32 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(i32, std.mem.span(value), 10) catch fallback;
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

const LogJournal = struct {
    file: std.Io.File,
    entries: usize = 0,

    fn init(path: []const u8) !LogJournal {
        try std.Io.Dir.cwd().createDirPath(aeron.io.io(), std.fs.path.dirname(path) orelse ".");
        var file = std.Io.Dir.cwd().openFile(aeron.io.io(), path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(aeron.io.io(), path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close(aeron.io.io());
        const file_size = @as(usize, @intCast(try file.length(aeron.io.io())));
        var entries: usize = 0;
        var offset: usize = 0;
        var length_buffer: [4]u8 = undefined;
        while (offset < file_size) {
            if (file_size - offset < length_buffer.len) return error.CorruptLogJournal;
            const read_length = try file.readPositionalAll(aeron.io.io(), &length_buffer, offset);
            if (read_length != length_buffer.len) return error.CorruptLogJournal;
            const record_length = @as(usize, @intCast(std.mem.readInt(u32, &length_buffer, .little)));
            if (record_length == 0 or record_length > file_size - offset - length_buffer.len) return error.CorruptLogJournal;
            offset += length_buffer.len + record_length;
            entries += 1;
        }
        var writer_buffer: [1]u8 = undefined;
        var writer = file.writer(aeron.io.io(), &writer_buffer);
        try writer.seekTo(file_size);
        return .{ .file = file, .entries = entries };
    }

    fn append(self: *LogJournal, payload: []const u8) !void {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.len), .little);
        try self.file.writeStreamingAll(aeron.io.io(), &length);
        try self.file.writeStreamingAll(aeron.io.io(), payload);
        try self.file.sync(aeron.io.io());
        self.entries += 1;
    }

    fn replayInto(self: *const LogJournal, allocator: std.mem.Allocator, book: *trading.OrderBook) !usize {
        const file_size = @as(usize, @intCast(try self.file.length(aeron.io.io())));
        var offset: usize = 0;
        var replayed: usize = 0;
        var length_buffer: [4]u8 = undefined;
        while (offset < file_size) {
            const read_length = try self.file.readPositionalAll(aeron.io.io(), &length_buffer, offset);
            if (read_length != length_buffer.len) return error.CorruptLogJournal;
            const record_length = @as(usize, @intCast(std.mem.readInt(u32, &length_buffer, .little)));
            const payload_offset = offset + length_buffer.len;
            if (record_length == 0 or record_length > file_size - payload_offset) return error.CorruptLogJournal;

            const payload = try allocator.alloc(u8, record_length);
            defer allocator.free(payload);
            const payload_length = try self.file.readPositionalAll(aeron.io.io(), payload, payload_offset);
            if (payload_length != record_length) return error.CorruptLogJournal;
            if (applyLogOrder(payload, book) catch false) replayed += 1;
            offset = payload_offset + record_length;
        }
        return replayed;
    }

    fn deinit(self: *LogJournal) void {
        self.file.close(aeron.io.io());
    }
};

fn resolveEndpoint(endpoint: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.InvalidEndpoint;
    const port = try std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10);
    _ = try aeron.net.Address.resolveIp(endpoint[0..colon], port);
}

fn waitForEndpoints(member_id: i32, endpoints: []const u8) !void {
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
            break;
        } else return error.PeerEndpointUnavailable;
    }
}

const Output = struct {
    publication_request_id: i64,
    buffer: []u8,
};

const Node = struct {
    allocator: std.mem.Allocator,
    aeron: *aeron.Aeron,
    adapter: adapter_mod.ConsensusAdapter,
    peer_publication_requests: std.ArrayListUnmanaged(i64) = .empty,
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    member_id: i32,
    rx_count: u64 = 0,
    tx_count: u64 = 0,
    announced_leader: bool = false,
    announced_follower: bool = false,
    announced_image_count: usize = 0,
    announced_votes: u32 = 0,
    append_position_sent: bool = false,
    log_journal: LogJournal,
    book: trading.OrderBook,
    replayed_orders: usize = 0,
    log_rx_count: u64 = 0,
    last_commit_position: i64 = -1,

    fn handle(self: *Node, payload: []const u8) !void {
        self.rx_count += 1;
        const header = codecs.decodeHeader(payload) catch |err| {
            std.log.warn("mixed member={} ignored undecodable consensus frame err={s} len={d}", .{
                self.member_id,
                @errorName(err),
                payload.len,
            });
            return;
        };
        if (self.rx_count <= 20) {
            std.debug.print("ZIG_MIXED_MEMBER_RX member={d} count={d} template={d} len={d} state={s}\n", .{
                self.member_id,
                self.rx_count,
                @intFromEnum(header.template_id),
                payload.len,
                @tagName(self.adapter.election.currentState()),
            });
            if (header.template_id == .request_vote) {
                const request_vote = codecs.decodeRequestVote(payload) catch return;
                std.debug.print("ZIG_MIXED_MEMBER_REQUEST_VOTE member={d} candidate={d} term={d} log_term={d} log_position={d}\n", .{
                    self.member_id,
                    request_vote.candidate_member_id,
                    request_vote.candidate_term_id,
                    request_vote.log_leadership_term_id,
                    request_vote.log_position,
                });
            }
        }
        var response: [256]u8 = undefined;
        const response_length = self.adapter.onMessage(
            payload,
            &response,
            @intCast(aeron.time.nanoTimestamp()),
        ) catch |err| {
            std.log.warn("mixed member={} ignored consensus frame err={s}", .{ self.member_id, @errorName(err) });
            return;
        };
        switch (header.template_id) {
            .append_position => std.debug.print("ZIG_MIXED_MEMBER_APPEND member={d} position={d} follower={d} flags={d}\n", .{
                self.member_id,
                self.adapter.last_append_position.?.log_position,
                self.adapter.last_append_position.?.follower_member_id,
                self.adapter.last_append_position.?.flags,
            }),
            .commit_position => {
                const commit_position = self.adapter.last_commit_position.?.log_position;
                if (commit_position != self.last_commit_position) {
                    self.last_commit_position = commit_position;
                    std.debug.print("ZIG_MIXED_MEMBER_COMMIT member={d} position={d} leader={d}\n", .{
                        self.member_id,
                        commit_position,
                        self.adapter.last_commit_position.?.leader_member_id,
                    });
                }
            },
            .catchup_position => std.debug.print("ZIG_MIXED_MEMBER_CATCHUP member={d} position={d} follower={d} endpoint={s}\n", .{
                self.member_id,
                self.adapter.last_catchup_position.?.log_position,
                self.adapter.last_catchup_position.?.follower_member_id,
                self.adapter.last_catchup_endpoint[0..self.adapter.last_catchup_endpoint_len],
            }),
            .stop_catchup => std.debug.print("ZIG_MIXED_MEMBER_STOP_CATCHUP member={d} follower={d}\n", .{
                self.member_id,
                self.adapter.last_stop_catchup.?.follower_member_id,
            }),
            else => {},
        }
        if (response_length == 0) return;

        for (self.peer_publication_requests.items) |request_id| {
            const buffer = try self.allocator.dupe(u8, response[0..response_length]);
            try self.outputs.append(self.allocator, .{
                .publication_request_id = request_id,
                .buffer = buffer,
            });
        }
        std.debug.print("ZIG_MIXED_MEMBER_RESPONSE member={d} request_template={d} response_len={d} state={s}\n", .{
            self.member_id,
            @intFromEnum(header.template_id),
            response_length,
            @tagName(self.adapter.election.currentState()),
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
                    self.tx_count += 1;
                    if (self.tx_count <= 5) std.debug.print("ZIG_MIXED_MEMBER_TX member={d} count={d}\n", .{ self.member_id, self.tx_count });
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
    }

    fn tick(self: *Node) void {
        const now_ns: i64 = @intCast(aeron.time.nanoTimestamp());
        _ = self.adapter.election.doWork(now_ns);
        if (self.adapter.election.votes_received != self.announced_votes) {
            self.announced_votes = self.adapter.election.votes_received;
            std.debug.print("ZIG_MIXED_MEMBER_VOTES member={d} votes={d} state={s}\n", .{
                self.member_id,
                self.announced_votes,
                @tagName(self.adapter.election.currentState()),
            });
        }
        if (!self.announced_leader and self.adapter.election.currentState() == .leader_ready) {
            self.announced_leader = true;
            std.debug.print("ZIG_MIXED_MEMBER_LEADER member={d} term={d} votes={d}\n", .{
                self.member_id,
                self.adapter.election.leaderShipTermId(),
                self.adapter.election.votes_received,
            });
        }
        if (!self.announced_follower and self.adapter.election.currentState() == .follower_ready) {
            self.announced_follower = true;
            std.debug.print("ZIG_MIXED_MEMBER_FOLLOWER member={d} leader={d} term={d}\n", .{
                self.member_id,
                self.adapter.election.leaderMemberId(),
                self.adapter.election.leaderShipTermId(),
            });
            self.queueAppendPosition() catch |err| {
                std.log.warn("mixed member={} append position send failed err={s}", .{ self.member_id, @errorName(err) });
            };
        }
    }

    fn queueAppendPosition(self: *Node) !void {
        if (self.append_position_sent) return;
        var append_position: [codecs.HEADER_LENGTH + codecs.AppendPositionBlockLength]u8 = undefined;
        const length = try codecs.encodeAppendPosition(&append_position, .{
            .leadership_term_id = self.adapter.election.leaderShipTermId(),
            .log_position = 0,
            .follower_member_id = self.member_id,
            .flags = 0,
        });
        for (self.peer_publication_requests.items) |request_id| {
            try self.outputs.append(self.allocator, .{
                .publication_request_id = request_id,
                .buffer = try self.allocator.dupe(u8, append_position[0..length]),
            });
        }
        self.append_position_sent = true;
        std.debug.print("ZIG_MIXED_MEMBER_APPEND_TX member={d} position=0 follower={d}\n", .{ self.member_id, self.member_id });
    }

    fn handleLog(self: *Node, payload: []const u8) !void {
        if (payload.len < 8) return error.InvalidLogFrame;
        const block_length = std.mem.readInt(u16, payload[0..2], .little);
        const template_id = std.mem.readInt(u16, payload[2..4], .little);
        const schema_id = std.mem.readInt(u16, payload[4..6], .little);
        if (schema_id != codecs.SCHEMA_ID) return error.SchemaMismatch;
        const body_end = 8 + @as(usize, block_length);
        if (body_end > payload.len) return error.InvalidLogFrame;
        try self.log_journal.append(payload);
        self.log_rx_count += 1;

        if (template_id == 1 and block_length >= 24) {
            const session_id = std.mem.readInt(i64, payload[16..24], .little);
            const application_payload = payload[body_end..];
            var applied = false;
            if (applyLogOrder(payload, &self.book)) |value| {
                applied = value;
            } else |err| {
                std.log.warn("mixed member={} rejected log order err={s}", .{ self.member_id, @errorName(err) });
            }
            std.debug.print("ZIG_MIXED_MEMBER_ORDER_RX member={d} count={d} session={d} payload={s}\n", .{
                self.member_id,
                self.log_rx_count,
                session_id,
                application_payload,
            });
            if (applied) {
                std.debug.print("ZIG_MIXED_MEMBER_ORDER_APPLIED member={d} bids={d} asks={d}\n", .{
                    self.member_id,
                    self.book.bids.items.len,
                    self.book.asks.items.len,
                });
            }
        } else if (self.log_rx_count <= 10) {
            std.debug.print("ZIG_MIXED_MEMBER_LOG_RX member={d} template={d} len={d} body={d} payload={d}\n", .{
                self.member_id,
                template_id,
                payload.len,
                block_length,
                payload.len - body_end,
            });
        }
    }

    fn deinit(self: *Node) void {
        self.adapter.deinit();
        self.peer_publication_requests.deinit(self.allocator);
        for (self.outputs.items) |output| self.allocator.free(output.buffer);
        self.outputs.deinit(self.allocator);
        self.book.deinit();
    }
};

fn parseOrder(payload: []const u8) !trading.Order {
    var fields = std.mem.splitScalar(u8, payload, '|');
    const symbol = fields.next() orelse return error.InvalidOrderPayload;
    if (!std.mem.eql(u8, symbol, trading.SYMBOL)) return error.InvalidOrderPayload;
    const order_id = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidOrderPayload, 10);
    const side_text = fields.next() orelse return error.InvalidOrderPayload;
    const side: trading.Side = if (std.mem.eql(u8, side_text, "BID")) .bid else if (std.mem.eql(u8, side_text, "ASK")) .ask else return error.InvalidOrderPayload;
    const price = try std.fmt.parseInt(i64, fields.next() orelse return error.InvalidOrderPayload, 10);
    const quantity = try std.fmt.parseInt(i64, fields.next() orelse return error.InvalidOrderPayload, 10);
    if (fields.next() != null) return error.InvalidOrderPayload;
    return .{ .order_id = order_id, .side = side, .price = price, .quantity = quantity };
}

fn applyLogOrder(payload: []const u8, book: *trading.OrderBook) !bool {
    if (payload.len < 8) return error.InvalidLogFrame;
    const block_length = std.mem.readInt(u16, payload[0..2], .little);
    const template_id = std.mem.readInt(u16, payload[2..4], .little);
    const body_end = 8 + @as(usize, block_length);
    if (body_end > payload.len) return error.InvalidLogFrame;
    if (template_id != 1 or block_length < 24) return false;
    _ = try book.submit(try parseOrder(payload[body_end..]));
    return true;
}

fn onFragment(_: *const frame.DataHeader, payload: []const u8, context: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(context));
    node.handle(payload) catch |err| std.log.warn("mixed member fragment error={s}", .{@errorName(err)});
}

fn onLogFragment(_: *const frame.DataHeader, payload: []const u8, context: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(context));
    node.handleLog(payload) catch |err| std.log.warn("mixed member log fragment error={s}", .{@errorName(err)});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const member_id = envInt("CLUSTER_MEMBER_ID", 2);
    const port = envInt("CONSENSUS_PORT", 9012);
    const endpoints = env("CLUSTER_CONSENSUS_ENDPOINTS", "0=java-node-0:9011,1=java-node-1:9011,2=zig-node-2:9012");
    const aeron_dir = env("AERON_DIR", "/dev/shm/aeron");
    const log_journal_path = env("LOG_JOURNAL_PATH", "/data/mixed-log.bin");
    try waitForEndpoints(member_id, endpoints);

    const driver = try aeron.driver.MediaDriver.create(allocator, .{
        .aeron_dir = aeron_dir,
        .listen_port = @intCast(port),
    });
    driver.setInitialSessionId(3_000 + member_id * 100);
    try driver.start();
    defer {
        driver.close();
        driver.destroy();
    }
    var client = try aeron.Aeron.init(allocator, .{ .aeron_dir = aeron_dir });
    defer client.deinit();
    client.embedded_driver = driver;

    const channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint=0.0.0.0:{d}", .{port});
    defer allocator.free(channel);
    const subscription_request = try client.addSubscription(channel, CONSENSUS_STREAM_ID);
    const log_subscription_request = try client.addSubscription(channel, LOG_STREAM_ID);
    var peer_requests = std.ArrayListUnmanaged(i64).empty;
    defer peer_requests.deinit(allocator);
    for (0..3) |peer_index| {
        const peer_id: i32 = @intCast(peer_index);
        if (peer_id == member_id) continue;
        const endpoint = endpointFor(peer_id, endpoints) orelse return error.MissingPeerEndpoint;
        const peer_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint={s}", .{endpoint});
        defer allocator.free(peer_channel);
        try peer_requests.append(allocator, try client.addPublication(peer_channel, CONSENSUS_STREAM_ID));
    }

    var node = Node{
        .allocator = allocator,
        .aeron = &client,
        .adapter = try adapter_mod.ConsensusAdapter.init(allocator, member_id, 3),
        .peer_publication_requests = peer_requests,
        .member_id = member_id,
        .log_journal = try LogJournal.init(log_journal_path),
        .book = trading.OrderBook.init(allocator),
    };
    peer_requests = .empty;
    defer node.deinit();
    node.replayed_orders = try node.log_journal.replayInto(allocator, &node.book);

    // Join Java's startup canvass with the real SBE template. Without this,
    // the Zig process can answer a ballot but never advertises its own log
    // position, so an authentic three-member election cannot converge.
    var canvass: [codecs.HEADER_LENGTH + codecs.CanvassPositionBlockLength]u8 = undefined;
    const canvass_length = try codecs.encodeCanvassPosition(&canvass, .{
        .log_leadership_term_id = node.adapter.election.leader_ship_term_id,
        .log_position = 0,
        .leadership_term_id = 0,
        .follower_member_id = member_id,
        .protocol_version = 15,
    });
    for (node.peer_publication_requests.items) |request_id| {
        try node.outputs.append(allocator, .{
            .publication_request_id = request_id,
            .buffer = try allocator.dupe(u8, canvass[0..canvass_length]),
        });
    }
    // Start one authentic candidate ballot so Java members can respond with
    // SBE Vote messages. The full implementation will replace this bootstrap
    // with the persistent canvass/election timer and leadership-term flow.
    _ = node.adapter.election.doWork(0);
    _ = node.adapter.election.doWork(5_000_000_001);
    var request_vote: [codecs.HEADER_LENGTH + codecs.RequestVoteBlockLength]u8 = undefined;
    const request_vote_length = try codecs.encodeRequestVote(&request_vote, .{
        .log_leadership_term_id = node.adapter.election.leader_ship_term_id,
        .log_position = 0,
        .candidate_term_id = node.adapter.election.candidate_term_id,
        .candidate_member_id = member_id,
        .protocol_version = 15,
    });
    for (node.peer_publication_requests.items) |request_id| {
        try node.outputs.append(allocator, .{
            .publication_request_id = request_id,
            .buffer = try allocator.dupe(u8, request_vote[0..request_vote_length]),
        });
    }
    defer node.log_journal.deinit();
    std.debug.print("ZIG_MIXED_MEMBER_READY member={d} consensus_port={d} consensus_stream={d} log_stream={d} log_journal={s} log_entries={d} replayed_orders={d} bids={d} asks={d}\n", .{ member_id, port, CONSENSUS_STREAM_ID, LOG_STREAM_ID, log_journal_path, node.log_journal.entries, node.replayed_orders, node.book.bids.items.len, node.book.asks.items.len });
    while (true) {
        const client_work = client.doWork();
        if (client_work > 0) {
            std.debug.print("ZIG_MIXED_MEMBER_CLIENT_WORK member={d} work={d}\n", .{ member_id, client_work });
        }
        if (client.getSubscription(subscription_request)) |subscription| {
            if (subscription.images().len != node.announced_image_count) {
                node.announced_image_count = subscription.images().len;
                std.debug.print("ZIG_MIXED_MEMBER_IMAGES member={d} count={d}\n", .{ member_id, node.announced_image_count });
            }
        }
        _ = client.poll(subscription_request, onFragment, @ptrCast(&node), 100);
        _ = client.poll(log_subscription_request, onLogFragment, @ptrCast(&node), 100);
        node.tick();
        node.flush();
        std.Thread.yield() catch {};
    }
}
