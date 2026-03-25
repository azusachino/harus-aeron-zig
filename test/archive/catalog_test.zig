// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/CatalogTest.java
// Aeron version: 1.46.7
// Coverage: recording descriptor written, read back

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("record_replay_test.zig");
    _ = @import("segment_rotation_test.zig");
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
