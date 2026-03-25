// Aeron wire protocol frame definitions
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/c/protocol/aeron_udp_protocol.h
const std = @import("std");

pub const VERSION: u8 = 0x00;
pub const FRAME_ALIGNMENT: usize = 32;

pub const FrameType = enum(u16) {
    padding = 0x00,
    data = 0x01,
    nak = 0x02,
    status = 0x03,
    setup = 0x05,
    rtt_measurement = 0x06,
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
    // at non-8-aligned offsets need align(4) in Zig to match the wire layout. See docs/tutorial/01-foundations/01-frame-codec.md
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
    // LESSON(frame-codec): receiver_id was present from the start in C header. See docs/tutorial/01-foundations/01-frame-codec.md
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

/// Error returned when a raw buffer cannot be decoded as a valid Aeron frame.
pub const DecodeError = error{
    /// Buffer is shorter than the minimum required for this frame type.
    BufferTooShort,
    /// frame_length field is zero, negative, or exceeds the buffer.
    InvalidFrameLength,
    /// version field does not equal VERSION (0x00).
    InvalidVersion,
    /// type field does not map to a known FrameType variant.
    UnknownFrameType,
};

/// A decoded Aeron frame — one variant per supported frame type.
/// Pointer variants point into the original buffer; caller must keep `buf` alive.
/// The `.data` variant includes a `payload` slice for the body bytes beyond the header.
pub const DecodedFrame = union(FrameType) {
    padding: void,
    data: struct {
        header: *const DataHeader,
        payload: []const u8,
    },
    nak: *const NakHeader,
    status: *const StatusMessage,
    setup: *const SetupHeader,
    rtt_measurement: *const RttMeasurement,
    resolution_entry: *const ResolutionEntry,
};

/// Decode the first Aeron frame from `buf`.
///
/// Validates:
/// - buffer has at least FrameHeader.LENGTH (8) bytes
/// - frame_length > 0 and fits within buf
/// - version == VERSION (0x00)
/// - type maps to a known FrameType
/// - per-type minimum size
///
/// Never panics on untrusted input. Returns DecodeError for any malformed data.
/// Assumes `buf` is at least 8-byte aligned (standard for UDP receive buffers).
pub fn decode(buf: []const u8) DecodeError!DecodedFrame {
    if (buf.len < FrameHeader.LENGTH) return DecodeError.BufferTooShort;

    const hdr = @as(*const FrameHeader, @ptrCast(@alignCast(buf.ptr)));
    const frame_len = hdr.frame_length;
    if (frame_len <= 0) return DecodeError.InvalidFrameLength;
    if (@as(usize, @intCast(frame_len)) > buf.len) return DecodeError.InvalidFrameLength;
    if (hdr.version != VERSION) return DecodeError.InvalidVersion;

    const frame_type = std.meta.intToEnum(FrameType, hdr.type) catch
        return DecodeError.UnknownFrameType;

    switch (frame_type) {
        .padding => return .{ .padding = {} },
        .data => {
            if (@as(usize, @intCast(frame_len)) < DataHeader.LENGTH) return DecodeError.BufferTooShort;
            const data_hdr = @as(*const DataHeader, @ptrCast(@alignCast(buf.ptr)));
            const payload = buf[DataHeader.LENGTH..@as(usize, @intCast(frame_len))];
            return .{ .data = .{ .header = data_hdr, .payload = payload } };
        },
        .nak => {
            if (@as(usize, @intCast(frame_len)) < NakHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .nak = @as(*const NakHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .status => {
            if (@as(usize, @intCast(frame_len)) < StatusMessage.LENGTH) return DecodeError.BufferTooShort;
            return .{ .status = @as(*const StatusMessage, @ptrCast(@alignCast(buf.ptr))) };
        },
        .setup => {
            if (@as(usize, @intCast(frame_len)) < SetupHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .setup = @as(*const SetupHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .rtt_measurement => {
            if (@as(usize, @intCast(frame_len)) < RttMeasurement.LENGTH) return DecodeError.BufferTooShort;
            return .{ .rtt_measurement = @as(*const RttMeasurement, @ptrCast(@alignCast(buf.ptr))) };
        },
        .resolution_entry => {
            if (@as(usize, @intCast(frame_len)) < ResolutionEntry.HEADER_LENGTH) return DecodeError.BufferTooShort;
            return .{ .resolution_entry = @as(*const ResolutionEntry, @ptrCast(@alignCast(buf.ptr))) };
        },
    }
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

test "decode: rejects buffer shorter than FrameHeader" {
    const buf = [_]u8{0} ** 4;
    try std.testing.expectError(DecodeError.BufferTooShort, decode(&buf));
}

test "decode: rejects zero frame_length" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 0, .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.InvalidFrameLength, decode(&buf));
}

test "decode: rejects negative frame_length" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], -1, .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.InvalidFrameLength, decode(&buf));
}

test "decode: rejects frame_length beyond buffer" {
    var buf align(8) = [_]u8{0} ** 32;
    std.mem.writeInt(i32, buf[0..4], 64, .little); // claims 64 bytes but buf is 32
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.InvalidFrameLength, decode(&buf));
}

test "decode: rejects wrong version" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 32, .little);
    buf[4] = 0xFF; // bad version
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.InvalidVersion, decode(&buf));
}

test "decode: rejects unknown frame type" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 32, .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], 0xFF, .little); // unknown type
    try std.testing.expectError(DecodeError.UnknownFrameType, decode(&buf));
}

test "decode: decodes DATA frame" {
    var buf align(8) = [_]u8{0} ** 64;
    const payload_str = "hello";
    const total_len = DataHeader.LENGTH + payload_str.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = VERSION;
    buf[5] = DataHeader.BEGIN_FLAG | DataHeader.END_FLAG;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    std.mem.writeInt(i32, buf[8..12], 0, .little); // term_offset
    std.mem.writeInt(i32, buf[12..16], 42, .little); // session_id
    std.mem.writeInt(i32, buf[16..20], 1, .little); // stream_id
    std.mem.writeInt(i32, buf[20..24], 0, .little); // term_id
    @memcpy(buf[DataHeader.LENGTH..][0..payload_str.len], payload_str);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.data, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 42), frame.data.header.session_id);
    try std.testing.expectEqualSlices(u8, payload_str, frame.data.payload);
}

test "decode: decodes SETUP frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, SetupHeader.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.setup), .little);
    // SetupHeader layout: frame_length(4) version(1) flags(1) type(2) term_offset(4)
    //   session_id(4) stream_id(4) initial_term_id(4) ... => initial_term_id at offset 20
    std.mem.writeInt(i32, buf[20..24], 7, .little); // initial_term_id

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 7), frame.setup.initial_term_id);
}

test "decode: decodes STATUS frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, StatusMessage.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.status), .little);
    std.mem.writeInt(i32, buf[8..12], 99, .little); // session_id

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.status, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 99), frame.status.session_id);
}

test "decode: decodes NAK frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, NakHeader.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.nak), .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.nak, std.meta.activeTag(frame));
}

test "decode: decodes RTT frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, RttMeasurement.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.rtt_measurement), .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.rtt_measurement, std.meta.activeTag(frame));
}

test "decode: rejects truncated DATA frame (frame_length < DataHeader.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 16, .little); // too short for DataHeader (32 bytes)
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.BufferTooShort, decode(&buf));
}
