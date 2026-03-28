const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const aeron = @import("aeron");

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

    const aeron_pkg = @import("aeron");

    // Register subscription in driver conductor so it can match the SETUP frame
    try h.driver.conductor_agent.subscriptions.append(allocator, .{
        .registration_id = 123,
        .stream_id = 1001,
        .channel = try allocator.dupe(u8, "aeron:ipc"),
        .channel_status_indicator_counter_id = aeron.ipc.counters.NULL_COUNTER_ID,
    });

    // Inject a synthetic SETUP signal directly into the receiver queue
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

test "repeated setup/teardown cycles do not leak images" {
    const allocator = std.testing.allocator;
    const aeron_pkg = @import("aeron");

    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    const stream_id: i32 = 2002;
    const reg_id: i64 = 555;

    // Add subscription to conductor
    try h.driver.conductor_agent.subscriptions.append(allocator, .{
        .registration_id = reg_id,
        .stream_id = stream_id,
        .channel = try allocator.dupe(u8, "aeron:ipc"),
        .channel_status_indicator_counter_id = aeron.ipc.counters.NULL_COUNTER_ID,
    });

    // Cycle: inject SETUP → conductor creates Image → remove subscription → image freed
    var cycle: u32 = 0;
    while (cycle < 3) : (cycle += 1) {
        // Re-add subscription if removed
        if (h.driver.conductor_agent.subscriptions.items.len == 0) {
            try h.driver.conductor_agent.subscriptions.append(allocator, .{
                .registration_id = reg_id,
                .stream_id = stream_id,
                .channel = try allocator.dupe(u8, "aeron:ipc"),
                .channel_status_indicator_counter_id = aeron_pkg.ipc.counters.NULL_COUNTER_ID,
            });
        }

        try h.injectSetupFrame(aeron_pkg.driver.receiver.SetupSignal{
            .session_id = @as(i32, @intCast(cycle + 1)),
            .stream_id = stream_id,
            .initial_term_id = 0,
            .active_term_id = 0,
            .term_length = 64 * 1024,
            .mtu = 1408,
            .source_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        });
        h.doConductorWork(10);
        try std.testing.expectEqual(@as(usize, 1), h.driver.receiver_agent.images.items.len);

        // Remove subscription — should also clean up the image
        var remove_buf: [24]u8 = undefined;
        std.mem.writeInt(i64, remove_buf[0..8], 1, .little); // client_id
        std.mem.writeInt(i64, remove_buf[8..16], 0, .little); // correlation_id
        std.mem.writeInt(i64, remove_buf[16..24], reg_id, .little);
        h.driver.conductor_agent.handleRemoveSubscription(&remove_buf);
        try std.testing.expectEqual(@as(usize, 0), h.driver.receiver_agent.images.items.len);
    }
}

test "subscriber catch-up preserves client-owned subscriber position" {
    const allocator = std.testing.allocator;
    const aeron_pkg = @import("aeron");
    const protocol = aeron_pkg.protocol;

    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();

    const stream_id: i32 = 3003;
    const session_id: i32 = 99;
    const term_length: i32 = 64 * 1024;
    const initial_term_id: i32 = 0;

    // Register subscription and inject SETUP
    try h.driver.conductor_agent.subscriptions.append(allocator, .{
        .registration_id = 777,
        .stream_id = stream_id,
        .channel = try allocator.dupe(u8, "aeron:ipc"),
        .channel_status_indicator_counter_id = aeron_pkg.ipc.counters.NULL_COUNTER_ID,
    });
    try h.injectSetupFrame(aeron_pkg.driver.receiver.SetupSignal{
        .session_id = session_id,
        .stream_id = stream_id,
        .initial_term_id = initial_term_id,
        .active_term_id = initial_term_id,
        .term_length = term_length,
        .mtu = 1408,
        .source_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
    });
    h.doConductorWork(10);
    try std.testing.expectEqual(@as(usize, 1), h.driver.receiver_agent.images.items.len);

    const image = h.driver.receiver_agent.images.items[0];
    const cm = h.driver.conductor_agent.counters_map;

    // Client-owned subscriber position should start at 0 (no data consumed yet)
    const pos_before = cm.get(image.subscriber_position.counter_id);
    try std.testing.expectEqual(@as(i64, 0), pos_before);
    try std.testing.expectEqual(@as(i64, 0), image.rebuild_position);

    // Simulate arrival of a DATA frame at offset 0
    const payload = "catch-up-test";
    var dh: protocol.DataHeader = undefined;
    dh.frame_length = @as(i32, @intCast(protocol.DataHeader.LENGTH + payload.len));
    dh.version = protocol.VERSION;
    dh.flags = protocol.DataHeader.BEGIN_FLAG | protocol.DataHeader.END_FLAG;
    dh.type = @intFromEnum(protocol.FrameType.data);
    const aligned_first = std.mem.alignForward(
        usize,
        protocol.DataHeader.LENGTH + payload.len,
        protocol.FRAME_ALIGNMENT,
    );
    dh.term_offset = @as(i32, @intCast(aligned_first));
    dh.session_id = session_id;
    dh.stream_id = stream_id;
    dh.term_id = initial_term_id;
    dh.reserved_value = 0;

    const written_late = image.insertFrame(cm, &dh, payload);
    try std.testing.expect(written_late);

    // Driver-side rebuild progress may move independently, but the client-owned
    // subscriber position counter must remain unchanged until an actual poll.
    const rebuild_before = image.rebuild_position;
    try std.testing.expectEqual(@as(i64, 0), cm.get(image.subscriber_position.counter_id));

    // Deliver the missing prefix frame and verify rebuild catches up.
    dh.term_offset = 0;
    dh.frame_length = @as(i32, @intCast(protocol.DataHeader.LENGTH + payload.len));

    const written_prefix = image.insertFrame(cm, &dh, payload);
    try std.testing.expect(written_prefix);

    const rebuild_final = image.rebuild_position;
    try std.testing.expect(rebuild_final >= rebuild_before);
    try std.testing.expectEqual(@as(i64, 0), cm.get(image.subscriber_position.counter_id));
}
