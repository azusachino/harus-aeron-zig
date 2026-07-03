// Publication lifecycle tests via ring buffer dispatch
// Tests ADD_PUBLICATION and REMOVE_PUBLICATION through the full rb.write -> doWork -> broadcast path.
// Reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java

const std = @import("std");
const aeron = @import("aeron");

fn makeRingBuffer(allocator: std.mem.Allocator) !struct { buf: []align(8) u8, rb: aeron.ipc.ring_buffer.ManyToOneRingBuffer } {
    const buf = try allocator.alignedAlloc(u8, .@"8", 8192 + 768);
    @memset(buf, 0);
    return .{ .buf = buf, .rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(buf) };
}

fn makeConductor(
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
    const conductor = try aeron.driver.conductor.DriverConductor.init(
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
    return .{
        .sock = sock,
        .recv_ep = recv_ep,
        .send_ep = send_ep,
        .sender = sender,
        .receiver = receiver,
        .conductor = conductor,
    };
}

test "ADD_PUBLICATION via ring buffer dispatches ON_PUBLICATION_READY" {
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

    var ctx = try makeConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const channel = "aeron:ipc";
    const stream_id: i32 = 1001;
    const client_id: i64 = 1;
    const correlation_id: i64 = 0xDEAD;

    // ADD_PUBLICATION payload: [0..8] client_id, [8..16] correlation_id, [16..20] stream_id,
    //                          [20..24] channel_len, [24..] channel
    var cmd_buf = try allocator.alloc(u8, 24 + channel.len);
    defer allocator.free(cmd_buf);
    @memset(cmd_buf, 0);
    std.mem.writeInt(i64, cmd_buf[0..8], client_id, .little);
    std.mem.writeInt(i64, cmd_buf[8..16], correlation_id, .little);
    std.mem.writeInt(i32, cmd_buf[16..20], stream_id, .little);
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    try std.testing.expect(rb_holder.rb.write(0x01, cmd_buf)); // CMD_ADD_PUBLICATION
    _ = ctx.conductor.doWork();

    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(
        @as(i32, aeron.driver.conductor.RESPONSE_ON_PUBLICATION_READY),
        rx.typeId(),
    );

    const payload = rx.buffer();
    try std.testing.expect(payload.len >= 36);

    const echo_correlation_id = std.mem.readInt(i64, payload[0..8], .little);
    const echo_stream_id = std.mem.readInt(i32, payload[20..24], .little);

    try std.testing.expectEqual(correlation_id, echo_correlation_id);
    try std.testing.expectEqual(stream_id, echo_stream_id);
}

test "duplicate ADD_PUBLICATION reuses existing entry" {
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

    var ctx = try makeConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const channel = "aeron:ipc";
    const stream_id: i32 = 2002;

    var cmd1 = try allocator.alloc(u8, 24 + channel.len);
    defer allocator.free(cmd1);
    @memset(cmd1, 0);
    std.mem.writeInt(i64, cmd1[0..8], 1, .little);
    std.mem.writeInt(i64, cmd1[8..16], 0x1111, .little);
    std.mem.writeInt(i32, cmd1[16..20], stream_id, .little);
    std.mem.writeInt(i32, cmd1[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd1[24 .. 24 + channel.len], channel);

    try std.testing.expect(rb_holder.rb.write(0x01, cmd1));
    _ = ctx.conductor.doWork();

    // Second ADD_PUBLICATION for same channel+stream — reuses same ring buffer
    var cmd2: [24 + channel.len]u8 = undefined;
    @memset(&cmd2, 0);
    std.mem.writeInt(i64, cmd2[0..8], 1, .little);
    std.mem.writeInt(i64, cmd2[8..16], 0x2222, .little);
    std.mem.writeInt(i32, cmd2[16..20], stream_id, .little);
    std.mem.writeInt(i32, cmd2[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd2[24 .. 24 + channel.len], channel);

    // Write second command and drain — should still only have 1 publication entry
    try std.testing.expect(rb_holder.rb.write(0x01, &cmd2));
    _ = ctx.conductor.doWork();

    try std.testing.expectEqual(@as(usize, 1), ctx.conductor.publications.items.len);
    try std.testing.expectEqual(@as(i32, 2), ctx.conductor.publications.items[0].ref_count);
}

test "ADD_PUBLICATION then REMOVE_PUBLICATION sends ON_OPERATION_SUCCESS" {
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

    var ctx = try makeConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    const channel = "aeron:ipc";
    const stream_id: i32 = 3003;
    const add_correlation_id: i64 = 0xBEEF;

    // ADD_PUBLICATION
    var add_cmd = try allocator.alloc(u8, 24 + channel.len);
    defer allocator.free(add_cmd);
    @memset(add_cmd, 0);
    std.mem.writeInt(i64, add_cmd[0..8], 1, .little);
    std.mem.writeInt(i64, add_cmd[8..16], add_correlation_id, .little);
    std.mem.writeInt(i32, add_cmd[16..20], stream_id, .little);
    std.mem.writeInt(i32, add_cmd[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(add_cmd[24 .. 24 + channel.len], channel);

    try std.testing.expect(rb_holder.rb.write(0x01, add_cmd));
    _ = ctx.conductor.doWork();

    try std.testing.expectEqual(@as(usize, 1), ctx.conductor.publications.items.len);

    // Drain the ON_PUBLICATION_READY broadcast
    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    _ = rx.receiveNext();

    // REMOVE_PUBLICATION: [0..8] client_id, [8..16] remove_correlation_id, [16..24] registration_id
    // registration_id = add_correlation_id (conductor sets registration_id = correlation_id)
    const remove_correlation_id: i64 = 0xF00D;
    var rm_cmd: [24]u8 = undefined;
    @memset(&rm_cmd, 0);
    std.mem.writeInt(i64, rm_cmd[0..8], 1, .little);
    std.mem.writeInt(i64, rm_cmd[8..16], remove_correlation_id, .little);
    std.mem.writeInt(i64, rm_cmd[16..24], add_correlation_id, .little);

    try std.testing.expect(rb_holder.rb.write(0x02, &rm_cmd)); // CMD_REMOVE_PUBLICATION
    _ = ctx.conductor.doWork();

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(
        @as(i32, aeron.driver.conductor.RESPONSE_ON_OPERATION_SUCCESS),
        rx.typeId(),
    );

    const payload = rx.buffer();
    try std.testing.expectEqual(remove_correlation_id, std.mem.readInt(i64, payload[0..8], .little));
}

test "ADD_PUBLICATION with invalid payload sends ON_ERROR" {
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

    var ctx = try makeConductor(allocator, &rb_holder.rb, &bcast, &cm);
    defer aeron.net.closeSocket(ctx.sock);
    defer ctx.sender.deinit();
    defer ctx.receiver.deinit();
    defer ctx.conductor.deinit();

    // Payload with valid header but negative channel_len to trigger error path
    const correlation_id: i64 = 0xABCD;
    var bad_cmd: [24]u8 = undefined;
    @memset(&bad_cmd, 0);
    std.mem.writeInt(i64, bad_cmd[0..8], 1, .little);
    std.mem.writeInt(i64, bad_cmd[8..16], correlation_id, .little);
    std.mem.writeInt(i32, bad_cmd[16..20], 99, .little);
    std.mem.writeInt(i32, bad_cmd[20..24], -1, .little); // negative channel_len

    try std.testing.expect(rb_holder.rb.write(0x01, &bad_cmd));
    _ = ctx.conductor.doWork();

    var rx = try aeron.ipc.broadcast.BroadcastReceiver.init(allocator, &bcast);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(
        @as(i32, aeron.driver.conductor.RESPONSE_ON_ERROR),
        rx.typeId(),
    );
}
