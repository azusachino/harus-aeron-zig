// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/ArchiveTest.java
// Aeron version: 1.46.7
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
