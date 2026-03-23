// Basic Subscriber Example
// Subscribes to stream 1001 and prints received messages using the high-level Aeron API
const std = @import("std");
const aeron = @import("aeron");
const Aeron = aeron.Aeron;
const MediaDriver = aeron.driver.MediaDriver;
const frame = aeron.protocol;

// ZIG: This context is passed to the fragment handler as a pointer.
// AERON: Use this to track count of received fragments or accumulate large messages.
const SubscriberContext = struct {
    received: i32 = 0,
};

// ZIG: FragmentHandler is a function pointer. The driver/client invokes it for each message.
// AERON: Zero-copy delivery. Data points directly into the mmap'd log buffer slice.
fn fragmentHandler(header: *const frame.DataHeader, buffer: []const u8, any_ctx: *anyopaque) void {
    const ctx = @as(*SubscriberContext, @ptrCast(@alignCast(any_ctx)));
    _ = header;
    std.debug.print("Received message: {s}\n", .{buffer});
    ctx.received += 1;
}

pub fn main() !void {
    // ZIG: Standard memory setup. All resources in the loop are scoped to the GPA.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Basic Subscriber ===\n\n", .{});

    // ZIG: Embedded driver instance starts on this process.
    // AERON: The conductor agent will run on a separate thread by default.
    const driver = try MediaDriver.create(allocator, .{ .aeron_dir = "/tmp/aeron-basic-example" });
    defer driver.destroy();
    std.debug.print("MediaDriver created at /tmp/aeron-basic-example\n", .{});

    // ZIG: Aeron.init performs mmap and establishes shared memory IPC.
    var client = try Aeron.init(allocator, .{ .aeron_dir = "/tmp/aeron-basic-example" });
    defer client.deinit();
    client.embedded_driver = driver;

    // ZIG: addSubscription requests the driver to listen on a channel/stream.
    // AERON: No messages are received until a matching publication sends a SETUP frame.
    const registration_id = try client.addSubscription("aeron:ipc", 1001);
    std.debug.print("Subscription requested (stream=1001, reg_id={d})\n", .{registration_id});

    // ZIG: Wait for the Conductor to confirm subscription readiness.
    var subscription: ?*aeron.Subscription = null;
    while (subscription == null) {
        _ = client.doWork();
        subscription = client.getSubscription(registration_id);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    std.debug.print("Subscription ready! Waiting for messages...\n\n", .{});

    const sub = subscription.?;
    var sub_ctx = SubscriberContext{};

    // Poll until 100 messages received or timeout
    var timer = try std.time.Timer.start();
    const timeout_ns = 30 * std.time.ns_per_s;

    while (sub_ctx.received < 100 and timer.read() < timeout_ns) {
        // ZIG: poll() executes the reader duty cycle over all assigned Images.
        // AERON: poll() takes a fragment_limit to ensure a single subscriber doesn't hog the thread.
        _ = client.doWork(); // Discover new images/publishers
        const fragments = sub.poll(fragmentHandler, &sub_ctx, 10);

        if (fragments == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    const elapsed = timer.read();
    std.debug.print("\n=== Subscription Complete ===\n", .{});
    std.debug.print("Received: {d} messages in {d}ms\n\n", .{ sub_ctx.received, elapsed / std.time.ns_per_ms });
}
