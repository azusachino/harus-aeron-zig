//! Minimal upstream-compatible Aeron Cluster client.
//!
//! This layer speaks the Java Aeron Cluster SBE session protocol. It intentionally depends on
//! the existing Media Driver client and does not reuse the repository's internal consensus
//! protocol.

const std = @import("std");
const aeron_mod = @import("../aeron.zig");
const codecs = @import("client_codecs.zig");
const publication_mod = @import("../publication.zig");
const frame = @import("../protocol/frame.zig");

pub const Context = struct {
    aeron: *aeron_mod.Aeron,
    allocator: std.mem.Allocator,
    ingress_channel: []const u8 = "aeron:udp",
    ingress_stream_id: i32 = 101,
    egress_channel: []const u8,
    egress_stream_id: i32 = 102,
    response_channel: []const u8,
    protocol_version: i32 = codecs.PROTOCOL_SEMANTIC_VERSION,
    client_info: []const u8 = "harus-aeron-zig",
    encoded_credentials: []const u8 = &.{},
    max_connect_iterations: usize = 100_000,
};

pub const EgressHandler = *const fn (cluster_session_id: i64, timestamp: i64, payload: []const u8, ctx: *anyopaque) void;

pub const AeronCluster = struct {
    aeron: *aeron_mod.Aeron,
    allocator: std.mem.Allocator,
    ingress_publication: *publication_mod.ExclusivePublication,
    egress_subscription_id: i64,
    cluster_session_id: i64,
    leadership_term_id: i64,
    leader_member_id: i32,
    egress_invalid: usize = 0,
    egress_ignored: usize = 0,
    closed: bool = false,

    const ConnectState = struct {
        cluster_session_id: i64 = 0,
        leadership_term_id: i64 = 0,
        leader_member_id: i32 = 0,
        event_code: ?codecs.EventCode = null,
        failed: bool = false,
        redirect_endpoint: [256]u8 = undefined,
        redirect_endpoint_len: usize = 0,
    };

    pub fn connect(ctx: Context) !AeronCluster {
        const subscription_id = try ctx.aeron.addSubscription(ctx.egress_channel, ctx.egress_stream_id);
        errdefer ctx.aeron.removeSubscription(subscription_id) catch {};
        var publication_request_id = try ctx.aeron.addPublication(ctx.ingress_channel, ctx.ingress_stream_id);
        errdefer ctx.aeron.removePublication(publication_request_id) catch {};
        var redirected_channel: ?[]u8 = null;
        defer if (redirected_channel) |channel| ctx.allocator.free(channel);

        var state = ConnectState{};
        var request_buffer: [4096]u8 = undefined;
        var response_channel_buffer: [1024]u8 = undefined;
        var request_sent = false;

        var iteration: usize = 0;
        while (iteration < ctx.max_connect_iterations) : (iteration += 1) {
            _ = ctx.aeron.doWork();

            const publication = ctx.aeron.publicationForRequest(publication_request_id);
            const subscription = ctx.aeron.getSubscription(subscription_id);

            if (!request_sent and publication != null and subscription != null) {
                const response_channel = resolveResponseChannel(ctx, &response_channel_buffer);
                const request_length = try codecs.encodeSessionConnectRequest(
                    &request_buffer,
                    ctx.aeron.clientId(),
                    ctx.egress_stream_id,
                    ctx.protocol_version,
                    response_channel,
                    ctx.encoded_credentials,
                    ctx.client_info,
                );
                switch (publication.?.offer(request_buffer[0..request_length])) {
                    .ok => request_sent = true,
                    .not_connected, .back_pressure, .admin_action => {},
                    .closed => return error.PublicationClosed,
                    .max_position_exceeded => return error.MaxPositionExceeded,
                }
            }

            if (subscription != null) {
                _ = subscription.?.poll(onConnectFragment, @ptrCast(&state), 10);
            }
            if (state.failed) return error.ClusterSessionRejected;
            if (state.event_code) |event_code| {
                if (event_code == .ok) {
                    return .{
                        .aeron = ctx.aeron,
                        .allocator = ctx.allocator,
                        .ingress_publication = publication orelse return error.PublicationNotReady,
                        .egress_subscription_id = subscription_id,
                        .cluster_session_id = state.cluster_session_id,
                        .leadership_term_id = state.leadership_term_id,
                        .leader_member_id = state.leader_member_id,
                    };
                }
                if (event_code == .redirect) {
                    const endpoint = state.redirect_endpoint[0..state.redirect_endpoint_len];
                    const channel = try ctx.allocator.alloc(u8, "aeron:udp?endpoint=".len + endpoint.len);
                    errdefer ctx.allocator.free(channel);
                    @memcpy(channel[0.."aeron:udp?endpoint=".len], "aeron:udp?endpoint=");
                    @memcpy(channel["aeron:udp?endpoint=".len..], endpoint);

                    ctx.aeron.removePublication(publication_request_id) catch {};
                    publication_request_id = try ctx.aeron.addPublication(channel, ctx.ingress_stream_id);
                    if (redirected_channel) |old_channel| ctx.allocator.free(old_channel);
                    redirected_channel = channel;
                    state.event_code = null;
                    state.redirect_endpoint_len = 0;
                    request_sent = false;
                    continue;
                }
                return error.ClusterSessionRejected;
            }
        }
        return error.ConnectTimeout;
    }

    pub fn offer(self: *AeronCluster, payload: []const u8) !publication_mod.OfferResult {
        const buffer = try self.allocator.alloc(u8, codecs.SESSION_HEADER_LENGTH + payload.len);
        defer self.allocator.free(buffer);
        _ = try codecs.encodeSessionMessageHeader(buffer, self.leadership_term_id, self.cluster_session_id, 0);
        @memcpy(buffer[codecs.SESSION_HEADER_LENGTH..], payload);
        return self.ingress_publication.offer(buffer);
    }

    pub fn pollEgress(self: *AeronCluster, handler: EgressHandler, ctx: *anyopaque, fragment_limit: i32) i32 {
        var state = PollState{ .handler = handler, .ctx = ctx, .cluster = self };
        return self.aeron.poll(self.egress_subscription_id, onEgressFragment, @ptrCast(&state), fragment_limit);
    }

    pub fn egressPosition(self: *const AeronCluster) i64 {
        const subscription = self.aeron.getSubscription(self.egress_subscription_id) orelse return 0;
        return subscription.position();
    }

    pub fn egressInvalidCount(self: *const AeronCluster) usize {
        return self.egress_invalid;
    }

    pub fn egressIgnoredCount(self: *const AeronCluster) usize {
        return self.egress_ignored;
    }

    pub fn close(self: *AeronCluster) void {
        if (self.closed) return;
        self.closed = true;
        self.ingress_publication.close();
        if (self.aeron.getSubscription(self.egress_subscription_id)) |subscription| subscription.close();
    }

    const PollState = struct { handler: EgressHandler, ctx: *anyopaque, cluster: *AeronCluster };

    fn onConnectFragment(_: *const frame.DataHeader, buffer: []const u8, ctx_ptr: *anyopaque) void {
        const state: *ConnectState = @ptrCast(@alignCast(ctx_ptr));
        const event = codecs.decodeSessionEvent(buffer) catch {
            state.failed = true;
            return;
        };
        state.cluster_session_id = event.cluster_session_id;
        state.leadership_term_id = event.leadership_term_id;
        state.leader_member_id = event.leader_member_id;
        state.event_code = event.code;
        if (event.code == .redirect) {
            const endpoint = redirectEndpoint(event.detail, event.leader_member_id) orelse {
                state.failed = true;
                return;
            };
            if (endpoint.len > state.redirect_endpoint.len) {
                state.failed = true;
                return;
            }
            @memcpy(state.redirect_endpoint[0..endpoint.len], endpoint);
            state.redirect_endpoint_len = endpoint.len;
        }
    }

    fn onEgressFragment(_: *const frame.DataHeader, buffer: []const u8, ctx_ptr: *anyopaque) void {
        const state: *PollState = @ptrCast(@alignCast(ctx_ptr));
        const header = codecs.decodeMessageHeader(buffer) catch {
            state.cluster.egress_invalid += 1;
            return;
        };
        if (header.template_id != .session_message_header or buffer.len < codecs.SESSION_HEADER_LENGTH) {
            state.cluster.egress_ignored += 1;
            return;
        }
        const cluster_session_id = readI64(buffer[16..24]);
        const timestamp = readI64(buffer[24..32]);
        state.handler(cluster_session_id, timestamp, buffer[codecs.SESSION_HEADER_LENGTH..], state.ctx);
    }

    fn readI64(bytes: []const u8) i64 {
        return std.mem.readInt(i64, @as(*const [8]u8, @ptrCast(bytes.ptr)), .little);
    }

    fn resolveResponseChannel(ctx: Context, buffer: []u8) []const u8 {
        const driver = ctx.aeron.embedded_driver orelse return ctx.response_channel;
        const port = driver.receivePort();
        if (port == 0) return ctx.response_channel;

        const colon = std.mem.lastIndexOfScalar(u8, ctx.response_channel, ':') orelse return ctx.response_channel;
        if (!std.mem.eql(u8, ctx.response_channel[colon + 1 ..], "0")) return ctx.response_channel;
        const prefix = ctx.response_channel[0 .. colon + 1];
        return std.fmt.bufPrint(buffer, "{s}{d}", .{ prefix, port }) catch ctx.response_channel;
    }

    fn redirectEndpoint(detail: []const u8, leader_member_id: i32) ?[]const u8 {
        var fallback: ?[]const u8 = null;
        var entries = std.mem.splitScalar(u8, detail, ',');
        while (entries.next()) |entry| {
            const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            const start = equals + 1;
            if (start >= entry.len) continue;
            if (fallback == null) fallback = entry[start..];
            const member_id = std.fmt.parseInt(i32, entry[0..equals], 10) catch continue;
            if (member_id == leader_member_id) return entry[start..];
        }
        return fallback;
    }
};

test "client exports upstream session header length" {
    try std.testing.expectEqual(@as(usize, 32), codecs.SESSION_HEADER_LENGTH);
}

test "client selects the leader endpoint from a redirect event" {
    const detail = "0=java-node-0:9010,1=java-node-1:9010";
    try std.testing.expectEqualStrings("java-node-1:9010", AeronCluster.redirectEndpoint(detail, 1).?);
}
