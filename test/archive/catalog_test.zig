// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/CatalogTest.java
// Aeron version: 1.50.2
// Coverage: recording descriptor written, read back

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("record_replay_test.zig");
    _ = @import("segment_rotation_test.zig");
    _ = @import("file_rotation_test.zig");
    _ = @import("file_replay_test.zig");
}

test "Catalog: recording descriptor can be added and found" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    const rec_id = try catalog.addNewRecording(
        42, // session_id
        1001, // stream_id
        "aeron:udp?endpoint=localhost:20121",
        "source-identity",
        0, // initial_term_id
        128 * 1024 * 1024, // segment_file_length
        64 * 1024, // term_buffer_length
        1408, // mtu_length
        0, // start_position
        1000, // start_timestamp
    );

    try std.testing.expectEqual(@as(i64, 1), rec_id);
    const entry = catalog.recordingDescriptor(rec_id);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(i32, 1001), entry.?.stream_id);
}

test "Catalog: add 100 recordings and lookup specific ID" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    // Add 100 recordings
    for (1..101) |i| {
        const id = try catalog.addNewRecording(
            @as(i32, @intCast(i)),
            @as(i32, @intCast(i * 10)),
            "aeron:udp",
            "source",
            0,
            128 * 1024 * 1024,
            64 * 1024,
            1408,
            0,
            @as(i64, @intCast(i)),
        );
        try std.testing.expectEqual(@as(i64, @intCast(i)), id);
    }

    // Lookup recording_id=50
    const entry = catalog.recordingDescriptor(50);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(i64, 50), entry.?.recording_id);
    try std.testing.expectEqual(@as(i32, 500), entry.?.stream_id);
    try std.testing.expectEqual(@as(i32, 50), entry.?.session_id);
}

test "Catalog: updateStopPosition persists to descriptor" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    const recording_id = try catalog.addNewRecording(
        1,
        2,
        "ch",
        "src",
        0,
        128 * 1024 * 1024,
        64 * 1024,
        1408,
        0,
        100,
    );

    try catalog.updateStopPosition(recording_id, 1024 * 1024);

    const entry = catalog.recordingDescriptor(recording_id).?;
    try std.testing.expectEqual(@as(i64, 1024 * 1024), entry.stop_position);
}

test "Catalog: updateStopTimestamp persists to descriptor" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    const recording_id = try catalog.addNewRecording(
        1,
        2,
        "ch",
        "src",
        0,
        128 * 1024 * 1024,
        64 * 1024,
        1408,
        0,
        500,
    );

    try catalog.updateStopTimestamp(recording_id, 1500);

    const entry = catalog.recordingDescriptor(recording_id).?;
    try std.testing.expectEqual(@as(i64, 1500), entry.stop_timestamp);
}

test "Catalog: listRecordings from_id=1 count=5 returns 5 descriptors" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    for (1..11) |i| {
        _ = try catalog.addNewRecording(
            @as(i32, @intCast(i)),
            @as(i32, @intCast(i)),
            "ch",
            "src",
            0,
            128 * 1024 * 1024,
            64 * 1024,
            1408,
            0,
            @as(i64, @intCast(i)),
        );
    }

    var count: i32 = 0;
    const counter = struct {
        pub fn handle(entry: *const aeron.archive.catalog.RecordingDescriptorEntry) void {
            _ = entry;
        }
    };

    count = catalog.listRecordings(1, 5, &counter.handle);
    try std.testing.expectEqual(@as(i32, 5), count);
}

test "Catalog: listRecordings from_id=99 count=10 returns only 2" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    for (1..101) |i| {
        _ = try catalog.addNewRecording(
            @as(i32, @intCast(i % 100)),
            @as(i32, @intCast(i % 100)),
            "ch",
            "src",
            0,
            128 * 1024 * 1024,
            64 * 1024,
            1408,
            0,
            @as(i64, @intCast(i)),
        );
    }

    var count: i32 = 0;
    const counter = struct {
        pub fn handle(entry: *const aeron.archive.catalog.RecordingDescriptorEntry) void {
            _ = entry;
        }
    };

    count = catalog.listRecordings(99, 10, &counter.handle);
    try std.testing.expectEqual(@as(i32, 2), count);
}

test "Catalog: findLastMatchingRecording returns last on same channel+stream" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "aeron:udp|ep=localhost:40123", "src1", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 100);
    _ = try catalog.addNewRecording(2, 1, "aeron:udp|ep=localhost:40123", "src2", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 200);
    const id3 = try catalog.addNewRecording(3, 1, "aeron:udp|ep=localhost:40123", "src3", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 300);

    const found = catalog.findLastMatchingRecording(0, "aeron:udp|ep=localhost:40123", 1);
    try std.testing.expectEqual(id3, found);
}

test "Catalog: findLastMatchingRecording with non-matching channel returns null" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "ch1", "src1", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 100);
    _ = try catalog.addNewRecording(2, 1, "ch1", "src2", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 200);

    const found = catalog.findLastMatchingRecording(0, "nonexistent_channel", 1);
    try std.testing.expect(found == null);
}

test "Catalog: recordingDescriptor for non-existent ID returns null" {
    const allocator = std.testing.allocator;
    var catalog = aeron.archive.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "ch1", "src1", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 100);
    _ = try catalog.addNewRecording(2, 1, "ch2", "src2", 0, 128 * 1024 * 1024, 64 * 1024, 1408, 0, 200);

    const entry = catalog.recordingDescriptor(999);
    try std.testing.expect(entry == null);
}
