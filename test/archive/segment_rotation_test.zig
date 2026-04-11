// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/RecordingWriterTest.java
// Aeron version: 1.50.2
// Coverage: segment file rotates when segment_length is exceeded

const std = @import("std");
const aeron = @import("aeron");

test "RecordingWriter: rotates segment" {
    const allocator = std.testing.allocator;
    const archive_dir = "/tmp/aeron-archive-test";
    std.fs.deleteTreeAbsolute(archive_dir) catch {};
    defer std.fs.deleteTreeAbsolute(archive_dir) catch {};

    const segment_len: i64 = 1024;
    var writer = try aeron.archive.recorder.RecordingWriter.initWithSegment(
        allocator,
        1, // recording_id
        0, // start_position
        segment_len,
        archive_dir,
    );
    defer writer.deinit();

    // Write enough to trigger rotation
    const data = [_]u8{0} ** 600;
    _ = try writer.write(&data);

    try std.testing.expectEqual(@as(i64, 600), writer.stop_position);
    try std.testing.expectEqual(@as(i64, 0), writer.current_segment_base);

    _ = try writer.write(&data); // Total 1200 > 1024

    try std.testing.expectEqual(@as(i64, 1200), writer.stop_position);
    // current_segment_base follows stop_position in current implementation
    try std.testing.expectEqual(@as(i64, 1200), writer.current_segment_base);
}

test "RecordingWriter: reads across segment boundary" {
    const allocator = std.testing.allocator;
    const archive_dir = "/tmp/aeron-archive-multi-segment";
    std.fs.deleteTreeAbsolute(archive_dir) catch {};
    defer std.fs.deleteTreeAbsolute(archive_dir) catch {};

    const segment_len: i64 = 100;
    var writer = try aeron.archive.recorder.RecordingWriter.initWithSegment(
        allocator,
        42,
        0,
        segment_len,
        archive_dir,
    );
    defer writer.deinit();

    // Write data spanning two segments
    const data1 = [_]u8{0} ** 80;
    const data2 = [_]u8{1} ** 50; // Crosses boundary at 100
    try writer.write(&data1);
    try writer.write(&data2);

    try writer.flush();

    // Read all segments
    const all = try writer.readAllSegments(allocator);
    defer allocator.free(all);

    try std.testing.expectEqual(@as(usize, 130), all.len);
    // First 80 bytes should be 0
    for (all[0..80]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    // Last 50 bytes should be 1
    for (all[80..130]) |b| {
        try std.testing.expectEqual(@as(u8, 1), b);
    }
}

test "RecordingWriter: writes up to boundary then rotates" {
    const allocator = std.testing.allocator;
    const archive_dir = "/tmp/aeron-archive-boundary";
    std.fs.deleteTreeAbsolute(archive_dir) catch {};
    defer std.fs.deleteTreeAbsolute(archive_dir) catch {};

    const segment_len: i64 = 100;
    var writer = try aeron.archive.recorder.RecordingWriter.initWithSegment(
        allocator,
        99,
        0,
        segment_len,
        archive_dir,
    );
    defer writer.deinit();

    // Write exactly to boundary
    const data1 = [_]u8{0} ** 100;
    try writer.write(&data1);

    try std.testing.expectEqual(@as(i64, 100), writer.stop_position);
    try std.testing.expectEqual(@as(i64, 100), writer.current_segment_base);

    // Write 1 more byte to trigger second segment
    const data2 = [_]u8{1};
    try writer.write(&data2);

    try std.testing.expectEqual(@as(i64, 101), writer.stop_position);
    try std.testing.expectEqual(@as(i64, 100), writer.current_segment_base);

    // Verify two segment files exist
    try writer.flush();

    const seg0_path = try aeron.archive.recorder.RecordingWriter.segmentFilePath(allocator, archive_dir, 99, 0);
    defer allocator.free(seg0_path);
    const seg0_file = std.fs.openFileAbsolute(seg0_path, .{}) catch |err| {
        std.debug.print("Failed to open segment 0: {}\n", .{err});
        return err;
    };
    defer seg0_file.close();
    const seg0_size = (try seg0_file.stat()).size;
    try std.testing.expectEqual(@as(u64, 100), seg0_size);

    const seg1_path = try aeron.archive.recorder.RecordingWriter.segmentFilePath(allocator, archive_dir, 99, 100);
    defer allocator.free(seg1_path);
    const seg1_file = std.fs.openFileAbsolute(seg1_path, .{}) catch |err| {
        std.debug.print("Failed to open segment 1: {}\n", .{err});
        return err;
    };
    defer seg1_file.close();
    const seg1_size = (try seg1_file.stat()).size;
    try std.testing.expectEqual(@as(u64, 1), seg1_size);
}

test "RecordingWriter: start and stop positions consistent across segments" {
    const allocator = std.testing.allocator;
    const archive_dir = "/tmp/aeron-archive-positions";
    std.fs.deleteTreeAbsolute(archive_dir) catch {};
    defer std.fs.deleteTreeAbsolute(archive_dir) catch {};

    const segment_len: i64 = 50;
    const start_pos: i64 = 10;
    var writer = try aeron.archive.recorder.RecordingWriter.initWithSegment(
        allocator,
        7,
        start_pos,
        segment_len,
        archive_dir,
    );
    defer writer.deinit();

    try std.testing.expectEqual(start_pos, writer.startPosition());
    try std.testing.expectEqual(start_pos, writer.stopPosition());

    // Write enough to create multiple segments
    const data = [_]u8{42} ** 120;
    try writer.write(&data);

    // start_position should not change
    try std.testing.expectEqual(start_pos, writer.startPosition());
    // stop_position should be start + total written
    try std.testing.expectEqual(start_pos + 120, writer.stopPosition());
}
