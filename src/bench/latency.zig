const std = @import("std");
const aeron = @import("aeron");
const MediaDriver = aeron.driver.MediaDriver;
const ExclusivePublication = aeron.ExclusivePublication;
const Subscription = aeron.Subscription;
const Image = aeron.Image;
const LogBuffer = aeron.logbuffer.LogBuffer;
const FragmentHandler = aeron.logbuffer.term_reader.FragmentHandler;

const Context = struct {
    count: usize = 0,
    latencies: []u64 = undefined,
    allocator: std.mem.Allocator = undefined,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start embedded driver
    const driver = try MediaDriver.create(allocator, .{
        .ipc_term_buffer_length = 64 * 1024,
    });
    defer driver.destroy();

    // Create log buffer and publication
    const term_length = 64 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer {
        lb.deinit();
        allocator.destroy(lb);
    }
    lb.* = try LogBuffer.init(allocator, term_length);

    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, 100) << 32);
    meta.setActiveTermCount(0);

    var pub_instance = ExclusivePublication.init(1, 1, 100, term_length, 1408, lb);
    pub_instance.publisher_limit = 1024 * 1024;

    // Create subscription and image
    var sub = try Subscription.init(allocator, 1, "aeron:ipc");
    defer sub.deinit();

    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1, 100, lb);
    try sub.addImage(img);

    const message_count: usize = 10000;
    const latencies = try allocator.alloc(u64, message_count);
    defer allocator.free(latencies);

    var context = Context{
        .latencies = latencies,
        .allocator = allocator,
    };

    const handler = struct {
        fn handle(_: *const aeron.protocol.DataHeader, data: []const u8, ctx: *anyopaque) void {
            if (data.len < 8) return;
            const c = @as(*Context, @ptrCast(@alignCast(ctx)));
            const sent_ts = std.mem.bytesAsValue(i64, data[0..8]).*;
            const now = @as(i64, @intCast(std.time.nanoTimestamp()));
            const latency = @as(u64, @intCast(now - sent_ts));
            if (c.count < c.latencies.len) {
                c.latencies[c.count] = latency;
                c.count += 1;
            }
        }
    }.handle;

    // Send timestamps in payload
    std.debug.print("Measuring round-trip latency for {d} messages...\n", .{message_count});

    for (0..message_count) |_| {
        const now = @as(i64, @intCast(std.time.nanoTimestamp()));
        var payload: [16]u8 = undefined;
        std.mem.writeInt(i64, payload[0..8], now, .little);
        std.mem.writeInt(i64, payload[8..16], 0, .little);

        while (true) {
            const result = pub_instance.offer(&payload);
            if (result == .ok) break;
            _ = driver.doWork();
        }
    }

    // Collect latencies
    context.count = 0;
    while (context.count < message_count) {
        _ = driver.doWork();
        _ = sub.poll(handler, &context, 100);
        if (context.count < message_count) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    // Sort latencies
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    const p50_idx = message_count / 2;
    const p99_idx = (message_count * 99) / 100;
    const p999_idx = (message_count * 999) / 1000;

    const p50 = @as(f64, @floatFromInt(latencies[p50_idx])) / 1000.0;
    const p99 = @as(f64, @floatFromInt(latencies[p99_idx])) / 1000.0;
    const p999 = @as(f64, @floatFromInt(latencies[p999_idx])) / 1000.0;
    const min = @as(f64, @floatFromInt(latencies[0])) / 1000.0;
    const max = @as(f64, @floatFromInt(latencies[message_count - 1])) / 1000.0;

    var sum: u64 = 0;
    for (latencies) |lat| {
        sum += lat;
    }
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(@as(u64, @intCast(message_count)))) / 1000.0;

    std.debug.print("\nLatency Histogram (microseconds):\n", .{});
    std.debug.print("| Metric | Value (us) |\n", .{});
    std.debug.print("|--------|------------|\n", .{});
    std.debug.print("| Min    | {: >10.2} |\n", .{min});
    std.debug.print("| Mean   | {: >10.2} |\n", .{mean});
    std.debug.print("| p50    | {: >10.2} |\n", .{p50});
    std.debug.print("| p99    | {: >10.2} |\n", .{p99});
    std.debug.print("| p999   | {: >10.2} |\n", .{p999});
    std.debug.print("| Max    | {: >10.2} |\n", .{max});
}
