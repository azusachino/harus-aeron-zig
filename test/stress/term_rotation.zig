const std = @import("std");
const aeron = @import("aeron");

test "stress: term rotation under load" {
    const allocator = std.testing.allocator;

    const term_length = 64 * 1024;
    var log_buf = try allocator.create(aeron.logbuffer.LogBuffer);
    defer allocator.destroy(log_buf);
    log_buf.* = try aeron.logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();

    const initial_term_id = 100;
    var meta = log_buf.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    var publication = aeron.ExclusivePublication.init(1, 1, initial_term_id, term_length, 1408, log_buf);
    publication.publisher_limit = 10 * 1024 * 1024;

    var subscription = try aeron.Subscription.init(allocator, 1, "aeron:ipc");
    defer subscription.deinit();

    const img = try allocator.create(aeron.Image);
    defer allocator.destroy(img);
    img.* = aeron.Image.init(1, 1, initial_term_id, log_buf);
    try subscription.addImage(img);

    var received_count: i32 = 0;

    const handler = struct {
        fn handle(_: *const aeron.protocol.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
        }
    }.handle;

    // Publish 100 messages to stress term boundaries
    var msg_id: u32 = 0;
    while (msg_id < 100) : (msg_id += 1) {
        var msg_buf: [16]u8 = undefined;
        std.mem.writeInt(u32, msg_buf[0..4], msg_id, .little);
        _ = publication.offer(msg_buf[0..8]);
    }

    // Poll until received or timeout
    var timer = try std.time.Timer.start();
    const timeout_ns = 5000 * std.time.ns_per_ms;
    while (received_count < 100) {
        if (timer.read() > timeout_ns) break;
        _ = img.poll(handler, &received_count, 10);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(i32, 100), received_count);
}
