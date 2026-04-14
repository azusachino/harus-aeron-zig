//! Pub/sub churn soak — add/remove publications across N cycles.
//! Mirrors the pattern in conductor_soak.zig: binary command buffers, full conductor init.

const std = @import("std");
const aeron = @import("aeron");

fn getSoakIterations() usize {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SOAK_ITERS")) |env| {
        defer std.testing.allocator.free(env);
        return std.fmt.parseInt(usize, env, 10) catch 50;
    } else |_| {
        return 50;
    }
}

test "pubsub_churn: add and remove publications across N cycles" {
    const allocator = std.testing.allocator;
    const iterations = getSoakIterations();
    const channel = "aeron:udp?endpoint=localhost:20125";

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

    var conductor = try aeron.driver.conductor.DriverConductor.init(
        allocator,
        &rb,
        &bcast,
        &cm,
        &receiver,
        &sender,
        &recv_ep,
        false,
        "/tmp",
        5_000_000_000,
        5_000_000_000,
        5_000_000_000,
    );
    defer conductor.deinit();
    conductor.recv_bound = true;

    for (0..iterations) |idx| {
        var cmd_buf = try allocator.alloc(u8, 1024);
        defer allocator.free(cmd_buf);
        @memset(cmd_buf, 0);
        std.mem.writeInt(i64, cmd_buf[0..8], 5, .little);
        std.mem.writeInt(i64, cmd_buf[8..16], @as(i64, @intCast(idx)), .little);
        std.mem.writeInt(i32, cmd_buf[16..20], @as(i32, @intCast(idx + 3000)), .little);
        std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(cmd_buf[24 .. 24 + channel.len], channel);
        conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

        var rem: [24]u8 = undefined;
        std.mem.writeInt(i64, rem[0..8], 5, .little);
        std.mem.writeInt(i64, rem[8..16], @as(i64, @intCast(idx + 30000)), .little);
        std.mem.writeInt(i64, rem[16..24], @as(i64, @intCast(idx)), .little);
        conductor.handleRemovePublication(&rem);
    }

    try std.testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
}
