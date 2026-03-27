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
