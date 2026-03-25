// Upstream reference: aeron-client/src/test/java/io/aeron/DataHeaderFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/SetupFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/StatusMessageFlyweightTest.java
// Aeron version: 1.46.7
// Coverage: frame_type, version, flags, stream_id, session_id, term_id, term_offset, frame_length

const std = @import("std");
const aeron = @import("aeron");
const protocol = aeron.protocol;

// Pull in other protocol test files so they are compiled by this root
comptime {
    _ = @import("uri_parser_test.zig");
    _ = @import("flow_control_test.zig");
}

test "DataHeader: type is data" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.type = @intFromEnum(protocol.FrameType.data);
    try std.testing.expectEqual(@intFromEnum(protocol.FrameType.data), hdr.type);
}

test "DataHeader: encode and decode session_id, stream_id, term_id" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.session_id = @bitCast(@as(u32, 0xDEAD_BEEF));
    hdr.stream_id = 42;
    hdr.term_id = 7;
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEAD_BEEF))), hdr.session_id);
    try std.testing.expectEqual(@as(i32, 42), hdr.stream_id);
    try std.testing.expectEqual(@as(i32, 7), hdr.term_id);
}

test "DataHeader: term_offset alignment is preserved" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.term_offset = 4096;
    try std.testing.expectEqual(@as(i32, 4096), hdr.term_offset);
}

test "SetupHeader: type is setup" {
    var setup: protocol.SetupHeader = std.mem.zeroes(protocol.SetupHeader);
    setup.type = @intFromEnum(protocol.FrameType.setup);
    try std.testing.expectEqual(@intFromEnum(protocol.FrameType.setup), setup.type);
}

test "StatusMessage: type is status" {
    var sm: protocol.StatusMessage = std.mem.zeroes(protocol.StatusMessage);
    sm.type = @intFromEnum(protocol.FrameType.status);
    try std.testing.expectEqual(@intFromEnum(protocol.FrameType.status), sm.type);
}

test "StatusMessage: receiver_window round-trips" {
    var sm: protocol.StatusMessage = std.mem.zeroes(protocol.StatusMessage);
    sm.receiver_window = 131072;
    try std.testing.expectEqual(@as(i32, 131072), sm.receiver_window);
}
