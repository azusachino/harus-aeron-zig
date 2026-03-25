const std = @import("std");
const aeron = @import("aeron");

test "stress: 3-round leader failover with image replacement" {
    const allocator = std.testing.allocator;

    const term_length = 128 * 1024;

    // Simulate 3 rounds of leader failover — each round creates a new
    // log buffer (simulating a new leader's term) and verifies the
    // subscription can attach to a fresh image after the previous one closes.
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        var log_buf = try allocator.create(aeron.logbuffer.LogBuffer);
        log_buf.* = try aeron.logbuffer.LogBuffer.init(allocator, term_length);

        var meta = log_buf.metaData();
        const initial_term_id: i32 = @intCast(round * 10);
        meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
        meta.setActiveTermCount(0);

        var subscription = try aeron.Subscription.init(allocator, 1, "aeron:udp?endpoint=localhost:40456");

        const img = try allocator.create(aeron.Image);
        img.* = aeron.Image.init(1, 1, initial_term_id, log_buf);
        try subscription.addImage(img);

        // Publish some messages in this term
        var publication = aeron.ExclusivePublication.init(
            1,
            1,
            initial_term_id,
            term_length,
            1408,
            log_buf,
        );
        publication.publisher_limit = 10 * 1024 * 1024;

        var msg_id: u32 = 0;
        while (msg_id < 50) : (msg_id += 1) {
            var payload: [32]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], round, .little);
            std.mem.writeInt(u32, payload[4..8], msg_id, .little);
            _ = publication.offer(&payload);
        }

        // Verify subscription can poll messages
        var received: i32 = 0;
        const handler = struct {
            fn handle(_: *const aeron.protocol.DataHeader, _: []const u8, ctx: *anyopaque) void {
                const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
                count_ptr.* += 1;
            }
        }.handle;
        _ = subscription.poll(handler, &received, 100);
        try std.testing.expect(received > 0);

        // Teardown this round — simulates leader death
        subscription.deinit();
        allocator.destroy(img);
        log_buf.deinit();
        allocator.destroy(log_buf);
    }
}

test "stress: 20-cycle reconnect churn" {
    const allocator = std.testing.allocator;

    const term_length = 64 * 1024;

    // Rapidly create and destroy publications + subscriptions to stress
    // resource cleanup paths
    var cycle: u32 = 0;
    while (cycle < 20) : (cycle += 1) {
        var log_buf = try allocator.create(aeron.logbuffer.LogBuffer);
        log_buf.* = try aeron.logbuffer.LogBuffer.init(allocator, term_length);

        var meta = log_buf.metaData();
        meta.setRawTailVolatile(0, @as(i64, @intCast(cycle)) << 32);
        meta.setActiveTermCount(0);

        var publication = aeron.ExclusivePublication.init(
            @intCast(cycle),
            1,
            @intCast(cycle),
            term_length,
            1408,
            log_buf,
        );
        publication.publisher_limit = 1024 * 1024;

        // Quick burst of messages
        var msg_id: u32 = 0;
        while (msg_id < 10) : (msg_id += 1) {
            var payload: [16]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], cycle, .little);
            _ = publication.offer(&payload);
        }

        // Immediate teardown
        log_buf.deinit();
        allocator.destroy(log_buf);
    }
}
