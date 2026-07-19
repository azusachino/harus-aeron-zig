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
    std.debug.print("ZIG_CLIENT {s}\n", .{payload});
    responses.count += 1;
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

    var cluster = try aeron.cluster.client.AeronCluster.connect(.{
        .aeron = &client,
        .allocator = allocator,
        .ingress_channel = ingress_channel,
        .egress_channel = response_channel,
        .response_channel = response_channel,
    });
    defer cluster.close();

    const orders = [_][]const u8{
        "BTC_USDT|1|ASK|10100|10",
        "BTC_USDT|2|BID|10100|4",
        "BTC_USDT|3|BID|10050|8",
    };
    for (orders) |order| {
        while (true) {
            _ = client.doWork();
            switch (try cluster.offer(order)) {
                .ok => break,
                .not_connected, .back_pressure, .admin_action => {},
                .closed => return error.PublicationClosed,
                .max_position_exceeded => return error.MaxPositionExceeded,
            }
        }
    }

    var responses = Responses{};
    const deadline = aeron.time.milliTimestamp() + 30_000;
    while (responses.count < orders.len and aeron.time.milliTimestamp() < deadline) {
        _ = client.doWork();
        _ = cluster.pollEgress(onResponse, @ptrCast(&responses), 10);
    }
    if (responses.count != orders.len) return error.ResponseTimeout;
    std.debug.print("ZIG_CLUSTER_CLIENT_OK responses={d}\n", .{responses.count});
}
