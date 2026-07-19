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
    });
    defer cluster.close();

    const order_count = envUsize("ORDER_COUNT", 3);
    if (order_count == 0) return error.InvalidOrderCount;
    var responses = Responses{};
    const offer_deadline = aeron.time.milliTimestamp() + 60_000;
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
            _ = client.doWork();
            _ = cluster.pollEgress(onResponse, @ptrCast(&responses), 10);
            switch (try cluster.offer(order)) {
                .ok => {
                    if ((index + 1) % 100 == 0) {
                        std.debug.print("ZIG_CLUSTER_CLIENT_PROGRESS sent={d} responses={d}\n", .{ index + 1, responses.count });
                    }
                    break;
                },
                .not_connected, .back_pressure, .admin_action => std.Thread.yield() catch {},
                .closed => return error.PublicationClosed,
                .max_position_exceeded => return error.MaxPositionExceeded,
            }
        }
    }

    const deadline = aeron.time.milliTimestamp() + 30_000;
    while (responses.count < order_count and aeron.time.milliTimestamp() < deadline) {
        _ = client.doWork();
        _ = cluster.pollEgress(onResponse, @ptrCast(&responses), 10);
    }
    if (responses.count != order_count) return error.ResponseTimeout;
    std.debug.print("ZIG_CLUSTER_CLIENT_OK responses={d}\n", .{responses.count});
}
