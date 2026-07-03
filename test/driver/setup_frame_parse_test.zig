// Test SETUP frame parsing in Receiver.processDatagram
// Verifies that raw UDP datagrams are correctly parsed into SetupSignal structs

const std = @import("std");
const aeron = @import("aeron");
const protocol = aeron.protocol;
const driver = aeron.driver;
const transport = aeron.transport;
const counters = aeron.ipc.counters;

test "processDatagram parses SETUP frame into pending_setups" {
    const allocator = std.testing.allocator;

    // Initialize counters
    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var counters_map = counters.CountersMap.init(meta_buf, values_buf);

    // Create dummy endpoints
    const dummy_socket = std.math.maxInt(std.posix.socket_t);
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    // Create receiver
    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &counters_map, null);
    defer receiver.deinit();

    // Build a 40-byte raw SETUP frame with known field values
    var buf: [40]u8 align(8) = undefined;
    @memset(&buf, 0);
    var header: protocol.SetupHeader = undefined;
    header.frame_length = 40;
    header.version = 0;
    header.flags = 0;
    header.type = @intFromEnum(protocol.FrameType.setup);
    header.term_offset = 0;
    header.session_id = 42;
    header.stream_id = 1001;
    header.initial_term_id = 100;
    header.active_term_id = 100;
    header.term_length = 65536;
    header.mtu = 1408;
    header.ttl = 0;

    @memcpy(&buf, std.mem.asBytes(&header));

    // Call processDatagram with the setup frame
    const dummy_addr = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123);
    const work = receiver.processDatagram(&buf, dummy_addr);

    // Verify work count
    try std.testing.expectEqual(@as(i32, 1), work);

    // Verify pending_setups has one entry
    try std.testing.expectEqual(@as(usize, 1), receiver.pending_setups.items.len);

    // Verify parsed field values
    const sig = receiver.pending_setups.items[0];
    try std.testing.expectEqual(@as(i32, 42), sig.session_id);
    try std.testing.expectEqual(@as(i32, 1001), sig.stream_id);
    try std.testing.expectEqual(@as(i32, 100), sig.initial_term_id);
    try std.testing.expectEqual(@as(i32, 100), sig.active_term_id);
    try std.testing.expectEqual(@as(i32, 65536), sig.term_length);
    try std.testing.expectEqual(@as(i32, 1408), sig.mtu);
    // Source address is preserved from input
    try std.testing.expect(sig.source_address.any.family == 2); // IPv4
}

test "processDatagram ignores frame with wrong type" {
    const allocator = std.testing.allocator;

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var counters_map = counters.CountersMap.init(meta_buf, values_buf);

    const dummy_socket = std.math.maxInt(std.posix.socket_t);
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &counters_map, null);
    defer receiver.deinit();

    // Build a 40-byte frame with DATA type (0x01) instead of SETUP (0x05), properly aligned
    var buf: [40]u8 align(8) = undefined;
    @memset(&buf, 0); // Zero-initialize the entire buffer
    std.mem.writeInt(i32, buf[0..4], 40, .little); // frame_length
    buf[4] = 0; // version
    buf[5] = 0; // flags
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.data), .little); // type = DATA
    // rest are zeros for this test

    const dummy_addr = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123);
    _ = receiver.processDatagram(&buf, dummy_addr);

    // DATA frames without an image should be skipped
    // work count may be 0 or 1 depending on image lookup, but pending_setups should be empty
    try std.testing.expectEqual(@as(usize, 0), receiver.pending_setups.items.len);
}

test "processDatagram returns 0 for datagram shorter than 8 bytes" {
    const allocator = std.testing.allocator;

    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var counters_map = counters.CountersMap.init(meta_buf, values_buf);

    const dummy_socket = std.math.maxInt(std.posix.socket_t);
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    var receiver = try driver.Receiver.init(allocator, &recv_ep, &send_ep, &counters_map, null);
    defer receiver.deinit();

    // Pass a 4-byte slice (too short for even a FrameHeader)
    var buf: [4]u8 = undefined;
    @memset(&buf, 0);
    const dummy_addr = aeron.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123);
    const result = receiver.processDatagram(&buf, dummy_addr);

    // Should return 0 and not queue anything
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expectEqual(@as(usize, 0), receiver.pending_setups.items.len);
}
