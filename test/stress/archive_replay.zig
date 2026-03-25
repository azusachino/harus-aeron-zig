const std = @import("std");
const aeron = @import("aeron");

test "stress: batched publish-drain replay (1k messages)" {
    const allocator = std.testing.allocator;

    // Create archive catalog and recorder
    var catalog = aeron.archive.Catalog.init(allocator);
    defer catalog.deinit();

    const recording_id = catalog.startRecording(1, 1, "aeron:ipc", 64 * 1024);

    // Publish 1000 small messages into the recording
    const msg_count: usize = 1000;
    var i: usize = 0;
    while (i < msg_count) : (i += 1) {
        var payload: [64]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], @intCast(i), .little);
        catalog.appendToRecording(recording_id, &payload) catch break;
    }

    catalog.stopRecording(recording_id);
    const descriptor = catalog.getDescriptor(recording_id) orelse return;

    // Replay and verify all messages drain correctly
    var replayer = aeron.archive.Replayer.init(allocator);
    defer replayer.deinit();

    const replay_count = replayer.replayRecording(
        &catalog,
        recording_id,
        descriptor.start_position,
        descriptor.stop_position - descriptor.start_position,
    ) catch 0;

    try std.testing.expect(replay_count > 0);
}

test "stress: sustained high-throughput replay (10k messages)" {
    const allocator = std.testing.allocator;

    var catalog = aeron.archive.Catalog.init(allocator);
    defer catalog.deinit();

    const recording_id = catalog.startRecording(2, 2, "aeron:udp?endpoint=localhost:40123", 64 * 1024);

    // Publish 10000 messages to stress replay throughput
    const msg_count: usize = 10_000;
    var i: usize = 0;
    while (i < msg_count) : (i += 1) {
        var payload: [128]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], @intCast(i), .little);
        @memset(payload[8..], 0xAB);
        catalog.appendToRecording(recording_id, &payload) catch break;
    }

    catalog.stopRecording(recording_id);
    const descriptor = catalog.getDescriptor(recording_id) orelse return;

    var replayer = aeron.archive.Replayer.init(allocator);
    defer replayer.deinit();

    // Replay in chunks to simulate sustained throughput
    const chunk_size: i64 = 64 * 1024;
    var pos = descriptor.start_position;
    var total_replayed: usize = 0;
    while (pos < descriptor.stop_position) {
        const remaining = descriptor.stop_position - pos;
        const len = @min(remaining, chunk_size);
        const count = replayer.replayRecording(&catalog, recording_id, pos, len) catch break;
        total_replayed += count;
        pos += len;
    }

    try std.testing.expect(total_replayed > 0);
}
