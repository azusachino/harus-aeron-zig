// Task 4.2: File-backed replay — initFromFile + readInto
// Verifies that ReplaySession can initialize from a file on disk and read data
// back via readInto, byte-for-byte matching the original content.

const std = @import("std");
const aeron = @import("aeron");

test "ReplaySession: initFromFile reads file and readInto returns content" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/aeron-replay-test";
    const file_path = test_dir ++ "/1-0.dat";
    const content = "hello-aeron-replay";

    // Setup: create the temp dir and write test content (delete first if it exists)
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    try std.fs.makeDirAbsolute(test_dir);
    defer std.fs.deleteTreeAbsolute(test_dir) catch {};

    const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    try f.writeAll(content);
    f.close();

    // Create ReplaySession from file
    var session = try aeron.archive.replayer.ReplaySession.initFromFile(
        allocator,
        1, // replay_session_id
        1, // recording_id
        0, // position
        0, // length (0 = all)
        0, // recording_start_position
        file_path,
    );
    defer session.deinit();

    // Read into an 18-byte buffer
    var buf: [18]u8 = undefined;
    const n = try session.readInto(&buf);

    try std.testing.expectEqual(@as(usize, 18), n);
    try std.testing.expectEqualSlices(u8, content, buf[0..n]);

    // Session should be complete and inactive after reading all data
    try std.testing.expect(session.isComplete());
    try std.testing.expect(!session.isActive());
}
