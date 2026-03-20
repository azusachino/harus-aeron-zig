// Basic Subscriber Example
// Subscribes to stream 1001 and prints received messages with 30s timeout
const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const MediaDriver = aeron.driver.MediaDriver;
const LogBuffer = aeron.logbuffer.LogBuffer;
const Image = aeron.Image;
const Subscription = aeron.Subscription;
const FragmentHandler = aeron.logbuffer.term_reader.FragmentHandler;

const SubscriberContext = struct {
    received: i32 = 0,
};

fn fragmentHandler(header: *const frame.DataHeader, buffer: []const u8, _: *anyopaque) void {
    _ = header;
    std.debug.print("Received message: {s}\n", .{buffer});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Basic Subscriber ===\n\n", .{});

    // Create and start MediaDriver
    const driver = try MediaDriver.create(allocator, .{});
    defer driver.destroy();
    std.debug.print("MediaDriver created\n", .{});

    // Create a log buffer (simulates publication data)
    const term_length = 64 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer allocator.destroy(lb);
    lb.* = try LogBuffer.init(allocator, term_length);
    defer lb.deinit();

    // Initialize metadata and image
    const initial_term_id = 100;
    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1001, initial_term_id, lb);

    // Create subscription on stream 1001
    var sub = try Subscription.init(allocator, 1001, "aeron:udp?endpoint=localhost:40123");
    defer sub.deinit();
    try sub.addImage(img);

    std.debug.print("Subscription created (stream=1001)\n", .{});
    std.debug.print("Waiting for messages (30s timeout)...\n\n", .{});

    // Poll for 30 seconds or until 100 messages received
    var timer = try std.time.Timer.start();
    const timeout_ns = 30 * std.time.ns_per_s;
    var received: i32 = 0;

    while (received < 100 and timer.read() < timeout_ns) {
        var ctx = SubscriberContext{ .received = received };
        const fragments = sub.poll(fragmentHandler, &ctx, 10);

        if (fragments == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        } else {
            received += fragments;
        }
    }

    const elapsed = timer.read();
    std.debug.print("\n=== Subscription Complete ===\n", .{});
    std.debug.print("Received: {d} messages in {d}ms\n\n", .{ received, elapsed / std.time.ns_per_ms });
}
