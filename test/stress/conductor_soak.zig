// Driver Conductor Soak Test
// Stress-tests add/remove publication cycles for resource leak detection.
// Verifies publication list correctly manages lifecycle across N cycles.
//
// Default iterations: 100 (CI), set SOAK_ITERS=10000 for local soak.

const std = @import("std");
const aeron = @import("aeron");

fn getSoakIterations() usize {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SOAK_ITERS")) |env| {
        defer std.testing.allocator.free(env);
        return std.fmt.parseInt(usize, env, 10) catch 100;
    } else |_| {
        return 100;
    }
}

test "conductor_soak: add/remove publication cycles" {
    const allocator = std.testing.allocator;
    const iterations = getSoakIterations();

    // Setup ring buffer for commands
    const ring_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(ring_buf);
    var rb = aeron.ipc.ring_buffer.ManyToOneRingBuffer.init(ring_buf);

    // Setup broadcast transmitter
    var bcast = try aeron.ipc.broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    // Setup counters map
    const meta_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    const values_buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(values_buf);
    @memset(values_buf, 0);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    // Setup transport endpoints
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

    const channel = "aeron:udp?endpoint=localhost:20121";

    // Cycle add/remove publications
    for (0..iterations) |idx| {
        // Add publication
        var cmd_buf = try allocator.alloc(u8, 1024);
        defer allocator.free(cmd_buf);
        @memset(cmd_buf, 0);

        std.mem.writeInt(i64, cmd_buf[0..8], 5, .little); // client_id
        std.mem.writeInt(i64, cmd_buf[8..16], @as(i64, @intCast(idx)), .little); // correlation_id
        std.mem.writeInt(i32, cmd_buf[16..20], @as(i32, @intCast(idx + 1000)), .little); // stream_id
        std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

        conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

        // Verify publication added
        try std.testing.expectEqual(@as(usize, 1), conductor.publications.items.len);

        // Remove publication by registration_id (from correlation_id in add response)
        var remove_cmd: [24]u8 = undefined;
        std.mem.writeInt(i64, remove_cmd[0..8], 5, .little); // client_id
        std.mem.writeInt(i64, remove_cmd[8..16], @as(i64, @intCast(idx + 10000)), .little); // correlation_id
        // The registration_id equals the correlation_id of the add
        std.mem.writeInt(i64, remove_cmd[16..24], @as(i64, @intCast(idx)), .little);

        conductor.handleRemovePublication(&remove_cmd);

        // Verify publication removed
        try std.testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
    }
}

test "conductor_soak: publication lifecycle stress" {
    const allocator = std.testing.allocator;
    const iterations = getSoakIterations() / 2;

    // Setup infrastructure
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

    // Multiple channels to stress broader allocation patterns
    const channels = [_][]const u8{
        "aeron:udp?endpoint=localhost:20121",
        "aeron:udp?endpoint=localhost:20122",
        "aeron:udp?endpoint=localhost:20123",
    };

    var total_added: usize = 0;
    var total_removed: usize = 0;

    for (0..iterations) |idx| {
        const channel_idx = idx % channels.len;
        const channel = channels[channel_idx];

        // Add
        var cmd_buf = try allocator.alloc(u8, 1024);
        defer allocator.free(cmd_buf);
        @memset(cmd_buf, 0);

        std.mem.writeInt(i64, cmd_buf[0..8], 5, .little);
        std.mem.writeInt(i64, cmd_buf[8..16], @as(i64, @intCast(idx)), .little);
        std.mem.writeInt(i32, cmd_buf[16..20], @as(i32, @intCast(idx + 2000)), .little);
        std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

        conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);
        if (conductor.publications.items.len > 0) {
            total_added += 1;
        }

        // Remove if we have any
        if (conductor.publications.items.len > 0) {
            var remove_cmd: [24]u8 = undefined;
            std.mem.writeInt(i64, remove_cmd[0..8], 5, .little);
            std.mem.writeInt(i64, remove_cmd[8..16], @as(i64, @intCast(idx + 20000)), .little);
            std.mem.writeInt(i64, remove_cmd[16..24], @as(i64, @intCast(idx)), .little);

            conductor.handleRemovePublication(&remove_cmd);
            if (conductor.publications.items.len == 0) {
                total_removed += 1;
            }
        }
    }

    try std.testing.expect(total_added > 0);
    try std.testing.expect(total_removed > 0);
}
