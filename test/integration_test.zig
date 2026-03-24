const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "round-trip 1 message" {
    const allocator = testing.allocator;
    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    const stream_id: i32 = 1001;
    const channel = "aeron:ipc";

    var pub_instance = try h.createPublication(stream_id, channel);
    defer pub_instance.close();

    var sub = try h.createSubscription(stream_id, channel);
    defer sub.deinit();

    var received_count: i32 = 0;

    const handler = struct {
        fn handle(header: *const @import("aeron").protocol.DataHeader, data: []const u8, ctx: *anyopaque) void {
            _ = header;
            _ = data;
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
        }
    }.handle;

    const msg = "hello";
    const result = pub_instance.offer(msg);
    try testing.expect(result == .ok);

    // Poll until received or timeout (1s)
    try h.doWorkLoop(&sub, &received_count, handler, 1, 1000);

    try testing.expectEqual(@as(i32, 1), received_count);
}

test "subscriber receives data after SETUP handshake" {
    const allocator = std.testing.allocator;
    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    var sub = try h.createSubscription(1001, "aeron:ipc");
    defer sub.deinit();

    // Register subscription in driver conductor so it can match the SETUP frame
    try h.driver.conductor_agent.subscriptions.append(allocator, .{
        .registration_id = 123,
        .stream_id = 1001,
        .channel = try allocator.dupe(u8, "aeron:ipc"),
    });

    // Inject a synthetic SETUP signal directly into the receiver queue
    const aeron_pkg = @import("aeron");
    try h.injectSetupFrame(aeron_pkg.driver.receiver.SetupSignal{
        .session_id = 42,
        .stream_id = 1001,
        .initial_term_id = 0,
        .active_term_id = 0,
        .term_length = 64 * 1024,
        .mtu = 1408,
        .source_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
    });

    // Allow conductor duty cycle to process the signal
    h.doConductorWork(10);

    // Receiver should now have an Image
    try std.testing.expectEqual(@as(usize, 1), h.driver.receiver_agent.images.items.len);
}
