// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/ArchiveTest.java
// Aeron version: 1.50.2
// Coverage: replay yields same messages in order

const std = @import("std");
const aeron = @import("aeron");

test "ReplaySession: yields recorded data in order" {
    const allocator = std.testing.allocator;
    const source_data = "hello aeron archive";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1, // replay_session_id
        101, // recording_id
        0, // position
        0, // length
        0, // recording_start_position
        source_data,
    );
    defer session.deinit();

    const chunk = session.readChunk(source_data.len).?;
    try std.testing.expectEqualStrings(source_data, chunk);
}

test "ReplaySession: reads data in multiple chunk calls" {
    const allocator = std.testing.allocator;
    const source_data = "0123456789abcdefghij";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        0,
        0,
        0,
        source_data,
    );
    defer session.deinit();

    // Call readChunk(5) repeatedly until complete
    var all_data: [20]u8 = undefined;
    var index: usize = 0;

    while (session.readChunk(5)) |chunk| {
        @memcpy(all_data[index .. index + chunk.len], chunk);
        index += chunk.len;
    }

    try std.testing.expectEqual(@as(usize, 20), index);
    try std.testing.expectEqualSlices(u8, source_data, all_data[0..20]);
}

test "ReplaySession: isComplete returns false while data remains" {
    const allocator = std.testing.allocator;
    const source_data = "data";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        0,
        0,
        0,
        source_data,
    );
    defer session.deinit();

    try std.testing.expect(!session.isComplete());
    _ = session.readChunk(100);
    try std.testing.expect(session.isComplete());
}

test "ReplaySession: position advances as chunks are read" {
    const allocator = std.testing.allocator;
    const source_data = "abcdefghij";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        0,
        0,
        0,
        source_data,
    );
    defer session.deinit();

    try std.testing.expectEqual(@as(i64, 0), session.current_position);

    _ = session.readChunk(3);
    try std.testing.expectEqual(@as(i64, 3), session.current_position);

    _ = session.readChunk(4);
    try std.testing.expectEqual(@as(i64, 7), session.current_position);

    _ = session.readChunk(10);
    try std.testing.expectEqual(@as(i64, 10), session.current_position);
}

test "ReplaySession: init with start_position=10 starts at byte 10" {
    const allocator = std.testing.allocator;
    const source_data = "0123456789ABCDEFGHIJ";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        10, // start_position
        0,
        0,
        source_data,
    );
    defer session.deinit();

    const chunk = session.readChunk(100).?;
    try std.testing.expectEqual(@as(usize, 10), chunk.len);
    try std.testing.expectEqualSlices(u8, "ABCDEFGHIJ", chunk);
}

test "ReplaySession: length=0 means replay all from start_position" {
    const allocator = std.testing.allocator;
    const source_data = "0123456789";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        0,
        0, // length=0 means all
        0,
        source_data,
    );
    defer session.deinit();

    var total: usize = 0;
    while (session.readChunk(3)) |chunk| {
        total += chunk.len;
    }

    try std.testing.expectEqual(@as(usize, 10), total);
}

test "ReplaySession: empty source data returns null immediately" {
    const allocator = std.testing.allocator;
    const source_data = "";

    var session = try aeron.archive.replayer.ReplaySession.init(
        allocator,
        1,
        1,
        0,
        0,
        0,
        source_data,
    );
    defer session.deinit();

    const chunk = session.readChunk(100);
    try std.testing.expect(chunk == null);
    try std.testing.expect(session.isComplete());
}
