// Task 4.1: File-backed segment rotation test
// Verifies that RecordingWriter rotates to a new segment file when data crosses
// the segment_file_length boundary, producing two .dat files on disk.
//
// Note: RecordingWriter writes the full payload to the current segment file, then
// checks whether rotation is needed. So when 70 bytes are written with a 64-byte
// segment length, the first segment file receives all 70 bytes and then the writer
// rotates, creating a second (initially empty) .dat file.

const std = @import("std");
const aeron = @import("aeron");

test "RecordingWriter: 64-byte segment rotation produces two .dat files" {
    const allocator = std.testing.allocator;

    // Use a unique temp dir to avoid collisions with parallel test runs
    const archive_dir = "/tmp/aeron-file-rotation-test-64";
    std.fs.deleteTreeAbsolute(archive_dir) catch {};
    defer std.fs.deleteTreeAbsolute(archive_dir) catch {};

    const segment_len: i64 = 64;
    var writer = try aeron.archive.recorder.RecordingWriter.initWithSegment(
        allocator,
        1, // recording_id
        0, // start_position
        segment_len,
        archive_dir,
    );
    defer writer.deinit();

    // Write 70 bytes — crosses the 64-byte segment boundary.
    // All 70 bytes go to segment 0, then rotation creates segment 1.
    const data = [_]u8{0xAB} ** 70;
    try writer.write(&data);
    try writer.flush();

    // stop_position should be 70
    try std.testing.expectEqual(@as(i64, 70), writer.stop_position);

    // After rotation, current_segment_base == stop_position == 70
    try std.testing.expectEqual(@as(i64, 70), writer.current_segment_base);

    // Segment 0: the initial file at base 0 — received the full 70-byte payload
    const seg0_path = try aeron.archive.recorder.RecordingWriter.segmentFilePath(
        allocator,
        archive_dir,
        1, // recording_id
        0, // base_position
    );
    defer allocator.free(seg0_path);
    const seg0 = try std.fs.openFileAbsolute(seg0_path, .{});
    defer seg0.close();
    try std.testing.expectEqual(@as(u64, 70), (try seg0.stat()).size);

    // Segment 1: the rotated file at base 70 — exists but is empty
    const seg1_path = try aeron.archive.recorder.RecordingWriter.segmentFilePath(
        allocator,
        archive_dir,
        1, // recording_id
        70, // base_position after rotation
    );
    defer allocator.free(seg1_path);
    const seg1 = try std.fs.openFileAbsolute(seg1_path, .{});
    defer seg1.close();
    // Second segment file exists (zero bytes — no further writes after rotation)
    try std.testing.expectEqual(@as(u64, 0), (try seg1.stat()).size);

    // Verify there are exactly 2 .dat files in the archive directory
    var dir = try std.fs.openDirAbsolute(archive_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var dat_count: usize = 0;
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".dat")) {
            dat_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), dat_count);
}
