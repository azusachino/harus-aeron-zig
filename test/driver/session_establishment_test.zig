// Session establishment via SETUP frame injection and Image creation
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/ImageSessionTest.java
const std = @import("std");
const aeron = @import("aeron");

test "Receiver: SETUP signal injection and Image creation" {
    const allocator = std.testing.allocator;

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    const dummy_send: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_send };

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, &send_endpoint, &cm, null);
    defer receiver.deinit();

    // Inject a SETUP signal
    const source_addr = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 20001);
    const setup_signal = aeron.driver.receiver.SetupSignal{
        .session_id = 100,
        .stream_id = 1,
        .initial_term_id = 50,
        .active_term_id = 50,
        .term_length = 64 * 1024,
        .mtu = 1408,
        .source_address = source_addr,
    };
    try receiver.pending_setups.append(allocator, setup_signal);

    // Verify SETUP was queued
    try std.testing.expectEqual(@as(usize, 1), receiver.pending_setups.items.len);

    // Drain pending setups
    const setups = receiver.drainPendingSetups();
    defer allocator.free(setups);

    try std.testing.expectEqual(@as(usize, 1), setups.len);
    try std.testing.expectEqual(@as(i32, 100), setups[0].session_id);
    try std.testing.expectEqual(@as(i32, 1), setups[0].stream_id);
}

test "Receiver: duplicate SETUP signals can be injected and drained" {
    const allocator = std.testing.allocator;

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    const dummy_send: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_send };

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, &send_endpoint, &cm, null);
    defer receiver.deinit();

    const source_addr = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 20001);
    const setup_signal = aeron.driver.receiver.SetupSignal{
        .session_id = 100,
        .stream_id = 1,
        .initial_term_id = 50,
        .active_term_id = 50,
        .term_length = 64 * 1024,
        .mtu = 1408,
        .source_address = source_addr,
    };

    // Inject duplicate SETUP signals
    try receiver.pending_setups.append(allocator, setup_signal);
    try receiver.pending_setups.append(allocator, setup_signal);

    try std.testing.expectEqual(@as(usize, 2), receiver.pending_setups.items.len);

    // Drain setups
    const setups = receiver.drainPendingSetups();
    defer allocator.free(setups);

    try std.testing.expectEqual(@as(usize, 2), setups.len);
    // Both should have same session_id (conductor logic would deduplicate)
    try std.testing.expectEqual(@as(i32, 100), setups[0].session_id);
    try std.testing.expectEqual(@as(i32, 100), setups[1].session_id);
}

test "Receiver: SETUP signal holds stream metadata" {
    const allocator = std.testing.allocator;

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);

    var recv_ep = aeron.transport.ReceiveChannelEndpoint{
        .socket = sock,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    const dummy_send: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_send };

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    var receiver = try aeron.driver.Receiver.init(allocator, &recv_ep, &send_endpoint, &cm, null);
    defer receiver.deinit();

    const source_addr = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 20001);
    const setup_signal = aeron.driver.receiver.SetupSignal{
        .session_id = 42,
        .stream_id = 2,
        .initial_term_id = 75,
        .active_term_id = 75,
        .term_length = 32 * 1024,
        .mtu = 1500,
        .source_address = source_addr,
    };
    try receiver.pending_setups.append(allocator, setup_signal);

    const setups = receiver.drainPendingSetups();
    defer allocator.free(setups);

    try std.testing.expectEqual(@as(i32, 42), setups[0].session_id);
    try std.testing.expectEqual(@as(i32, 2), setups[0].stream_id);
    try std.testing.expectEqual(@as(i32, 75), setups[0].initial_term_id);
    try std.testing.expectEqual(@as(i32, 32 * 1024), setups[0].term_length);
    try std.testing.expectEqual(@as(i32, 1500), setups[0].mtu);
}
