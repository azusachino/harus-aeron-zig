// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java
// Aeron version: 1.46.7
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

    const meta_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(meta_buf);
    const values_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(values_buf);
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

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false);
    defer conductor.deinit();

    // 1. Add publication
    const channel = "aeron:udp?endpoint=localhost:20121";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 10001, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[16..20], 1001, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

    try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try std.testing.expectEqual(@as(i32, 1001), conductor.publications.items[0].stream_id);

    // 2. Remove publication
    var remove_cmd: [16]u8 = undefined;
    std.mem.writeInt(i64, remove_cmd[0..8], 10002, .little); // correlation_id
    std.mem.writeInt(i64, remove_cmd[8..16], 10001, .little); // registration_id

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

    const meta_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(meta_buf);
    const values_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(values_buf);
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

    var conductor = try aeron.driver.conductor.DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false);
    defer conductor.deinit();

    // 1. Add subscription
    const channel = "aeron:udp?endpoint=localhost:20121";
    var cmd_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);

    std.mem.writeInt(i64, cmd_buf[0..8], 20001, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[16..20], 1001, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    conductor.handleAddSubscription(cmd_buf[0 .. 24 + channel.len]);

    try std.testing.expectEqual(@as(usize, 1), conductor.subscriptions.items.len);
    try std.testing.expectEqual(@as(i32, 1001), conductor.subscriptions.items[0].stream_id);

    // 2. Remove subscription
    var remove_cmd: [16]u8 = undefined;
    std.mem.writeInt(i64, remove_cmd[0..8], 20002, .little); // correlation_id
    std.mem.writeInt(i64, remove_cmd[8..16], 20001, .little); // registration_id

    conductor.handleRemoveSubscription(&remove_cmd);
    try std.testing.expectEqual(@as(usize, 0), conductor.subscriptions.items.len);
}
