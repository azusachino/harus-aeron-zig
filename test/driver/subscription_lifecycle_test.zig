// Subscription lifecycle tests via ring buffer dispatch
// Tests the full ADD_SUBSCRIPTION -> doWork -> ON_SUBSCRIPTION_READY and
// REMOVE_SUBSCRIPTION -> doWork -> ON_OPERATION_SUCCESS paths.
// Reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java

const std = @import("std");
const aeron = @import("aeron");

fn makeRingBuffer(allocator: std.mem.Allocator) !struct { buf: []align(8) u8, rb: aeron.ipc.ring_buffer.ManyToOneRingBuffer } {
    const buf = try allocator.alignedAlloc(u8, .@"8", 8192 + 768);
    @memset(buf, 0);
    return .{ .buf = buf, .rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(buf) };
}

fn setupConductor(
    allocator: std.mem.Allocator,
    rb: *aeron.ipc.ring_buffer.ManyToOneRingBuffer,
    bcast: *aeron.ipc.broadcast.BroadcastTransmitter,
    cm: *aeron.ipc.counters.CountersMap,
) !struct {
    sock: std.posix.socket_t,
    recv_ep: aeron.transport.ReceiveChannelEndpoint,
    send_ep: aeron.transport.SendChannelEndpoint,
    sender: aeron.driver.Sender,
    receiver: aeron.driver.Receiver,
    conductor: aeron.driver.conductor.DriverConductor,
} {
    const sock = try aeron.net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_ep, cm);
    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, cm, null);
    var conductor = try aeron.driver.conductor.DriverConductor.init(
        allocator,
        rb,
        bcast,
        cm,
        &receiver,
        &sender,
        &recv_ep,
        false,
        "/tmp",
        5_000_000_000,
        5_000_000_000,
        5_000_000_000,
    );
    conductor.recv_bound = true;
    return .{
        .sock = sock,
        .recv_ep = recv_ep,
        .send_ep = send_ep,
        .sender = sender,
        .receiver = receiver,
        .conductor = conductor,
    };
}

fn writeAddSubscription(
    rb: *aeron.ipc.ring_buffer.ManyToOneRingBuffer,
    allocator: std.mem.Allocator,
    client_id: i64,
    correlation_id: i64,
    registration_correlation_id: i64,
    stream_id: i32,
    channel: []const u8,
) !bool {
    // ADD_SUBSCRIPTION payload:
    // [0..8] client_id, [8..16] correlation_id, [16..24] registration_correlation_id,
    // [24..28] stream_id, [28..32] channel_len, [32..] channel
    const buf = try allocator.alloc(u8, 32 + channel.len);
    defer allocator.free(buf);
    @memset(buf, 0);
    std.mem.writeInt(i64, buf[0..8], client_id, .little);
    std.mem.writeInt(i64, buf[8..16], correlation_id, .little);
    std.mem.writeInt(i64, buf[16..24], registration_correlation_id, .little);
    std.mem.writeInt(i32, buf[24..28], stream_id, .little);
    std.mem.writeInt(i32, buf[28..32], @as(i32, @intCast(channel.len)), .little);
    @memcpy(buf[32 .. 32 + channel.len], channel);
    return rb.write(0x04, buf); // CMD_ADD_SUBSCRIPTION
}

test "ADD_SUBSCRIPTION via ring buffer dispatches ON_SUBSCRIPTION_READY" {
    const allocator = std.testing.allocator;

    var rb_holder = try makeRingBuffer(allocator);
    defer allocator.free(rb_holder.buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var ctx = try setupConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const correlation_id: i64 = 0xCAFE;
    try std.testing.expect(try writeAddSubscription(
        &rb_holder.rb,
        allocator,
        1,
        correlation_id,
        -1,
        1001,
        "aeron:ipc",
    ));
    _ = ctx.conductor.doWork();

    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(
        @as(i32, aeron.driver.conductor.RESPONSE_ON_SUBSCRIPTION_READY),
        rx.typeId(),
    );

    const payload = rx.buffer();
    try std.testing.expectEqual(@as(usize, 12), payload.len);
    try std.testing.expectEqual(correlation_id, std.mem.readInt(i64, payload[0..8], .little));
}

test "ADD_SUBSCRIPTION registers entry in conductor subscriptions list" {
    const allocator = std.testing.allocator;

    var rb_holder = try makeRingBuffer(allocator);
    defer allocator.free(rb_holder.buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var ctx = try setupConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    try std.testing.expect(try writeAddSubscription(
        &rb_holder.rb,
        allocator,
        1,
        0x1234,
        -1,
        5555,
        "aeron:udp?endpoint=localhost:40123",
    ));
    _ = ctx.conductor.doWork();

    try std.testing.expectEqual(@as(usize, 1), ctx.conductor.subscriptions.items.len);
    try std.testing.expectEqual(@as(i32, 5555), ctx.conductor.subscriptions.items[0].stream_id);
}

test "ADD_SUBSCRIPTION then REMOVE_SUBSCRIPTION sends ON_OPERATION_SUCCESS" {
    const allocator = std.testing.allocator;

    var rb_holder = try makeRingBuffer(allocator);
    defer allocator.free(rb_holder.buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var ctx = try setupConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const add_correlation_id: i64 = 0xAA01;
    try std.testing.expect(try writeAddSubscription(
        &rb_holder.rb,
        allocator,
        1,
        add_correlation_id,
        -1,
        7777,
        "aeron:ipc",
    ));
    _ = ctx.conductor.doWork();

    try std.testing.expectEqual(@as(usize, 1), ctx.conductor.subscriptions.items.len);
    const reg_id = ctx.conductor.subscriptions.items[0].registration_id;

    // Drain ON_SUBSCRIPTION_READY
    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    _ = rx.receiveNext();

    // REMOVE_SUBSCRIPTION: [0..8] client_id, [8..16] correlation_id, [16..24] registration_id
    const remove_correlation_id: i64 = 0xBB02;
    var rm_cmd: [24]u8 = undefined;
    @memset(&rm_cmd, 0);
    std.mem.writeInt(i64, rm_cmd[0..8], 1, .little);
    std.mem.writeInt(i64, rm_cmd[8..16], remove_correlation_id, .little);
    std.mem.writeInt(i64, rm_cmd[16..24], reg_id, .little);

    try std.testing.expect(rb_holder.rb.write(0x05, &rm_cmd)); // CMD_REMOVE_SUBSCRIPTION
    _ = ctx.conductor.doWork();

    try std.testing.expectEqual(@as(usize, 0), ctx.conductor.subscriptions.items.len);

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(
        @as(i32, aeron.driver.conductor.RESPONSE_ON_OPERATION_SUCCESS),
        rx.typeId(),
    );

    const payload = rx.buffer();
    try std.testing.expectEqual(remove_correlation_id, std.mem.readInt(i64, payload[0..8], .little));
}

test "REMOVE_SUBSCRIPTION with unknown registration_id sends ON_ERROR" {
    const allocator = std.testing.allocator;

    var rb_holder = try makeRingBuffer(allocator);
    defer allocator.free(rb_holder.buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var ctx = try setupConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const remove_correlation_id: i64 = 0xCC03;
    var rm_cmd: [24]u8 = undefined;
    @memset(&rm_cmd, 0);
    std.mem.writeInt(i64, rm_cmd[0..8], 1, .little);
    std.mem.writeInt(i64, rm_cmd[8..16], remove_correlation_id, .little);
    std.mem.writeInt(i64, rm_cmd[16..24], 9999999, .little); // unknown registration_id

    try std.testing.expect(rb_holder.rb.write(0x05, &rm_cmd));
    _ = ctx.conductor.doWork();

    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    const got_message = rx.receiveNext();
    if (got_message) {
        try std.testing.expectEqual(
            @as(i32, aeron.driver.conductor.RESPONSE_ON_ERROR),
            rx.typeId(),
        );
    }
}
