// IPC command dispatch tests for DriverConductor
// Tests the full ring buffer → doWork → broadcast flow for IPC commands
// Reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java

const std = @import("std");
const aeron = @import("aeron");

test "ADD_SUBSCRIPTION via ring buffer dispatches ON_SUBSCRIPTION_READY" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alignedAlloc(u8, .@"8", 8192 + 768); // data capacity 8192 (2^13) + metadata 768
    defer allocator.free(ring_buf);
    @memset(ring_buf, 0);
    var rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(ring_buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const sock = try aeron.net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer aeron.net.closeSocket(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();
    conductor.recv_bound = true;

    // Write ADD_SUBSCRIPTION command to ring buffer
    const channel = "aeron:ipc";
    const channel_len = @as(i32, @intCast(channel.len));

    // Build ADD_SUBSCRIPTION payload
    // Format: [0..8] client_id, [8..16] correlation_id, [16..24] registration_correlation_id,
    //         [24..28] stream_id, [28..32] channel_len, [32..] channel
    var cmd_buf = try allocator.alloc(u8, 32 + channel.len);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 1, .little); // client_id
    std.mem.writeInt(i64, cmd_buf[8..16], 0xCAFE, .little); // correlation_id = 51966
    std.mem.writeInt(i64, cmd_buf[16..24], -1, .little); // registration_correlation_id
    std.mem.writeInt(i32, cmd_buf[24..28], 1001, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[28..32], channel_len, .little); // channel_len
    @memcpy(cmd_buf[32 .. 32 + channel.len], channel);

    // Write to ring buffer with type 0x04 (ADD_SUBSCRIPTION)
    const wrote = rb.write(0x04, cmd_buf);
    try std.testing.expect(wrote);

    // Call doWork to dispatch the command
    _ = conductor.doWork();

    // Read the broadcast response using BroadcastReceiver
    var bcast_receiver = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);

    // The broadcast buffer should have ON_SUBSCRIPTION_READY (0x0F07)
    try std.testing.expect(bcast_receiver.receiveNext());
    try std.testing.expectEqual(@as(i32, aeron.driver.conductor.RESPONSE_ON_SUBSCRIPTION_READY), bcast_receiver.typeId());

    // Verify payload: [0..8] correlation_id, [8..12] channel_status_indicator_id
    const payload = bcast_receiver.buffer();
    try std.testing.expectEqual(@as(usize, 12), payload.len);

    const echo_correlation_id = std.mem.readInt(i64, payload[0..8], .little);
    const channel_status_indicator_id = std.mem.readInt(i32, payload[8..12], .little);

    try std.testing.expectEqual(@as(i64, 0xCAFE), echo_correlation_id);
    try std.testing.expect(channel_status_indicator_id >= 0);
}

test "ADD_SUBSCRIPTION with invalid payload is silently ignored" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alignedAlloc(u8, .@"8", 8192 + 768); // data capacity 8192 (2^13) + metadata 768
    defer allocator.free(ring_buf);
    @memset(ring_buf, 0);
    var rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(ring_buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const sock = try aeron.net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer aeron.net.closeSocket(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();
    conductor.recv_bound = true;

    // Write ADD_SUBSCRIPTION with too-short payload (< 32 bytes)
    const short_buf = try allocator.alloc(u8, 16);
    defer allocator.free(short_buf);
    @memset(short_buf, 0xAA);

    const wrote = rb.write(0x04, short_buf);
    try std.testing.expect(wrote);

    // Call doWork — should not crash
    _ = conductor.doWork();

    // Check if an ON_ERROR response was sent
    var bcast_receiver = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);

    // The command should either be ignored or an error should be sent
    // We just verify that doWork didn't panic and the receiver is still valid
    const got_message = bcast_receiver.receiveNext();

    if (got_message) {
        // If a message was sent, it should be an error
        try std.testing.expectEqual(@as(i32, aeron.driver.conductor.RESPONSE_ON_ERROR), bcast_receiver.typeId());
    }
}

test "ring buffer dispatches CLIENT_KEEPALIVE without crashing" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alignedAlloc(u8, .@"8", 8192 + 768); // data capacity 8192 (2^13) + metadata 768
    defer allocator.free(ring_buf);
    @memset(ring_buf, 0);
    var rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(ring_buf);

    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const sock = try aeron.net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer aeron.net.closeSocket(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();

    // Write CLIENT_KEEPALIVE command to ring buffer
    // Format: [0..8] client_id, [8..16] timestamp
    var keepalive_buf: [16]u8 = undefined;
    std.mem.writeInt(i64, keepalive_buf[0..8], 42, .little); // client_id
    const timestamp: i64 = aeron.time.milliTimestamp();
    std.mem.writeInt(i64, keepalive_buf[8..16], timestamp, .little); // timestamp

    const wrote = rb.write(0x06, &keepalive_buf);
    try std.testing.expect(wrote);

    // Call doWork — should not crash
    _ = conductor.doWork();

    // Verify the client was registered
    try std.testing.expectEqual(@as(usize, 1), conductor.clients.items.len);
    try std.testing.expectEqual(@as(i64, 42), conductor.clients.items[0].client_id);
}
