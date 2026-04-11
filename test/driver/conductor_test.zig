// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java
// Aeron version: 1.50.2
// Coverage: add/remove publication, add/remove subscription, IPC command dispatch

const std = @import("std");
const aeron = @import("aeron");

test "DriverConductor: handleAddPublication and handleRemovePublication" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = std.math.maxInt(std.posix.socket_t);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();
    conductor.recv_bound = true;

    // 1. Add publication
    const channel = "aeron:udp?endpoint=localhost:20121";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 5, .little); // client_id
    std.mem.writeInt(i64, cmd_buf[8..16], 10001, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[16..20], 1001, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

    try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try std.testing.expectEqual(@as(i32, 1001), conductor.publications.items[0].stream_id);
    try std.testing.expect(conductor.publications.items[0].log_file_name.len > 0);
    const lb = conductor.publications.items[0].log_buffer.?;
    const meta = lb.metaData();
    try std.testing.expectEqual(@as(i32, aeron.protocol.DataHeader.LENGTH), std.mem.readInt(i32, meta.buffer[268..272], .little));
    try std.testing.expectEqual(@as(i32, 1408), std.mem.readInt(i32, meta.buffer[272..276], .little));
    try std.testing.expectEqual(@as(i32, 64 * 1024), std.mem.readInt(i32, meta.buffer[276..280], .little));
    try std.testing.expectEqual(@as(i32, 4096), std.mem.readInt(i32, meta.buffer[280..284], .little));

    // 2. Remove publication
    var remove_cmd: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_cmd[0..8], 5, .little); // client_id
    std.mem.writeInt(i64, remove_cmd[8..16], 10002, .little); // correlation_id
    std.mem.writeInt(i64, remove_cmd[16..24], 10001, .little); // registration_id

    conductor.handleRemovePublication(&remove_cmd);
    try std.testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
}

test "DriverConductor: handleAddSubscription and handleRemoveSubscription" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();

    // 1. Add subscription
    const channel = "aeron:udp?endpoint=localhost:20121";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 5, .little); // client_id
    std.mem.writeInt(i64, cmd_buf[8..16], 20001, .little); // correlation_id
    std.mem.writeInt(i64, cmd_buf[16..24], -1, .little); // registration correlation id
    std.mem.writeInt(i32, cmd_buf[24..28], 1001, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[28..32], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[32 .. 32 + channel.len], channel);

    conductor.handleAddSubscription(cmd_buf[0 .. 32 + channel.len]);

    try std.testing.expectEqual(@as(usize, 1), conductor.subscriptions.items.len);
    try std.testing.expectEqual(@as(i32, 1001), conductor.subscriptions.items[0].stream_id);

    // 2. Remove subscription
    var remove_cmd: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_cmd[0..8], 5, .little); // client_id
    std.mem.writeInt(i64, remove_cmd[8..16], 20002, .little); // correlation_id
    std.mem.writeInt(i64, remove_cmd[16..24], 20001, .little); // registration_id

    conductor.handleRemoveSubscription(&remove_cmd);
    try std.testing.expectEqual(@as(usize, 0), conductor.subscriptions.items.len);
}

test "DriverConductor: multiple publications on same channel with reference counting" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = std.math.maxInt(std.posix.socket_t);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();
    conductor.recv_bound = true;

    const channel = "aeron:ipc";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    // Add first publication
    std.mem.writeInt(i64, cmd_buf[0..8], 5, .little);
    std.mem.writeInt(i64, cmd_buf[8..16], 10001, .little);
    std.mem.writeInt(i32, cmd_buf[16..20], 1, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);
    try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try std.testing.expectEqual(@as(i32, 1), conductor.publications.items[0].ref_count);

    // Add same channel again (non-exclusive) — should increment ref_count
    @memset(cmd_buf, 0);
    std.mem.writeInt(i64, cmd_buf[0..8], 5, .little);
    std.mem.writeInt(i64, cmd_buf[8..16], 10002, .little);
    std.mem.writeInt(i32, cmd_buf[16..20], 1, .little);
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);
    try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try std.testing.expectEqual(@as(i32, 2), conductor.publications.items[0].ref_count);

    // Remove once — publication still exists
    var remove_cmd: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_cmd[0..8], 5, .little);
    std.mem.writeInt(i64, remove_cmd[8..16], 10003, .little);
    std.mem.writeInt(i64, remove_cmd[16..24], 10001, .little); // registration_id from first add
    conductor.handleRemovePublication(&remove_cmd);
    try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);

    // Remove again — now publication is gone
    @memset(&remove_cmd, 0);
    std.mem.writeInt(i64, remove_cmd[0..8], 5, .little);
    std.mem.writeInt(i64, remove_cmd[8..16], 10004, .little);
    std.mem.writeInt(i64, remove_cmd[16..24], 10002, .little); // registration_id from second add
    conductor.handleRemovePublication(&remove_cmd);
    try std.testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
}

test "DriverConductor: ADD_SUBSCRIPTION with no matching publication" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = std.math.maxInt(std.posix.socket_t);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();

    // Add subscription without any publication
    const channel = "aeron:udp?endpoint=localhost:20121";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 5, .little);
    std.mem.writeInt(i64, cmd_buf[8..16], 20001, .little);
    std.mem.writeInt(i64, cmd_buf[16..24], -1, .little);
    std.mem.writeInt(i32, cmd_buf[24..28], 1001, .little);
    std.mem.writeInt(i32, cmd_buf[28..32], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[32 .. 32 + channel.len], channel);

    conductor.handleAddSubscription(cmd_buf[0 .. 32 + channel.len]);

    // Subscription should be created
    try std.testing.expectEqual(@as(usize, 1), conductor.subscriptions.items.len);
    try std.testing.expectEqual(@as(i32, 1001), conductor.subscriptions.items[0].stream_id);

    // No images should exist
    try std.testing.expectEqual(@as(usize, 0), receiver.images.items.len);
}

test "DriverConductor: CLIENT_KEEPALIVE message processed without error" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = std.math.maxInt(std.posix.socket_t);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", 5_000_000_000, 5_000_000_000, 5_000_000_000);
    defer conductor.deinit();

    // Send CLIENT_KEEPALIVE
    const client_id: i64 = 42;
    var keepalive_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, keepalive_buf[0..8], client_id, .little);

    conductor.handleClientKeepalive(&keepalive_buf);

    // Should register the client
    try std.testing.expectEqual(@as(usize, 1), conductor.clients.items.len);
    try std.testing.expectEqual(client_id, conductor.clients.items[0].client_id);
}

test "DriverConductor: client eviction on timeout" {
    const allocator = std.testing.allocator;

    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
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

    const sock = std.math.maxInt(std.posix.socket_t);
    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = sock };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, sender.send_endpoint, &cm, null);
    defer receiver.deinit();

    const timeout_ns: i64 = 5_000_000_000; // 5 seconds
    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp", timeout_ns, timeout_ns, timeout_ns);
    defer conductor.deinit();

    // Register a client
    const client_id: i64 = 99;
    var keepalive_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, keepalive_buf[0..8], client_id, .little);
    conductor.handleClientKeepalive(&keepalive_buf);

    try std.testing.expectEqual(@as(usize, 1), conductor.clients.items.len);

    // Set current time far in the future (past timeout)
    conductor.setCurrentTimeMs(10_000_000); // 10 seconds
    conductor.checkClientLiveness();

    // Client should be evicted
    try std.testing.expectEqual(@as(usize, 0), conductor.clients.items.len);
}
