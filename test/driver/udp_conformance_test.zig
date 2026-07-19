// UDP conformance tests translated from Aeron SenderTest, ReceiverTest, and FlowControlTest.
const std = @import("std");
const aeron = @import("aeron");

const protocol = aeron.protocol;
const net = aeron.net;
const transport = aeron.transport;
const driver = aeron.driver;
const counters = aeron.ipc.counters;

fn makeCounters(allocator: std.mem.Allocator) !struct {
    meta: []align(64) u8,
    values: []align(64) u8,
    map: counters.CountersMap,
} {
    const meta = try allocator.alignedAlloc(u8, .@"64", 4096);
    errdefer allocator.free(meta);
    @memset(meta, 0);
    const values = try allocator.alignedAlloc(u8, .@"64", 4096);
    @memset(values, 0);
    return .{ .meta = meta, .values = values, .map = counters.CountersMap.init(meta, values) };
}

test "ReceiverTest: STATUS datagram preserves all flow-control fields" {
    const allocator = std.testing.allocator;
    var storage = try makeCounters(allocator);
    defer allocator.free(storage.meta);
    defer allocator.free(storage.values);

    const dummy_socket = std.math.maxInt(std.posix.socket_t);
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = transport.SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &storage.map, null);
    defer receiver.deinit();

    var frame: protocol.StatusMessage = undefined;
    frame.frame_length = protocol.StatusMessage.LENGTH;
    frame.version = protocol.VERSION;
    frame.flags = 0;
    frame.type = @intFromEnum(protocol.FrameType.status);
    frame.session_id = 42;
    frame.stream_id = 1001;
    frame.consumption_term_id = 17;
    frame.consumption_term_offset = 4096;
    frame.receiver_window = 65536;
    frame.receiver_id = 0x1020304050607080;

    const source = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123);
    const bytes = std.mem.asBytes(&frame);
    try std.testing.expectEqual(@as(i32, 1), receiver.processDatagram(bytes, source));

    const messages = receiver.drainPendingStatusMessages();
    defer allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(@as(i32, 42), messages[0].session_id);
    try std.testing.expectEqual(@as(i32, 1001), messages[0].stream_id);
    try std.testing.expectEqual(@as(i32, 17), messages[0].consumption_term_id);
    try std.testing.expectEqual(@as(i32, 4096), messages[0].consumption_term_offset);
    try std.testing.expectEqual(@as(i32, 65536), messages[0].receiver_window);
    try std.testing.expectEqual(@as(i64, 0x1020304050607080), messages[0].receiver_id);
}

test "ReceiverTest: packed SETUP and STATUS frames are both dispatched" {
    const allocator = std.testing.allocator;
    var storage = try makeCounters(allocator);
    defer allocator.free(storage.meta);
    defer allocator.free(storage.values);

    const dummy_socket = std.math.maxInt(std.posix.socket_t);
    var recv_ep = transport.ReceiveChannelEndpoint{ .socket = dummy_socket, .bound_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0) };
    var send_ep = transport.SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &storage.map, null);
    defer receiver.deinit();

    var datagram: [128]u8 align(8) = undefined;
    @memset(&datagram, 0);

    var setup: protocol.SetupHeader = undefined;
    setup.frame_length = protocol.SetupHeader.LENGTH;
    setup.version = protocol.VERSION;
    setup.flags = 0;
    setup.type = @intFromEnum(protocol.FrameType.setup);
    setup.term_offset = 0;
    setup.session_id = 7;
    setup.stream_id = 8;
    setup.initial_term_id = 9;
    setup.active_term_id = 9;
    setup.term_length = 65536;
    setup.mtu = 1408;
    setup.ttl = 0;
    @memcpy(datagram[0..protocol.SetupHeader.LENGTH], std.mem.asBytes(&setup));

    var status: protocol.StatusMessage = undefined;
    status.frame_length = protocol.StatusMessage.LENGTH;
    status.version = protocol.VERSION;
    status.flags = 0;
    status.type = @intFromEnum(protocol.FrameType.status);
    status.session_id = 7;
    status.stream_id = 8;
    status.consumption_term_id = 9;
    status.consumption_term_offset = 0;
    status.receiver_window = 16384;
    status.receiver_id = 1;
    // Aeron aligns every frame to 32 bytes inside a datagram.
    @memcpy(datagram[64 .. 64 + protocol.StatusMessage.LENGTH], std.mem.asBytes(&status));

    const source = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40124);
    try std.testing.expectEqual(@as(i32, 2), receiver.processDatagram(&datagram, source));
    try std.testing.expectEqual(@as(usize, 1), receiver.pending_setups.items.len);
    try std.testing.expectEqual(@as(usize, 1), receiver.pending_status_messages.items.len);
    try std.testing.expectEqual(@as(i32, 7), receiver.pending_status_messages.items[0].session_id);
}

test "ReceiverTest: STATUS response uses the image source address and wire layout" {
    const allocator = std.testing.allocator;
    var storage = try makeCounters(allocator);
    defer allocator.free(storage.meta);
    defer allocator.free(storage.values);

    const source_socket = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);
    defer net.closeSocket(source_socket);
    var source_bind = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try net.bindSocket(source_socket, &source_bind.any, source_bind.getOsSockLen());
    const source_address = try net.getSockName(source_socket);

    const send_socket = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);
    defer net.closeSocket(send_socket);
    var recv_ep = transport.ReceiveChannelEndpoint{ .socket = std.math.maxInt(std.posix.socket_t), .bound_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0) };
    var send_ep = transport.SendChannelEndpoint{ .socket = send_socket };
    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &storage.map, null);
    defer receiver.deinit();

    var log_buffer = try aeron.logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buffer.deinit();
    const hwm = storage.map.allocate(counters.RECEIVER_HWM, "hwm");
    const subscriber_position = storage.map.allocate(counters.SUBSCRIBER_POSITION, "subscriber");
    storage.map.set(subscriber_position.counter_id, 65536);
    var image = driver.receiver.Image.init(42, 1001, 65536, 1408, 10, 11, &log_buffer, hwm, subscriber_position, source_address);
    defer image.deinit();

    try receiver.sendStatus(&image);
    var bytes: [protocol.StatusMessage.LENGTH]u8 = undefined;
    var received: usize = 0;
    var source: net.Address = undefined;
    var source_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    for (0..100) |_| {
        received = net.recvFrom(source_socket, &bytes, 0, &source.any, &source_len) catch |err| {
            if (err == error.WouldBlock) {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
                continue;
            }
            return err;
        };
        break;
    }
    try std.testing.expectEqual(@as(usize, protocol.StatusMessage.LENGTH), received);
    const status = @as(*const protocol.StatusMessage, @ptrCast(@alignCast(&bytes)));
    try std.testing.expectEqual(@as(i32, protocol.StatusMessage.LENGTH), status.frame_length);
    try std.testing.expectEqual(@as(u16, @intFromEnum(protocol.FrameType.status)), status.type);
    try std.testing.expectEqual(@as(i32, 42), status.session_id);
    try std.testing.expectEqual(@as(i32, 1001), status.stream_id);
    try std.testing.expectEqual(@as(i32, 11), status.consumption_term_id);
    try std.testing.expectEqual(@as(i32, 0), status.consumption_term_offset);
    try std.testing.expectEqual(@as(i32, 65536), status.receiver_window);
}

test "FlowControlTest: unicast limit is receiver position plus window" {
    var strategy = aeron.driver.flow_control.FlowControl{ .unicast = .{} };
    const limit = strategy.onStatusMessage(1, 2, 17, 4096, 65536, 10, 65536, 0, 0);
    try std.testing.expectEqual(@as(i64, 528384), limit);
}

test "FlowControlTest: multicast limit follows slowest active receiver" {
    const allocator = std.testing.allocator;
    var multicast = aeron.driver.flow_control.MinMulticastFlowControl.init(allocator, 100);
    defer multicast.deinit();

    const first = multicast.onStatusMessage(1, 2, 10, 0, 1000, 10, 65536, 11, 1000);
    const second = multicast.onStatusMessage(1, 2, 10, 0, 500, 10, 65536, 12, 1000);
    try std.testing.expectEqual(@as(i64, 1000), first);
    try std.testing.expectEqual(@as(i64, 500), second);
    try std.testing.expectEqual(@as(i64, 500), multicast.onIdle(1050, second, 0));
    try std.testing.expectEqual(@as(i64, 500), multicast.onIdle(1201, second, 0));
}

test "UdpChannelTest: ephemeral receive endpoint exposes its assigned port" {
    const allocator = std.testing.allocator;
    var channel = try transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=127.0.0.1:0");
    defer channel.deinit(allocator);
    var endpoint = try transport.ReceiveChannelEndpoint.open(&channel);
    defer endpoint.close();
    try endpoint.bind();
    try std.testing.expect(endpoint.bound_address.getPort() != 0);
}
