const std = @import("std");
const aeron = @import("aeron");

test "stress: publisher reconnection cycles" {
    const allocator = std.testing.allocator;

    const term_length = 128 * 1024;
    var log_buf = try allocator.create(aeron.logbuffer.LogBuffer);
    defer allocator.destroy(log_buf);
    log_buf.* = try aeron.logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();

    var meta = log_buf.metaData();
    meta.setRawTailVolatile(0, @as(i64, 100) << 32);
    meta.setActiveTermCount(0);

    var subscription = try aeron.Subscription.init(allocator, 1, "aeron:ipc");
    defer subscription.deinit();

    const img = try allocator.create(aeron.Image);
    defer allocator.destroy(img);
    img.* = aeron.Image.init(1, 1, 100, log_buf);
    try subscription.addImage(img);

    var received_count: i32 = 0;

    const handler = struct {
        fn handle(_: *const aeron.protocol.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
        }
    }.handle;

    // 5 cycles: create publisher, send messages, close
    var cycle: u32 = 0;
    while (cycle < 5) : (cycle += 1) {
        var publication = aeron.ExclusivePublication.init(
            1,
            1,
            100 + @as(i32, @intCast(cycle)),
            term_length,
            1408,
            log_buf,
        );
        publication.publisher_limit = 10 * 1024 * 1024;

        var msg_id: u32 = 0;
        while (msg_id < 20) : (msg_id += 1) {
            var msg_buf: [16]u8 = undefined;
            std.mem.writeInt(u32, msg_buf[0..4], cycle, .little);
            std.mem.writeInt(u32, msg_buf[4..8], msg_id, .little);
            _ = publication.offer(msg_buf[0..8]);
        }
    }

    // Poll until received or timeout
    var timer = try std.time.Timer.start();
    const timeout_ns = 5000 * std.time.ns_per_ms;
    while (received_count < 100) {
        if (timer.read() > timeout_ns) break;
        _ = img.poll(handler, &received_count, 10);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expect(!img.is_eos);
    try std.testing.expect(received_count >= 20);
}
