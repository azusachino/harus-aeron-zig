// Aeron wire protocol frame definitions
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/c/protocol/aeron_udp_protocol.h
const std = @import("std");

pub const VERSION: u8 = 0x00;
pub const FRAME_ALIGNMENT: usize = 32;

pub const FrameType = enum(u16) {
    padding = 0x00,
    data = 0x01,
    setup = 0x03,
    status = 0x04,
    nak = 0x05,
    rtt_measurement = 0x0B,
    resolution_entry = 0x0E,
};

/// Base frame header — 8 bytes, present in every frame
pub const FrameHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,

    pub const LENGTH = @sizeOf(FrameHeader);
};

/// Data frame header — 32 bytes total
pub const DataHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    term_offset: i32,
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    reserved_value: i64,

    pub const LENGTH = @sizeOf(DataHeader);
    pub const BEGIN_FLAG: u8 = 0x80;
    pub const END_FLAG: u8 = 0x40;
    pub const EOS_FLAG: u8 = 0x20;
    pub const PADDING_FLAG: u8 = 0x20; // reused in padding frame
};

/// Setup frame — 40 bytes total
pub const SetupHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    term_offset: i32,
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    active_term_id: i32,
    term_length: i32,
    mtu: i32,
    ttl: i32,

    pub const LENGTH = @sizeOf(SetupHeader);
};

/// Status message (SM) frame — 36 bytes total
pub const StatusMessage = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    session_id: i32,
    stream_id: i32,
    consumption_term_id: i32,
    consumption_term_offset: i32,
    receiver_window: i32,
    // LESSON(frame-codec): Aeron's C header uses #pragma pack(4), so i64 fields
    // at non-8-aligned offsets need align(4) in Zig to match the wire layout.
    receiver_id: i64 align(4),

    pub const LENGTH = @sizeOf(StatusMessage);
};

/// NAK frame — 28 bytes total
pub const NakHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    term_offset: i32,
    length: i32,

    pub const LENGTH = @sizeOf(NakHeader);
};

/// RTT Measurement frame — 32 bytes total
pub const RttMeasurement = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    echo_timestamp: i64 align(4),
    reception_delta: i64 align(4),
    // LESSON(frame-codec/aeron): receiver_id was present from the start in C header
    // (aeron_udp_protocol.h). Total frame size = 32 bytes.
    receiver_id: i64 align(4),

    pub const LENGTH = @sizeOf(RttMeasurement);
};

/// Resolution Entry — variable length, header portion only
pub const ResolutionEntry = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    res_type: u8,
    address_length: u8,
    port: u16,
    age_in_ms: i32,

    pub const HEADER_LENGTH = 16;
};

/// Returns (data_length + DataHeader.LENGTH) rounded up to FRAME_ALIGNMENT (32).
pub fn alignedLength(data_length: usize) usize {
    return (data_length + DataHeader.LENGTH + (FRAME_ALIGNMENT - 1)) & ~(FRAME_ALIGNMENT - 1);
}

/// Returns the maximum payload bytes that fit in a single DATA frame given mtu.
pub fn computeMaxPayload(mtu: usize) usize {
    return mtu - DataHeader.LENGTH;
}

pub fn isBeginFragment(flags: u8) bool {
    return (flags & DataHeader.BEGIN_FLAG) != 0;
}

pub fn isEndFragment(flags: u8) bool {
    return (flags & DataHeader.END_FLAG) != 0;
}

comptime {
    std.debug.assert(@sizeOf(DataHeader) == 32);
    std.debug.assert(@sizeOf(SetupHeader) == 40);
    std.debug.assert(@sizeOf(StatusMessage) == 36);
    std.debug.assert(@sizeOf(NakHeader) == 28);
    std.debug.assert(@sizeOf(RttMeasurement) == 32);
}

test "RttMeasurement is exactly 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RttMeasurement));
}

test "frame sizes match spec" {
    try std.testing.expectEqual(32, DataHeader.LENGTH);
    try std.testing.expectEqual(40, SetupHeader.LENGTH);
    try std.testing.expectEqual(36, StatusMessage.LENGTH);
    try std.testing.expectEqual(28, NakHeader.LENGTH);
    try std.testing.expectEqual(32, RttMeasurement.LENGTH);
}

test "alignedLength calculation" {
    try std.testing.expectEqual(@as(usize, 32), alignedLength(0));
    try std.testing.expectEqual(@as(usize, 64), alignedLength(1));
    try std.testing.expectEqual(@as(usize, 64), alignedLength(32));
    try std.testing.expectEqual(@as(usize, 96), alignedLength(33));
}

test "computeMaxPayload calculation" {
    try std.testing.expectEqual(@as(usize, 1376), computeMaxPayload(1408));
}

test "isBeginFragment correctly identifies flag" {
    try std.testing.expect(isBeginFragment(DataHeader.BEGIN_FLAG));
    try std.testing.expect(!isBeginFragment(DataHeader.END_FLAG));
    try std.testing.expect(isBeginFragment(DataHeader.BEGIN_FLAG | DataHeader.END_FLAG));
}

test "isEndFragment correctly identifies flag" {
    try std.testing.expect(isEndFragment(DataHeader.END_FLAG));
    try std.testing.expect(!isEndFragment(DataHeader.BEGIN_FLAG));
    try std.testing.expect(isEndFragment(DataHeader.BEGIN_FLAG | DataHeader.END_FLAG));
}
