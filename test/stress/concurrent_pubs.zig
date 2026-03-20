const std = @import("std");
const aeron = @import("aeron");

test "stress: multiple publications on same stream" {
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

    // Create two publications on same stream
    var pub1 = aeron.ExclusivePublication.init(1, 1, 100, term_length, 1408, log_buf);
    pub1.publisher_limit = 100 * 1024 * 1024;

    var pub2 = aeron.ExclusivePublication.init(2, 1, 100, term_length, 1408, log_buf);
    pub2.publisher_limit = 100 * 1024 * 1024;

    // Both publishers send messages
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var msg_buf: [8]u8 = undefined;
        std.mem.writeInt(u32, msg_buf[0..4], i, .little);
        _ = pub1.offer(msg_buf[0..8]);
        _ = pub2.offer(msg_buf[0..8]);
    }

    // Poll until received or timeout
    var timer = try std.time.Timer.start();
    const timeout_ns = 5000 * std.time.ns_per_ms;
    while (received_count < 100) {
        if (timer.read() > timeout_ns) break;
        _ = img.poll(handler, &received_count, 10);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expect(received_count >= 50);
}
