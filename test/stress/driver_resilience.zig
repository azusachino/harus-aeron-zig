const std = @import("std");
const aeron = @import("aeron");

const MediaDriver = aeron.driver.MediaDriver;
const SetupHeader = aeron.protocol.SetupHeader;
const DataHeader = aeron.protocol.DataHeader;

test "stress: publication and subscription churn" {
    const allocator = std.testing.allocator;
    const channel = "aeron:ipc";
    var iteration: i32 = 0;
    while (iteration < 16) : (iteration += 1) {
        const stream_id = 1000 + iteration;
        var log_buffer = try allocator.create(aeron.logbuffer.LogBuffer);
        defer allocator.destroy(log_buffer);
        log_buffer.* = try aeron.logbuffer.LogBuffer.init(allocator, 64 * 1024);
        defer log_buffer.deinit();

        var meta = log_buffer.metaData();
        meta.setRawTailVolatile(0, @as(i64, 100) << 32);
        meta.setActiveTermCount(0);

        var publication = aeron.ExclusivePublication.init(1, stream_id, 100, 64 * 1024, 1408, log_buffer);
        publication.publisher_limit = 1024 * 1024;

        var subscription = try aeron.Subscription.init(allocator, stream_id, channel);
        defer subscription.deinit();

        const image = try allocator.create(aeron.Image);
        defer allocator.destroy(image);
        image.* = aeron.Image.init(1, stream_id, 100, log_buffer);
        try subscription.addImage(image);

        var received_count: i32 = 0;
        const handler = struct {
            fn handle(_: *const DataHeader, _: []const u8, ctx: *anyopaque) void {
                const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
                count_ptr.* += 1;
            }
        }.handle;

        switch (publication.offer("stress payload")) {
            .ok => {},
            else => return error.UnexpectedOfferResult,
        }

        const fragments = subscription.poll(handler, &received_count, 10);
        try std.testing.expectEqual(@as(i32, 1), fragments);
        try std.testing.expectEqual(@as(i32, 1), received_count);

        publication.close();
    }
}

test "stress: media driver lifecycle churn" {
    const allocator = std.testing.allocator;

    var iteration: usize = 0;
    while (iteration < 12) : (iteration += 1) {
        const driver = try MediaDriver.create(allocator, .{});
        driver.destroy();
    }
}

test "stress: receiver tolerates duplicate setup and invalid packets" {
    const allocator = std.testing.allocator;

    const driver = try MediaDriver.create(allocator, .{});
    defer driver.destroy();

    const src_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123);

    var short_packet = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    try std.testing.expectEqual(@as(i32, 0), driver.receiver_agent.processDatagram(&short_packet, src_address));

    var setup_header: SetupHeader = undefined;
    setup_header.frame_length = SetupHeader.LENGTH;
    setup_header.version = aeron.protocol.VERSION;
    setup_header.flags = 0;
    setup_header.type = @intFromEnum(aeron.protocol.FrameType.setup);
    setup_header.term_offset = 0;
    setup_header.session_id = 1;
    setup_header.stream_id = 2;
    setup_header.initial_term_id = 100;
    setup_header.active_term_id = 100;
    setup_header.term_length = 64 * 1024;
    setup_header.mtu = 1408;
    setup_header.ttl = 0;

    const setup_bytes = @as([*]const u8, @ptrCast(&setup_header))[0..SetupHeader.LENGTH];
    try std.testing.expectEqual(@as(i32, 1), driver.receiver_agent.processDatagram(setup_bytes, src_address));

    try std.testing.expectEqual(@as(i32, 1), driver.receiver_agent.processDatagram(setup_bytes, src_address));
}
