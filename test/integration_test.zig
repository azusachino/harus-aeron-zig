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
