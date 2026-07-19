//! Zig AeronCluster client talking to the official Java Aeron Cluster.

const std = @import("std");
const aeron = @import("aeron");

fn envOr(comptime name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name) orelse return fallback;
    return std.mem.span(value);
}

const Responses = struct { count: usize = 0 };

fn onResponse(_: i64, _: i64, payload: []const u8, ctx_ptr: *anyopaque) void {
    const responses: *Responses = @ptrCast(@alignCast(ctx_ptr));
    _ = payload;
    responses.count += 1;
}

fn envUsize(comptime name: [:0]const u8, fallback: usize) usize {
    const value = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(usize, std.mem.span(value), 10) catch fallback;
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

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const aeron_dir = envOr("AERON_DIR", "/tmp/aeron-zig-cluster-client");
    const ingress_endpoint = envOr("INGRESS_ENDPOINT", "java-node-0:9010");
    const response_channel = envOr("RESPONSE_CHANNEL", "aeron:udp?endpoint=zig-client:0");
    const ingress_channel = try std.fmt.allocPrint(allocator, "aeron:udp?endpoint={s}", .{ingress_endpoint});
    defer allocator.free(ingress_channel);

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

    var cluster = try aeron.cluster.client.AeronCluster.connect(.{
        .aeron = &client,
        .allocator = allocator,
        .ingress_channel = ingress_channel,
        .egress_channel = response_channel,
        .response_channel = response_channel,
        .max_connect_iterations = envUsize("CONNECT_MAX_ITERATIONS", 100_000),
    });
    defer cluster.close();

    const order_count = envUsize("ORDER_COUNT", 3);
    if (order_count == 0) return error.InvalidOrderCount;
    var responses = Responses{};
    const trace_perf = envBool("TRACE_PERF");
    var perf = PerfStats{};
    const offer_timeout_ms = envUsize("OFFER_TIMEOUT_MS", 60_000);
    const offer_deadline = aeron.time.milliTimestamp() + @as(i64, @intCast(offer_timeout_ms));
    const publish_start_ms = aeron.time.milliTimestamp();
    for (0..order_count) |index| {
        // Keep the Zig client namespace disjoint from the Java baseline client.
        const order_id = 1_000_001 + index;
        const side: []const u8 = if (index % 2 == 0) "ASK" else "BID";
        const price: usize = if (index % 2 == 0) 10100 else 10050;
        const quantity: usize = if (index % 2 == 0) 10 else 4;
        const order = try std.fmt.allocPrint(allocator, "BTC_USDT|{d}|{s}|{d}|{d}", .{ order_id, side, price, quantity });
        defer allocator.free(order);
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
            const offer_start_ns = if (trace_perf) aeron.time.nanoTimestamp() else 0;
            const offer_result = try cluster.offer(order);
            if (trace_perf) {
                perf.offer_calls += 1;
                perf.offer_ns += aeron.time.nanoTimestamp() - offer_start_ns;
            }
            switch (offer_result) {
                .ok => {
                    if (trace_perf) perf.offers_ok += 1;
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
    if (responses.count != order_count) return error.ResponseTimeout;
    const total_ms = publish_ms + response_timeout_ms -| @as(usize, @intCast(@max(0, deadline - aeron.time.milliTimestamp())));
    const orders_per_sec = order_count * 1000 / @max(1, total_ms);
    std.debug.print("ZIG_CLUSTER_CLIENT_OK responses={d} publish_ms={d} total_ms={d} orders_per_sec={d}\n", .{ responses.count, publish_ms, total_ms, orders_per_sec });
    if (trace_perf) {
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
