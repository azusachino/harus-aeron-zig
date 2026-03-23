// Aeron Archive control protocol codec
// Reference: https://github.com/aeron-io/aeron/tree/master/aeron-archive/src/main/java/io/aeron/archive/codecs
// LESSON(archive/aeron): Archive uses a request/response protocol over Aeron streams (not raw UDP).
// LESSON(archive/zig): Every message is an extern struct to ensure bit-perfect wire compatibility with Java.
const std = @import("std");

pub const SourceLocation = enum(i32) {
    local = 0,
    remote = 1,
};

pub const ControlResponseCode = enum(i32) {
    ok = 0,
    err = 1,
    recording_unknown = 2,
};

// ============================================================================
// Control Requests (client -> archive)
// ============================================================================

/// StartRecordingRequest — initiate recording on a channel
// LESSON(archive/aeron): StartRecordingRequest tells the archive conductor to create a new recording session.
pub const StartRecordingRequest = extern struct {
    correlation_id: i64,
    stream_id: i32,
    source_location: i32,
    channel_length: i32,
    // Variable-length channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(StartRecordingRequest);
    pub const MSG_TYPE_ID: i32 = 1;
};

/// StopRecordingRequest — stop recording on a channel
pub const StopRecordingRequest = extern struct {
    correlation_id: i64,
    stream_id: i32,
    channel_length: i32,
    // Variable-length channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(StopRecordingRequest);
    pub const MSG_TYPE_ID: i32 = 2;
};

/// ReplayRequest — initiate replay of a recording
// LESSON(archive/aeron): ReplayRequest allows a client to request a range of data from a saved recording.
pub const ReplayRequest = extern struct {
    correlation_id: i64,
    recording_id: i64,
    position: i64,
    length: i64,
    replay_stream_id: i32,
    replay_channel_length: i32,
    // Variable-length replay_channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(ReplayRequest);
    pub const MSG_TYPE_ID: i32 = 3;
};

/// StopReplayRequest — stop an active replay
pub const StopReplayRequest = extern struct {
    correlation_id: i64,
    replay_session_id: i64,

    pub const HEADER_LENGTH = @sizeOf(StopReplayRequest);
    pub const MSG_TYPE_ID: i32 = 4;
};

/// ListRecordingsRequest — list recordings
pub const ListRecordingsRequest = extern struct {
    correlation_id: i64,
    from_recording_id: i64,
    record_count: i32,

    pub const HEADER_LENGTH = @sizeOf(ListRecordingsRequest);
    pub const MSG_TYPE_ID: i32 = 5;
};

/// ExtendRecordingRequest — extend an existing recording
pub const ExtendRecordingRequest = extern struct {
    correlation_id: i64,
    recording_id: i64,
    stream_id: i32,
    source_location: i32,
    channel_length: i32,
    // Variable-length channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(ExtendRecordingRequest);
    pub const MSG_TYPE_ID: i32 = 6;
};

// ============================================================================
// Control Responses (archive -> client)
// ============================================================================

/// ControlResponse — generic response with status code
pub const ControlResponse = extern struct {
    correlation_id: i64,
    code: i32,
    error_message_length: i32,
    // Variable-length error_message follows in the buffer (if error_message_length > 0)

    pub const HEADER_LENGTH = @sizeOf(ControlResponse);
    pub const MSG_TYPE_ID: i32 = 101;
};

/// RecordingStarted — notification that recording has started
pub const RecordingStarted = extern struct {
    correlation_id: i64,
    recording_id: i64,

    pub const HEADER_LENGTH = @sizeOf(RecordingStarted);
    pub const MSG_TYPE_ID: i32 = 102;
};

/// RecordingProgress — current state of an active recording
pub const RecordingProgress = extern struct {
    recording_id: i64,
    start_position: i64,
    stop_position: i64,

    pub const HEADER_LENGTH = @sizeOf(RecordingProgress);
    pub const MSG_TYPE_ID: i32 = 103;
};

/// RecordingDescriptor — metadata for a recorded session
// LESSON(archive/aeron): RecordingDescriptor contains all metadata needed to replay a stream, including term_length and MTU.
pub const RecordingDescriptor = extern struct {
    recording_id: i64,
    start_timestamp: i64,
    stop_timestamp: i64,
    start_position: i64,
    stop_position: i64,
    initial_term_id: i32,
    segment_file_length: i32,
    term_buffer_length: i32,
    mtu_length: i32,
    session_id: i32,
    stream_id: i32,
    channel_length: i32,
    // Variable-length channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(RecordingDescriptor);
    pub const MSG_TYPE_ID: i32 = 104;
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Encode a length-prefixed channel string into buffer.
/// Returns number of bytes written (length prefix + string data).
// LESSON(archive/zig): Zig's @memcpy and @intCast make encoding variable-length SBE-style strings efficient and safe.
pub fn encodeChannel(buf: []u8, channel: []const u8) !usize {
    if (buf.len < 4 + channel.len) {
        return error.BufferTooSmall;
    }
    // Write length as i32 (little-endian)
    const channel_len: i32 = @intCast(channel.len);
    std.mem.writeInt(i32, buf[0..4], channel_len, .little);
    // Write channel string
    @memcpy(buf[4 .. 4 + channel.len], channel);
    return 4 + channel.len;
}

/// Decode a length-prefixed channel string from buffer.
/// Returns a slice into the buffer if valid, null if buffer too small.
pub fn decodeChannel(buf: []const u8) ?[]const u8 {
    if (buf.len < 4) {
        return null;
    }
    const channel_len = std.mem.readInt(i32, buf[0..4], .little);
    if (channel_len < 0 or buf.len < 4 + channel_len) {
        return null;
    }
    return buf[4 .. 4 + @as(usize, @intCast(channel_len))];
}

// ============================================================================
// Compile-time Assertions
// ============================================================================

comptime {
    // Verify MSG_TYPE_IDs are unique
    std.debug.assert(StartRecordingRequest.MSG_TYPE_ID != StopRecordingRequest.MSG_TYPE_ID);
    std.debug.assert(ReplayRequest.MSG_TYPE_ID != StopReplayRequest.MSG_TYPE_ID);
    std.debug.assert(ListRecordingsRequest.MSG_TYPE_ID != ExtendRecordingRequest.MSG_TYPE_ID);
    std.debug.assert(ControlResponse.MSG_TYPE_ID != RecordingStarted.MSG_TYPE_ID);
    std.debug.assert(RecordingProgress.MSG_TYPE_ID != RecordingDescriptor.MSG_TYPE_ID);

    // Verify ControlResponseCode values
    std.debug.assert(@intFromEnum(ControlResponseCode.ok) == 0);
    std.debug.assert(@intFromEnum(ControlResponseCode.err) == 1);
    std.debug.assert(@intFromEnum(ControlResponseCode.recording_unknown) == 2);
}

// ============================================================================
// Tests
// ============================================================================

test "header sizes are correct" {
    try std.testing.expectEqual(@as(usize, 24), StartRecordingRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), StopRecordingRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 40), ReplayRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), StopReplayRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 24), ListRecordingsRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 32), ExtendRecordingRequest.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), ControlResponse.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), RecordingStarted.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 24), RecordingProgress.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 72), RecordingDescriptor.HEADER_LENGTH);
}

test "msg_type_ids are unique" {
    try std.testing.expectEqual(1, StartRecordingRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(2, StopRecordingRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(3, ReplayRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(4, StopReplayRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(5, ListRecordingsRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(6, ExtendRecordingRequest.MSG_TYPE_ID);
    try std.testing.expectEqual(101, ControlResponse.MSG_TYPE_ID);
    try std.testing.expectEqual(102, RecordingStarted.MSG_TYPE_ID);
    try std.testing.expectEqual(103, RecordingProgress.MSG_TYPE_ID);
    try std.testing.expectEqual(104, RecordingDescriptor.MSG_TYPE_ID);
}

test "control response codes" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ControlResponseCode.ok));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ControlResponseCode.err));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(ControlResponseCode.recording_unknown));
}

test "encodeChannel round-trip" {
    var buf: [256]u8 = undefined;
    const channel = "aeron:udp://localhost:40123";

    const written = try encodeChannel(&buf, channel);
    try std.testing.expectEqual(4 + channel.len, written);

    const decoded = decodeChannel(buf[0..written]);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqualSlices(u8, channel, decoded.?);
}

test "decodeChannel with empty channel" {
    var buf: [4]u8 = undefined;
    const written = try encodeChannel(&buf, "");
    try std.testing.expectEqual(4, written);

    const decoded = decodeChannel(buf[0..written]);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(0, decoded.?.len);
}

test "decodeChannel with invalid buffer" {
    try std.testing.expect(decodeChannel("abc") == null);
}

test "encodeChannel with buffer too small" {
    var buf: [4]u8 = undefined;
    const channel = "aeron:udp://localhost:40123";
    try std.testing.expectError(error.BufferTooSmall, encodeChannel(&buf, channel));
}

test "source location enum values" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(SourceLocation.local));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(SourceLocation.remote));
}
