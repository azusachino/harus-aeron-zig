// Throughput Example
// Bidirectional pub/sub on IPC with live stats: msgs/sec, bytes/sec
const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const MediaDriver = aeron.driver.MediaDriver;
const LogBuffer = aeron.logbuffer.LogBuffer;
const Image = aeron.Image;
const ExclusivePublication = aeron.ExclusivePublication;
const Subscription = aeron.Subscription;

const ThroughputContext = struct {
    messages_received: i64 = 0,
    bytes_received: i64 = 0,
};

fn fragmentHandler(header: *const frame.DataHeader, buffer: []const u8, ctx_ptr: *anyopaque) void {
    _ = header;
    const ctx: *ThroughputContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.messages_received += 1;
    ctx.bytes_received += @intCast(buffer.len);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Throughput Test ===\n", .{});
    std.debug.print("Running for 10 seconds on IPC channel\n\n", .{});

    // Create MediaDriver
    const driver = try MediaDriver.create(allocator, .{});
    defer driver.destroy();

    // Create shared log buffer for IPC
    const term_length = 16 * 1024 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer allocator.destroy(lb);
    lb.* = try LogBuffer.init(allocator, term_length);
    defer lb.deinit();

    const initial_term_id = 100;
    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    // Create publisher
    var publication = ExclusivePublication.init(1, 1, initial_term_id, term_length, 1408, lb);
    publication.publisher_limit = 100 * 1024 * 1024;

    // Create subscriber image
    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1, initial_term_id, lb);

    // Create subscription
    var subscription = try Subscription.init(allocator, 1, "aeron:ipc");
    defer subscription.deinit();
    try subscription.addImage(img);

    // Fixed message payload (256 bytes)
    var msg_buffer: [256]u8 = undefined;
    @memset(&msg_buffer, 'X');
    const msg = msg_buffer[0..256];

    // Test loop: run for 10 seconds
    var timer = try std.time.Timer.start();
    const test_duration_ns = 10 * std.time.ns_per_s;
    var stat_timer = try std.time.Timer.start();
    const stat_interval_ns = 1 * std.time.ns_per_s;

    var total_sent: i64 = 0;
    var total_received: i64 = 0;
    var total_bytes: i64 = 0;
    var ctx = ThroughputContext{};

    std.debug.print("Time(s)  | Messages/sec | Bytes/sec    | Total Sent | Total Recv\n", .{});
    std.debug.print("---------+--------------+--------------+------------+-----------\n", .{});

    while (timer.read() < test_duration_ns) {
        // Publish as fast as possible
        _ = publication.offer(msg);
        total_sent += 1;

        // Poll for received messages
        ctx.messages_received = 0;
        ctx.bytes_received = 0;
        const fragments = subscription.poll(fragmentHandler, &ctx, 100);
        total_received += ctx.messages_received;
        total_bytes += ctx.bytes_received;

        // Print stats every second
        if (stat_timer.read() >= stat_interval_ns) {
            const elapsed_sec: i64 = @intCast(timer.read() / std.time.ns_per_s);
            const msg_per_sec = @divTrunc(total_received, elapsed_sec + 1);
            const bytes_per_sec = @divTrunc(total_bytes, elapsed_sec + 1);

            std.debug.print(
                "{d:7} | {d:12} | {d:12} | {d:10} | {d:9}\n",
                .{ elapsed_sec, msg_per_sec, bytes_per_sec, total_sent, total_received },
            );

            stat_timer = try std.time.Timer.start();
        }

        // Small sleep to prevent busy loop from consuming too much CPU
        if (fragments == 0) {
            std.Thread.sleep(100);
        }
    }

    // Final summary
    const elapsed_sec: i64 = @intCast(timer.read() / std.time.ns_per_s);
    const final_msg_sec = if (elapsed_sec > 0) @divTrunc(total_received, elapsed_sec) else 0;
    const final_bytes_sec = if (elapsed_sec > 0) @divTrunc(total_bytes, elapsed_sec) else 0;

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Duration: {d}s\n", .{elapsed_sec});
    std.debug.print("Messages Sent: {d}\n", .{total_sent});
    std.debug.print("Messages Received: {d}\n", .{total_received});
    std.debug.print("Average Throughput: {d} msg/sec, {d} bytes/sec\n\n", .{ final_msg_sec, final_bytes_sec });
}
