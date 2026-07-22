//! Zig AeronCluster client talking to the official Java Aeron Cluster.

const std = @import("std");
const aeron = @import("aeron");

fn envOr(comptime name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.mem.span(value);
}

const Responses = struct {
    count: usize = 0,
    expected_start: usize = 1_000_001,
    seen: []bool = &.{},
    malformed: usize = 0,
    duplicate: usize = 0,
};

fn onResponse(_: i64, _: i64, payload: []const u8, ctx_ptr: *anyopaque) void {
    const responses: *Responses = @ptrCast(@alignCast(ctx_ptr));
    responses.count += 1;
    var fields = std.mem.splitScalar(u8, payload, '|');
    _ = fields.next();
    const order_id = fields.next() orelse {
        responses.malformed += 1;
        return;
    };
    const parsed = std.fmt.parseInt(usize, order_id, 10) catch {
        responses.malformed += 1;
        return;
    };
    if (parsed < responses.expected_start or parsed - responses.expected_start >= responses.seen.len) {
        responses.malformed += 1;
        return;
    }
    const index = parsed - responses.expected_start;
    if (responses.seen[index]) responses.duplicate += 1;
    responses.seen[index] = true;
}

fn envUsize(comptime name: [:0]const u8, fallback: usize) usize {
    const value = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(usize, std.mem.span(value), 10) catch fallback;
}

fn envI64(comptime name: [:0]const u8, fallback: i64) i64 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(i64, std.mem.span(value), 10) catch fallback;
}

fn envBool(comptime name: [:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1") or std.mem.eql(u8, std.mem.span(value), "true");
}

const PerfStats = struct {
    offer_calls: usize = 0,
    offers_ok: usize = 0,
    not_connected: usize = 0,
    back_pressure: usize = 0,
    admin_action: usize = 0,
    yields: usize = 0,
    do_work_calls: usize = 0,
    do_work_items: usize = 0,
    do_work_ns: i128 = 0,
    poll_calls: usize = 0,
    poll_fragments: usize = 0,
    poll_ns: i128 = 0,
    offer_ns: i128 = 0,
};

fn printMissingResponses(responses: *const Responses) void {
    var missing: usize = 0;
    for (responses.seen, 0..) |was_seen, index| {
        if (!was_seen and missing < 16) {
            std.debug.print("ZIG_CLUSTER_CLIENT_MISSING order_id={d}\n", .{responses.expected_start + index});
            missing += 1;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const aeron_dir = envOr("AERON_DIR", "/tmp/aeron-zig-cluster-client");
    const ingress_endpoints = envOr(
        "INGRESS_ENDPOINTS",
        envOr("INGRESS_ENDPOINT", "java-node-0:9010,java-node-1:9010,java-node-2:9010"),
    );
    const response_channel = envOr("RESPONSE_CHANNEL", "aeron:udp?endpoint=zig-client:0");

    const driver = try aeron.driver.MediaDriver.create(allocator, .{ .aeron_dir = aeron_dir });
    try driver.start();
    defer {
        driver.close();
        driver.destroy();
    }

    var client = try aeron.Aeron.init(allocator, .{ .aeron_dir = aeron_dir });
    defer client.deinit();
    client.embedded_driver = driver;

    const start_delay_ms = envUsize("START_DELAY_MS", 0);
    if (start_delay_ms > 0) {
        var delay: std.c.timespec = .{
            .sec = @intCast(start_delay_ms / 1000),
            .nsec = @intCast((start_delay_ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&delay, null);
    }

    var cluster: aeron.cluster.client.AeronCluster = undefined;
    var connected = false;
    var last_connect_error: anyerror = error.ConnectTimeout;
    var endpoint_iterator = std.mem.splitScalar(u8, ingress_endpoints, ',');
    while (endpoint_iterator.next()) |ingress_endpoint| {
        if (ingress_endpoint.len == 0) continue;
        const ingress_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint={s}", .{ingress_endpoint});
        defer allocator.free(ingress_channel);
        cluster = aeron.cluster.client.AeronCluster.connect(.{
            .aeron = &client,
            .allocator = allocator,
            .ingress_channel = ingress_channel,
            .egress_channel = response_channel,
            .response_channel = response_channel,
            .max_connect_iterations = envUsize("CONNECT_MAX_ITERATIONS", 100_000),
            .connect_timeout_ms = envI64("CONNECT_TIMEOUT_MS", 30_000),
        }) catch |err| {
            last_connect_error = err;
            std.debug.print("ZIG_CLUSTER_CLIENT_CONNECT_RETRY error={s} ingress={s} status_received={d} status_sent={d} data_frames={d} data_before_image={d} insert_failures={d} nak_sent={d}\n", .{
                @errorName(err),
                ingress_endpoint,
                driver.receiver_agent.statusMessagesReceived(),
                driver.receiver_agent.statusMessagesSent(),
                driver.receiver_agent.dataFramesTotal(),
                driver.receiver_agent.dataFramesBeforeImage(),
                driver.receiver_agent.insertFailures(),
                driver.receiver_agent.nakFramesSent(),
            });
            continue;
        };
        connected = true;
        break;
    }
    if (!connected) return last_connect_error;
    defer cluster.close();

    const order_count = envUsize("ORDER_COUNT", 3);
    if (order_count == 0) return error.InvalidOrderCount;
    const response_seen = try allocator.alloc(bool, order_count);
    defer allocator.free(response_seen);
    @memset(response_seen, false);
    var responses = Responses{ .seen = response_seen };
    const trace_perf = envBool("TRACE_PERF");
    var perf = PerfStats{};
    const offer_timeout_ms = envUsize("OFFER_TIMEOUT_MS", 60_000);
    const offer_deadline = aeron.time.milliTimestamp() + @as(i64, @intCast(offer_timeout_ms));
    const publish_start_ms = aeron.time.milliTimestamp();
    var retry_started_ms: i64 = 0;
    var last_stall_report_ms = publish_start_ms;
    var last_keep_alive_ms = publish_start_ms;
    for (0..order_count) |index| {
        // Keep the Zig client namespace disjoint from the Java baseline client.
        const order_id = 1_000_001 + index;
        const side: []const u8 = if (index % 2 == 0) "ASK" else "BID";
        const price: usize = if (index % 2 == 0) 10100 else 10050;
        const quantity: usize = if (index % 2 == 0) 10 else 4;
        var order_buf: [64]u8 = undefined;
        const order = try std.fmt.bufPrint(&order_buf, "BTC_USDT|{d}|{s}|{d}|{d}", .{ order_id, side, price, quantity });
        while (true) {
            if (aeron.time.milliTimestamp() >= offer_deadline) return error.OfferTimeout;
            const work_start_ns = if (trace_perf) aeron.time.nanoTimestamp() else 0;
            const work_count = client.doWork();
            if (trace_perf) {
                perf.do_work_calls += 1;
                perf.do_work_items += @intCast(@max(work_count, 0));
                perf.do_work_ns += aeron.time.nanoTimestamp() - work_start_ns;
            }
            const poll_start_ns = if (trace_perf) aeron.time.nanoTimestamp() else 0;
            const poll_count = cluster.pollEgress(onResponse, @ptrCast(&responses), 10);
            if (trace_perf) {
                perf.poll_calls += 1;
                perf.poll_fragments += @intCast(@max(poll_count, 0));
                perf.poll_ns += aeron.time.nanoTimestamp() - poll_start_ns;
            }
            const now_ms = aeron.time.milliTimestamp();
            if (now_ms - last_keep_alive_ms >= 1_000) {
                _ = try cluster.sendKeepAlive();
                last_keep_alive_ms = now_ms;
            }
            const offer_start_ns = if (trace_perf) aeron.time.nanoTimestamp() else 0;
            const offer_result = cluster.offer(order) catch |err| {
                if (err == error.ClusterSessionClosed) {
                    std.debug.print("ZIG_CLUSTER_CLIENT_SESSION_CLOSED sent={d} responses={d} malformed={d} duplicate={d} ingress_position={d} publisher_limit={d} egress_position={d} invalid_egress={d} buffer_too_small={d} invalid_template={d} ignored_egress={d} last_ignored_template={d} last_ignored_length={d} last_ignored_bytes={any} zero_payload_frames={d} padding_frames={d} last_padding_term={d} last_padding_offset={d} last_padding_length={d} term_buffer_clears={d} last_clear_old_term={d} last_clear_new_term={d} last_clear_subscriber={d}\n", .{
                        index,
                        responses.count,
                        responses.malformed,
                        responses.duplicate,
                        cluster.ingress_publication.position(),
                        cluster.ingress_publication.publisherLimit(),
                        cluster.egressPosition(),
                        cluster.egressInvalidCount(),
                        cluster.egressBufferTooSmallCount(),
                        cluster.egressInvalidTemplateCount(),
                        cluster.egressIgnoredCount(),
                        cluster.egressLastIgnoredTemplate(),
                        cluster.egressLastIgnoredLength(),
                        cluster.egressLastIgnoredBytes(),
                        driver.receiver_agent.zeroPayloadFrames(),
                        driver.receiver_agent.paddingFramesReceived(),
                        driver.receiver_agent.lastPaddingTermId(),
                        driver.receiver_agent.lastPaddingTermOffset(),
                        driver.receiver_agent.lastPaddingLength(),
                        driver.receiver_agent.termBufferClears(),
                        driver.receiver_agent.lastClearOldTermId(),
                        driver.receiver_agent.lastClearNewTermId(),
                        driver.receiver_agent.lastClearSubscriberPosition(),
                    });
                    std.debug.print("ZIG_CLUSTER_CLIENT_STATUS_DIAGNOSTICS status_received={d} status_applied={d} status_sent={d} status_last_session={d} status_last_stream={d} status_last_term={d} status_last_offset={d} status_last_window={d} status_last_limit={d} receiver_last_stream={d} receiver_last_position={d} receiver_last_rebuild={d} receiver_last_subscriber={d} data_frames={d} data_before_image={d} insert_failures={d} nak_sent={d}\n", .{
                        driver.receiver_agent.statusMessagesReceived(),
                        driver.sender_agent.statusMessagesApplied(),
                        driver.receiver_agent.statusMessagesSent(),
                        driver.sender_agent.lastStatusSessionId(),
                        driver.sender_agent.lastStatusStreamId(),
                        driver.sender_agent.lastStatusTermId(),
                        driver.sender_agent.lastStatusTermOffset(),
                        driver.sender_agent.lastStatusWindow(),
                        driver.sender_agent.lastStatusLimit(),
                        driver.receiver_agent.lastStatusStreamId(),
                        driver.receiver_agent.lastStatusPosition(),
                        driver.receiver_agent.lastStatusRebuildPosition(),
                        driver.receiver_agent.lastStatusSubscriberPosition(),
                        driver.receiver_agent.dataFramesTotal(),
                        driver.receiver_agent.dataFramesBeforeImage(),
                        driver.receiver_agent.insertFailures(),
                        driver.receiver_agent.nakFramesSent(),
                    });
                    std.debug.print("ZIG_CLUSTER_CLIENT_SENDER_DIAGNOSTICS data_frames_sent={d} last_sent_term={d} last_sent_offset={d} last_sent_length={d} stale_frames_skipped={d} last_expected_term={d} last_expected_offset={d} retransmit_requests={d} retransmits_sent={d} last_retransmit_term={d} last_retransmit_offset={d} last_retransmit_length={d} last_retransmit_source_port={d} last_retransmit_frame_term={d} last_retransmit_frame_offset={d} last_retransmit_frame_session={d} last_retransmit_frame_stream={d} last_retransmit_frame_length={d}\n", .{
                        driver.sender_agent.dataFramesSent(),
                        driver.sender_agent.lastSentTermId(),
                        driver.sender_agent.lastSentTermOffset(),
                        driver.sender_agent.lastSentFrameLength(),
                        driver.sender_agent.staleFramesSkipped(),
                        driver.sender_agent.lastExpectedTermId(),
                        driver.sender_agent.lastExpectedTermOffset(),
                        driver.sender_agent.retransmitRequests(),
                        driver.sender_agent.retransmitsSent(),
                        driver.sender_agent.lastRetransmitTermId(),
                        driver.sender_agent.lastRetransmitTermOffset(),
                        driver.sender_agent.lastRetransmitLength(),
                        driver.sender_agent.lastRetransmitSourcePort(),
                        driver.sender_agent.lastRetransmitFrameTermId(),
                        driver.sender_agent.lastRetransmitFrameTermOffset(),
                        driver.sender_agent.lastRetransmitFrameSessionId(),
                        driver.sender_agent.lastRetransmitFrameStreamId(),
                        driver.sender_agent.lastRetransmitFrameLength(),
                    });
                    printMissingResponses(&responses);
                }
                return err;
            };
            if (trace_perf) {
                perf.offer_calls += 1;
                perf.offer_ns += aeron.time.nanoTimestamp() - offer_start_ns;
            }
            const is_retry = switch (offer_result) {
                .ok => false,
                else => true,
            };
            if (trace_perf and is_retry) {
                const report_now_ms = aeron.time.milliTimestamp();
                if (retry_started_ms == 0) retry_started_ms = report_now_ms;
                if (report_now_ms - last_stall_report_ms >= 1_000) {
                    std.debug.print("ZIG_CLUSTER_CLIENT_STALL sent={d} result={s} responses={d} malformed={d} duplicate={d} ingress_position={d} publisher_limit={d} egress_position={d} invalid_egress={d} buffer_too_small={d} invalid_template={d} last_invalid_template={d} last_invalid_bytes={any} ignored_egress={d} last_ignored_template={d} last_ignored_bytes={any} session_events={d} last_session_event={any} session_detail={s} new_leader_events={d} status_received={d} status_applied={d} status_sent={d} status_last_session={d} status_last_stream={d} status_last_term={d} status_last_offset={d} status_last_window={d} status_last_limit={d} connected={any} retry_ms={d}\n", .{
                        index + 1,
                        @tagName(offer_result),
                        responses.count,
                        responses.malformed,
                        responses.duplicate,
                        cluster.ingress_publication.position(),
                        cluster.ingress_publication.publisherLimit(),
                        cluster.egressPosition(),
                        cluster.egressInvalidCount(),
                        cluster.egressBufferTooSmallCount(),
                        cluster.egressInvalidTemplateCount(),
                        cluster.egressLastInvalidTemplate(),
                        cluster.egressLastInvalidBytes(),
                        cluster.egressIgnoredCount(),
                        cluster.egressLastIgnoredTemplate(),
                        cluster.egressLastIgnoredBytes(),
                        cluster.egressSessionEventCount(),
                        cluster.egressLastSessionEvent(),
                        cluster.egressLastSessionDetail(),
                        cluster.egressNewLeaderEventCount(),
                        driver.receiver_agent.statusMessagesReceived(),
                        driver.sender_agent.statusMessagesApplied(),
                        driver.receiver_agent.statusMessagesSent(),
                        driver.sender_agent.lastStatusSessionId(),
                        driver.sender_agent.lastStatusStreamId(),
                        driver.sender_agent.lastStatusTermId(),
                        driver.sender_agent.lastStatusTermOffset(),
                        driver.sender_agent.lastStatusWindow(),
                        driver.sender_agent.lastStatusLimit(),
                        cluster.ingress_publication.isConnected(),
                        report_now_ms - retry_started_ms,
                    });
                    last_stall_report_ms = report_now_ms;
                }
            }
            switch (offer_result) {
                .ok => {
                    if (trace_perf) perf.offers_ok += 1;
                    retry_started_ms = 0;
                    if ((index + 1) % 100 == 0) {
                        std.debug.print("ZIG_CLUSTER_CLIENT_PROGRESS sent={d} responses={d}\n", .{ index + 1, responses.count });
                    }
                    break;
                },
                .not_connected => {
                    if (trace_perf) perf.not_connected += 1;
                    std.Thread.yield() catch {};
                    if (trace_perf) perf.yields += 1;
                },
                .back_pressure => {
                    if (trace_perf) perf.back_pressure += 1;
                    std.Thread.yield() catch {};
                    if (trace_perf) perf.yields += 1;
                },
                .admin_action => {
                    if (trace_perf) perf.admin_action += 1;
                    std.Thread.yield() catch {};
                    if (trace_perf) perf.yields += 1;
                },
                .closed => return error.PublicationClosed,
                .max_position_exceeded => return error.MaxPositionExceeded,
            }
        }
    }
    const publish_ms = @as(usize, @intCast(@max(0, aeron.time.milliTimestamp() - publish_start_ms)));

    const response_timeout_ms = envUsize("RESPONSE_TIMEOUT_MS", 30_000);
    const deadline = aeron.time.milliTimestamp() + @as(i64, @intCast(response_timeout_ms));
    while (responses.count < order_count and aeron.time.milliTimestamp() < deadline) {
        _ = client.doWork();
        _ = cluster.pollEgress(onResponse, @ptrCast(&responses), 10);
    }
    if (responses.count != order_count) {
        if (trace_perf) {
            std.debug.print("ZIG_CLUSTER_CLIENT_RESPONSE_TIMEOUT responses={d} expected={d} malformed={d} duplicate={d} egress_position={d} invalid_egress={d} buffer_too_small={d} invalid_template={d} last_invalid_template={d} last_invalid_bytes={any} ignored_egress={d} last_ignored_template={d} last_ignored_length={d} last_ignored_bytes={any} zero_payload_frames={d} padding_frames={d} last_padding_term={d} last_padding_offset={d} last_padding_length={d} term_buffer_clears={d} last_clear_old_term={d} last_clear_new_term={d} last_clear_subscriber={d} receiver_last_stream={d} receiver_last_position={d} receiver_last_rebuild={d} receiver_last_subscriber={d} status_received={d} status_applied={d} status_sent={d}\n", .{
                responses.count,
                order_count,
                responses.malformed,
                responses.duplicate,
                cluster.egressPosition(),
                cluster.egressInvalidCount(),
                cluster.egressBufferTooSmallCount(),
                cluster.egressInvalidTemplateCount(),
                cluster.egressLastInvalidTemplate(),
                cluster.egressLastInvalidBytes(),
                cluster.egressIgnoredCount(),
                cluster.egressLastIgnoredTemplate(),
                cluster.egressLastIgnoredLength(),
                cluster.egressLastIgnoredBytes(),
                driver.receiver_agent.zeroPayloadFrames(),
                driver.receiver_agent.paddingFramesReceived(),
                driver.receiver_agent.lastPaddingTermId(),
                driver.receiver_agent.lastPaddingTermOffset(),
                driver.receiver_agent.lastPaddingLength(),
                driver.receiver_agent.termBufferClears(),
                driver.receiver_agent.lastClearOldTermId(),
                driver.receiver_agent.lastClearNewTermId(),
                driver.receiver_agent.lastClearSubscriberPosition(),
                driver.receiver_agent.lastStatusStreamId(),
                driver.receiver_agent.lastStatusPosition(),
                driver.receiver_agent.lastStatusRebuildPosition(),
                driver.receiver_agent.lastStatusSubscriberPosition(),
                driver.receiver_agent.statusMessagesReceived(),
                driver.sender_agent.statusMessagesApplied(),
                driver.receiver_agent.statusMessagesSent(),
            });
            std.debug.print("ZIG_CLUSTER_CLIENT_STATUS_DIAGNOSTICS status_received={d} status_applied={d} status_sent={d} receiver_last_stream={d} receiver_last_position={d} receiver_last_rebuild={d} receiver_last_subscriber={d} data_frames={d} data_before_image={d} insert_failures={d} nak_sent={d}\n", .{
                driver.receiver_agent.statusMessagesReceived(),
                driver.sender_agent.statusMessagesApplied(),
                driver.receiver_agent.statusMessagesSent(),
                driver.receiver_agent.lastStatusStreamId(),
                driver.receiver_agent.lastStatusPosition(),
                driver.receiver_agent.lastStatusRebuildPosition(),
                driver.receiver_agent.lastStatusSubscriberPosition(),
                driver.receiver_agent.dataFramesTotal(),
                driver.receiver_agent.dataFramesBeforeImage(),
                driver.receiver_agent.insertFailures(),
                driver.receiver_agent.nakFramesSent(),
            });
            std.debug.print("ZIG_CLUSTER_CLIENT_SENDER_DIAGNOSTICS data_frames_sent={d} last_sent_term={d} last_sent_offset={d} last_sent_length={d} retransmit_requests={d} retransmits_sent={d} last_retransmit_term={d} last_retransmit_offset={d} last_retransmit_length={d}\n", .{
                driver.sender_agent.dataFramesSent(),
                driver.sender_agent.lastSentTermId(),
                driver.sender_agent.lastSentTermOffset(),
                driver.sender_agent.lastSentFrameLength(),
                driver.sender_agent.retransmitRequests(),
                driver.sender_agent.retransmitsSent(),
                driver.sender_agent.lastRetransmitTermId(),
                driver.sender_agent.lastRetransmitTermOffset(),
                driver.sender_agent.lastRetransmitLength(),
            });
            printMissingResponses(&responses);
        }
        return error.ResponseTimeout;
    }
    const total_ms = publish_ms + response_timeout_ms -| @as(usize, @intCast(@max(0, deadline - aeron.time.milliTimestamp())));
    const orders_per_sec = order_count * 1000 / @max(1, total_ms);
    std.debug.print("ZIG_CLUSTER_CLIENT_OK responses={d} publish_ms={d} total_ms={d} orders_per_sec={d}\n", .{ responses.count, publish_ms, total_ms, orders_per_sec });
    if (trace_perf) {
        std.debug.print("ZIG_CLUSTER_CLIENT_TRANSPORT_DIAGNOSTICS data_frames_sent={d} stale_frames_skipped={d} retransmit_requests={d} retransmits_sent={d}\n", .{
            driver.sender_agent.dataFramesSent(),
            driver.sender_agent.staleFramesSkipped(),
            driver.sender_agent.retransmitRequests(),
            driver.sender_agent.retransmitsSent(),
        });
        std.debug.print("ZIG_CLUSTER_CLIENT_TRACE offers={d} ok={d} not_connected={d} back_pressure={d} admin_action={d} yields={d} do_work_calls={d} do_work_items={d} do_work_ms={d} poll_calls={d} poll_fragments={d} poll_ms={d} offer_ms={d}\n", .{
            perf.offer_calls,
            perf.offers_ok,
            perf.not_connected,
            perf.back_pressure,
            perf.admin_action,
            perf.yields,
            perf.do_work_calls,
            perf.do_work_items,
            @divTrunc(perf.do_work_ns, std.time.ns_per_ms),
            perf.poll_calls,
            perf.poll_fragments,
            @divTrunc(perf.poll_ns, std.time.ns_per_ms),
            @divTrunc(perf.offer_ns, std.time.ns_per_ms),
        });
    }
}
