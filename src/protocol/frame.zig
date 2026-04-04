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
    err = 0x04,
    setup = 0x05,
    rtt_measurement = 0x06,
    resolution_entry = 0x07,
    ats_data = 0x08,
    ats_setup = 0x09,
    ats_status = 0x0A,
    response_setup = 0x0B,
    ext = 0xFFFF,
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

/// Error frame fixed header — 40 bytes total before variable error string bytes
pub const ErrorHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    session_id: i32,
    stream_id: i32,
    receiver_id: i64 align(4),
    group_tag: i64 align(4),
    error_code: i32,
    error_message_length: i32,

    pub const LENGTH = @sizeOf(ErrorHeader);
    pub const HAS_GROUP_ID_FLAG: u8 = 0x08;
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
    session_id: i32,
    stream_id: i32,
    echo_timestamp: i64 align(4),
    reception_delta: i64 align(4),
    // LESSON(frame-codec): receiver_id was present from the start in C header. See docs/tutorial/01-foundations/01-frame-codec.md
    // (aeron_udp_protocol.h). Total frame size = 40 bytes including session_id and stream_id.
    receiver_id: i64 align(4),

    pub const LENGTH = @sizeOf(RttMeasurement);
    pub const REPLY_FLAG: u8 = 0x80;
};

/// Response setup frame — 20 bytes total
pub const ResponseSetupHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    session_id: i32,
    stream_id: i32,
    response_session_id: i32,

    pub const LENGTH = @sizeOf(ResponseSetupHeader);
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

/// Extension frame header — 12 bytes total
pub const ExtensionHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    header_length: u16,
    extension_type: u16,

    pub const LENGTH = @sizeOf(ExtensionHeader);
    pub const IGNORE_FLAG: u16 = 0x8000;

    pub fn length(self: *const ExtensionHeader) u16 {
        return self.header_length & ~IGNORE_FLAG;
    }

    pub fn isIgnorable(self: *const ExtensionHeader) bool {
        return (self.header_length & IGNORE_FLAG) != 0;
    }
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
    err: struct {
        header: *const ErrorHeader,
        error_message: []const u8,
    },
    setup: *const SetupHeader,
    rtt_measurement: *const RttMeasurement,
    resolution_entry: *const ResolutionEntry,
    ats_data: struct {
        header: *const DataHeader,
        payload: []const u8,
    },
    ats_setup: *const SetupHeader,
    ats_status: *const StatusMessage,
    response_setup: *const ResponseSetupHeader,
    ext: struct {
        header: *const ExtensionHeader,
        payload: []const u8,
    },
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
        .ats_data => {
            if (@as(usize, @intCast(frame_len)) < DataHeader.LENGTH) return DecodeError.BufferTooShort;
            const data_hdr = @as(*const DataHeader, @ptrCast(@alignCast(buf.ptr)));
            const payload = buf[DataHeader.LENGTH..@as(usize, @intCast(frame_len))];
            return .{ .ats_data = .{ .header = data_hdr, .payload = payload } };
        },
        .nak => {
            if (@as(usize, @intCast(frame_len)) < NakHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .nak = @as(*const NakHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .status => {
            if (@as(usize, @intCast(frame_len)) < StatusMessage.LENGTH) return DecodeError.BufferTooShort;
            return .{ .status = @as(*const StatusMessage, @ptrCast(@alignCast(buf.ptr))) };
        },
        .ats_status => {
            if (@as(usize, @intCast(frame_len)) < StatusMessage.LENGTH) return DecodeError.BufferTooShort;
            return .{ .ats_status = @as(*const StatusMessage, @ptrCast(@alignCast(buf.ptr))) };
        },
        .err => {
            if (@as(usize, @intCast(frame_len)) < ErrorHeader.LENGTH) return DecodeError.BufferTooShort;
            const err_hdr = @as(*const ErrorHeader, @ptrCast(@alignCast(buf.ptr)));
            const message_end = ErrorHeader.LENGTH + @as(usize, @intCast(err_hdr.error_message_length));
            if (message_end > @as(usize, @intCast(frame_len))) return DecodeError.BufferTooShort;
            return .{
                .err = .{
                    .header = err_hdr,
                    .error_message = buf[ErrorHeader.LENGTH..message_end],
                },
            };
        },
        .setup => {
            if (@as(usize, @intCast(frame_len)) < SetupHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .setup = @as(*const SetupHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .ats_setup => {
            if (@as(usize, @intCast(frame_len)) < SetupHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .ats_setup = @as(*const SetupHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .rtt_measurement => {
            if (@as(usize, @intCast(frame_len)) < RttMeasurement.LENGTH) return DecodeError.BufferTooShort;
            return .{ .rtt_measurement = @as(*const RttMeasurement, @ptrCast(@alignCast(buf.ptr))) };
        },
        .resolution_entry => {
            if (@as(usize, @intCast(frame_len)) < ResolutionEntry.HEADER_LENGTH) return DecodeError.BufferTooShort;
            return .{ .resolution_entry = @as(*const ResolutionEntry, @ptrCast(@alignCast(buf.ptr))) };
        },
        .response_setup => {
            if (@as(usize, @intCast(frame_len)) < ResponseSetupHeader.LENGTH) return DecodeError.BufferTooShort;
            return .{ .response_setup = @as(*const ResponseSetupHeader, @ptrCast(@alignCast(buf.ptr))) };
        },
        .ext => {
            if (@as(usize, @intCast(frame_len)) < ExtensionHeader.LENGTH) return DecodeError.BufferTooShort;
            const ext_hdr = @as(*const ExtensionHeader, @ptrCast(@alignCast(buf.ptr)));
            const payload = buf[ExtensionHeader.LENGTH..@as(usize, @intCast(frame_len))];
            return .{ .ext = .{ .header = ext_hdr, .payload = payload } };
        },
    }
}

comptime {
    std.debug.assert(@sizeOf(DataHeader) == 32);
    std.debug.assert(@sizeOf(SetupHeader) == 40);
    std.debug.assert(@sizeOf(StatusMessage) == 36);
    std.debug.assert(@sizeOf(ErrorHeader) == 40);
    std.debug.assert(@sizeOf(NakHeader) == 28);
    std.debug.assert(@sizeOf(RttMeasurement) == 40);
    std.debug.assert(@sizeOf(ResponseSetupHeader) == 20);
    std.debug.assert(@offsetOf(DataHeader, "reserved_value") == 24);
    std.debug.assert(@offsetOf(StatusMessage, "receiver_id") == 28);
    std.debug.assert(@offsetOf(ErrorHeader, "receiver_id") == 16);
    std.debug.assert(@offsetOf(ErrorHeader, "group_tag") == 24);
    std.debug.assert(@offsetOf(ErrorHeader, "error_code") == 32);
    std.debug.assert(@offsetOf(ErrorHeader, "error_message_length") == 36);
    std.debug.assert(@offsetOf(RttMeasurement, "session_id") == 8);
    std.debug.assert(@offsetOf(RttMeasurement, "stream_id") == 12);
    std.debug.assert(@offsetOf(RttMeasurement, "echo_timestamp") == 16);
    std.debug.assert(@offsetOf(RttMeasurement, "reception_delta") == 24);
    std.debug.assert(@offsetOf(RttMeasurement, "receiver_id") == 32);
    std.debug.assert(@offsetOf(ResponseSetupHeader, "session_id") == 8);
    std.debug.assert(@offsetOf(ResponseSetupHeader, "stream_id") == 12);
    std.debug.assert(@offsetOf(ResponseSetupHeader, "response_session_id") == 16);
}

test "RttMeasurement is exactly 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RttMeasurement));
}

test "frame type numeric values match aeron udp protocol" {
    try std.testing.expectEqual(@as(u16, 0x00), @intFromEnum(FrameType.padding));
    try std.testing.expectEqual(@as(u16, 0x01), @intFromEnum(FrameType.data));
    try std.testing.expectEqual(@as(u16, 0x02), @intFromEnum(FrameType.nak));
    try std.testing.expectEqual(@as(u16, 0x03), @intFromEnum(FrameType.status));
    try std.testing.expectEqual(@as(u16, 0x04), @intFromEnum(FrameType.err));
    try std.testing.expectEqual(@as(u16, 0x05), @intFromEnum(FrameType.setup));
    try std.testing.expectEqual(@as(u16, 0x06), @intFromEnum(FrameType.rtt_measurement));
    try std.testing.expectEqual(@as(u16, 0x07), @intFromEnum(FrameType.resolution_entry));
    try std.testing.expectEqual(@as(u16, 0x08), @intFromEnum(FrameType.ats_data));
    try std.testing.expectEqual(@as(u16, 0x09), @intFromEnum(FrameType.ats_setup));
    try std.testing.expectEqual(@as(u16, 0x0A), @intFromEnum(FrameType.ats_status));
    try std.testing.expectEqual(@as(u16, 0x0B), @intFromEnum(FrameType.response_setup));
    try std.testing.expectEqual(@as(u16, 0xFFFF), @intFromEnum(FrameType.ext));
}

test "wire field offsets match aeron udp protocol" {
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(DataHeader, "reserved_value"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(StatusMessage, "receiver_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ErrorHeader, "receiver_id"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ErrorHeader, "group_tag"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ErrorHeader, "error_code"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(ErrorHeader, "error_message_length"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(NakHeader, "session_id"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(NakHeader, "stream_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(NakHeader, "term_id"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(NakHeader, "term_offset"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(NakHeader, "length"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RttMeasurement, "session_id"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(RttMeasurement, "stream_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RttMeasurement, "echo_timestamp"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RttMeasurement, "reception_delta"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(RttMeasurement, "receiver_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ResponseSetupHeader, "session_id"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(ResponseSetupHeader, "stream_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ResponseSetupHeader, "response_session_id"));
}

test "frame sizes match spec" {
    try std.testing.expectEqual(32, DataHeader.LENGTH);
    try std.testing.expectEqual(40, SetupHeader.LENGTH);
    try std.testing.expectEqual(36, StatusMessage.LENGTH);
    try std.testing.expectEqual(40, ErrorHeader.LENGTH);
    try std.testing.expectEqual(28, NakHeader.LENGTH);
    try std.testing.expectEqual(40, RttMeasurement.LENGTH);
    try std.testing.expectEqual(20, ResponseSetupHeader.LENGTH);
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

test "decode: decodes EXT frame with payload" {
    var buf align(8) = [_]u8{0} ** 64;
    const payload_str = "secret";
    const total_len = ExtensionHeader.LENGTH + payload_str.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.ext), .little);
    std.mem.writeInt(u16, buf[8..10], @as(u16, @intCast(payload_str.len)) | ExtensionHeader.IGNORE_FLAG, .little);
    std.mem.writeInt(u16, buf[10..12], 0x1234, .little); // extension_type
    @memcpy(buf[ExtensionHeader.LENGTH..][0..payload_str.len], payload_str);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.ext, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(u16, 0x1234), frame.ext.header.extension_type);
    try std.testing.expectEqual(@as(u16, payload_str.len), frame.ext.header.length());
    try std.testing.expect(frame.ext.header.isIgnorable());
    try std.testing.expectEqualSlices(u8, payload_str, frame.ext.payload);
}

test "decode: decodes ATS_DATA frame using data layout" {
    var buf align(8) = [_]u8{0} ** 64;
    const payload_str = "ats";
    const total_len = DataHeader.LENGTH + payload_str.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = VERSION;
    buf[5] = DataHeader.BEGIN_FLAG;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.ats_data), .little);
    std.mem.writeInt(i32, buf[8..12], 64, .little);
    std.mem.writeInt(i32, buf[12..16], 1, .little);
    std.mem.writeInt(i32, buf[16..20], 2, .little);
    std.mem.writeInt(i32, buf[20..24], 3, .little);
    @memcpy(buf[DataHeader.LENGTH..][0..payload_str.len], payload_str);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.ats_data, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 1), frame.ats_data.header.session_id);
    try std.testing.expectEqualSlices(u8, payload_str, frame.ats_data.payload);
}

test "decode: decodes SETUP frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, SetupHeader.LENGTH), .little);
    buf[4] = VERSION;
    buf[5] = 0xC0;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.setup), .little);
    std.mem.writeInt(i32, buf[8..12], 4096, .little);
    std.mem.writeInt(i32, buf[12..16], 11, .little);
    std.mem.writeInt(i32, buf[16..20], 22, .little);
    std.mem.writeInt(i32, buf[20..24], 33, .little);
    std.mem.writeInt(i32, buf[24..28], 44, .little);
    std.mem.writeInt(i32, buf[28..32], 64 * 1024, .little);
    std.mem.writeInt(i32, buf[32..36], 1408, .little);
    std.mem.writeInt(i32, buf[36..40], 3, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(u8, 0xC0), frame.setup.flags);
    try std.testing.expectEqual(@as(i32, 4096), frame.setup.term_offset);
    try std.testing.expectEqual(@as(i32, 11), frame.setup.session_id);
    try std.testing.expectEqual(@as(i32, 22), frame.setup.stream_id);
    try std.testing.expectEqual(@as(i32, 33), frame.setup.initial_term_id);
    try std.testing.expectEqual(@as(i32, 44), frame.setup.active_term_id);
    try std.testing.expectEqual(@as(i32, 64 * 1024), frame.setup.term_length);
    try std.testing.expectEqual(@as(i32, 1408), frame.setup.mtu);
    try std.testing.expectEqual(@as(i32, 3), frame.setup.ttl);
}

test "decode: decodes ATS_SETUP frame using setup layout" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, SetupHeader.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.ats_setup), .little);
    std.mem.writeInt(i32, buf[8..12], 11, .little);
    std.mem.writeInt(i32, buf[12..16], 22, .little);
    std.mem.writeInt(i32, buf[16..20], 33, .little);
    std.mem.writeInt(i32, buf[20..24], 44, .little);
    std.mem.writeInt(i32, buf[24..28], 55, .little);
    std.mem.writeInt(i32, buf[28..32], 65536, .little);
    std.mem.writeInt(i32, buf[32..36], 1408, .little);
    std.mem.writeInt(i32, buf[36..40], 1, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.ats_setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 22), frame.ats_setup.session_id);
    try std.testing.expectEqual(@as(i32, 55), frame.ats_setup.active_term_id);
}

test "decode: decodes STATUS frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, StatusMessage.LENGTH), .little);
    buf[4] = VERSION;
    buf[5] = 0x80;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.status), .little);
    std.mem.writeInt(i32, buf[8..12], 99, .little);
    std.mem.writeInt(i32, buf[12..16], 7, .little);
    std.mem.writeInt(i32, buf[16..20], 12, .little);
    std.mem.writeInt(i32, buf[20..24], 2048, .little);
    std.mem.writeInt(i32, buf[24..28], 65536, .little);
    std.mem.writeInt(i64, buf[28..36], 0x0102_0304_0506_0708, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.status, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 99), frame.status.session_id);
    try std.testing.expectEqual(@as(i32, 7), frame.status.stream_id);
    try std.testing.expectEqual(@as(i32, 12), frame.status.consumption_term_id);
    try std.testing.expectEqual(@as(i32, 2048), frame.status.consumption_term_offset);
    try std.testing.expectEqual(@as(i32, 65536), frame.status.receiver_window);
    try std.testing.expectEqual(@as(i64, 0x0102_0304_0506_0708), frame.status.receiver_id);
}

test "decode: decodes ATS_SM frame using status layout" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, StatusMessage.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.ats_status), .little);
    std.mem.writeInt(i32, buf[8..12], 101, .little);
    std.mem.writeInt(i32, buf[12..16], 202, .little);
    std.mem.writeInt(i32, buf[16..20], 303, .little);
    std.mem.writeInt(i32, buf[20..24], 404, .little);
    std.mem.writeInt(i32, buf[24..28], 505, .little);
    std.mem.writeInt(i64, buf[28..36], 606, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.ats_status, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 101), frame.ats_status.session_id);
    try std.testing.expectEqual(@as(i64, 606), frame.ats_status.receiver_id);
}

test "decode: decodes ERR frame with message" {
    var buf align(8) = [_]u8{0} ** 128;
    const msg = "channel failure";
    const total_len = ErrorHeader.LENGTH + msg.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = VERSION;
    buf[5] = ErrorHeader.HAS_GROUP_ID_FLAG;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.err), .little);
    std.mem.writeInt(i32, buf[8..12], 10, .little);
    std.mem.writeInt(i32, buf[12..16], 20, .little);
    std.mem.writeInt(i64, buf[16..24], 30, .little);
    std.mem.writeInt(i64, buf[24..32], 40, .little);
    std.mem.writeInt(i32, buf[32..36], 50, .little);
    std.mem.writeInt(i32, buf[36..40], @as(i32, @intCast(msg.len)), .little);
    @memcpy(buf[ErrorHeader.LENGTH..][0..msg.len], msg);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.err, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 10), frame.err.header.session_id);
    try std.testing.expectEqual(@as(i32, 20), frame.err.header.stream_id);
    try std.testing.expectEqual(@as(i64, 30), frame.err.header.receiver_id);
    try std.testing.expectEqual(@as(i64, 40), frame.err.header.group_tag);
    try std.testing.expectEqual(@as(i32, 50), frame.err.header.error_code);
    try std.testing.expectEqual(@as(i32, @intCast(msg.len)), frame.err.header.error_message_length);
    try std.testing.expectEqualSlices(u8, msg, frame.err.error_message);
}

test "decode: decodes NAK frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, NakHeader.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.nak), .little);
    std.mem.writeInt(i32, buf[8..12], 17, .little);
    std.mem.writeInt(i32, buf[12..16], 27, .little);
    std.mem.writeInt(i32, buf[16..20], 37, .little);
    std.mem.writeInt(i32, buf[20..24], 4096, .little);
    std.mem.writeInt(i32, buf[24..28], 512, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.nak, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 17), frame.nak.session_id);
    try std.testing.expectEqual(@as(i32, 27), frame.nak.stream_id);
    try std.testing.expectEqual(@as(i32, 37), frame.nak.term_id);
    try std.testing.expectEqual(@as(i32, 4096), frame.nak.term_offset);
    try std.testing.expectEqual(@as(i32, 512), frame.nak.length);
}

test "decode: decodes RTT frame" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], @as(i32, RttMeasurement.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.rtt_measurement), .little);
    std.mem.writeInt(i32, buf[8..12], 17, .little);
    std.mem.writeInt(i32, buf[12..16], 27, .little);
    std.mem.writeInt(i64, buf[16..24], 111, .little);
    std.mem.writeInt(i64, buf[24..32], 222, .little);
    std.mem.writeInt(i64, buf[32..40], 333, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.rtt_measurement, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 17), frame.rtt_measurement.session_id);
    try std.testing.expectEqual(@as(i32, 27), frame.rtt_measurement.stream_id);
    try std.testing.expectEqual(@as(i64, 111), frame.rtt_measurement.echo_timestamp);
    try std.testing.expectEqual(@as(i64, 222), frame.rtt_measurement.reception_delta);
    try std.testing.expectEqual(@as(i64, 333), frame.rtt_measurement.receiver_id);
}

test "decode: decodes resolution entry header" {
    var buf align(8) = [_]u8{0} ** 32;
    std.mem.writeInt(i32, buf[0..4], @as(i32, ResolutionEntry.HEADER_LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.resolution_entry), .little);
    buf[8] = 1;
    buf[9] = 16;
    std.mem.writeInt(u16, buf[10..12], 40123, .little);
    std.mem.writeInt(i32, buf[12..16], 9000, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.resolution_entry, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(u8, 1), frame.resolution_entry.res_type);
    try std.testing.expectEqual(@as(u8, 16), frame.resolution_entry.address_length);
    try std.testing.expectEqual(@as(u16, 40123), frame.resolution_entry.port);
    try std.testing.expectEqual(@as(i32, 9000), frame.resolution_entry.age_in_ms);
}

test "decode: decodes response setup frame" {
    var buf align(8) = [_]u8{0} ** 32;
    std.mem.writeInt(i32, buf[0..4], @as(i32, ResponseSetupHeader.LENGTH), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.response_setup), .little);
    std.mem.writeInt(i32, buf[8..12], 71, .little);
    std.mem.writeInt(i32, buf[12..16], 72, .little);
    std.mem.writeInt(i32, buf[16..20], 73, .little);

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.response_setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 71), frame.response_setup.session_id);
    try std.testing.expectEqual(@as(i32, 72), frame.response_setup.stream_id);
    try std.testing.expectEqual(@as(i32, 73), frame.response_setup.response_session_id);
}

test "decode: data payload respects frame_length not outer buffer length" {
    var buf align(8) = [_]u8{0} ** 96;
    const payload = "abc";
    const total_len = DataHeader.LENGTH + payload.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    @memcpy(buf[DataHeader.LENGTH..][0..payload.len], payload);
    @memcpy(buf[DataHeader.LENGTH + payload.len ..][0..5], "zzzzz");

    const frame = try decode(&buf);
    try std.testing.expectEqual(FrameType.data, std.meta.activeTag(frame));
    try std.testing.expectEqualSlices(u8, payload, frame.data.payload);
}

test "decode: rejects truncated DATA frame (frame_length < DataHeader.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 16, .little); // too short for DataHeader (32 bytes)
    buf[4] = VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(FrameType.data), .little);
    try std.testing.expectError(DecodeError.BufferTooShort, decode(&buf));
}
