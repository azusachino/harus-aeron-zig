// Upstream reference: aeron-client/src/test/java/io/aeron/DataHeaderFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/SetupFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/StatusMessageFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/FlyweightTest.java
//                    aeron-client/src/main/java/io/aeron/protocol/NakFlyweight.java
//                    aeron-client/src/main/java/io/aeron/protocol/RttMeasurementFlyweight.java
//                    aeron-client/src/main/c/protocol/aeron_udp_protocol.h
// Aeron version: 1.50.2
// Coverage: frame_type, version, flags, stream_id, session_id, term_id, term_offset, frame_length, upstream NAK/RTT byte layout

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

test "NakHeader matches upstream FlyweightTest byte fixture" {
    var buf align(8) = [_]u8{0} ** protocol.NakHeader.LENGTH;

    std.mem.writeInt(i32, buf[0..4], protocol.NakHeader.LENGTH, .little);
    buf[4] = protocol.VERSION;
    buf[5] = 0;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.nak), .little);
    std.mem.writeInt(i32, buf[8..12], @as(i32, @bitCast(@as(u32, 0xDEAD_BEEF))), .little);
    std.mem.writeInt(i32, buf[12..16], @as(i32, @bitCast(@as(u32, 0x4433_2211))), .little);
    std.mem.writeInt(i32, buf[16..20], @as(i32, @bitCast(@as(u32, 0x9988_7766))), .little);
    std.mem.writeInt(i32, buf[20..24], 0x22334, .little);
    std.mem.writeInt(i32, buf[24..28], 512, .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.nak, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 28), frame.nak.frame_length);
    try std.testing.expectEqual(protocol.VERSION, frame.nak.version);
    try std.testing.expectEqual(@as(u8, 0), frame.nak.flags);
    try std.testing.expectEqual(@intFromEnum(protocol.FrameType.nak), frame.nak.type);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEAD_BEEF))), frame.nak.session_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x4433_2211))), frame.nak.stream_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x9988_7766))), frame.nak.term_id);
    try std.testing.expectEqual(@as(i32, 0x22334), frame.nak.term_offset);
    try std.testing.expectEqual(@as(i32, 512), frame.nak.length);
}

test "RttMeasurement matches upstream non-reply wire layout" {
    var buf align(8) = [_]u8{0} ** protocol.RttMeasurement.LENGTH;

    std.mem.writeInt(i32, buf[0..4], protocol.RttMeasurement.LENGTH, .little);
    buf[4] = protocol.VERSION;
    buf[5] = 0;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.rtt_measurement), .little);
    std.mem.writeInt(i32, buf[8..12], 0x1111_2222, .little);
    std.mem.writeInt(i32, buf[12..16], 0x3333_4444, .little);
    std.mem.writeInt(i64, buf[16..24], 0x0102_0304_0506_0708, .little);
    std.mem.writeInt(i64, buf[24..32], 0x1112_1314_1516_1718, .little);
    std.mem.writeInt(i64, buf[32..40], 0x2122_2324_2526_2728, .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.rtt_measurement, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 40), frame.rtt_measurement.frame_length);
    try std.testing.expectEqual(protocol.VERSION, frame.rtt_measurement.version);
    try std.testing.expectEqual(@as(u8, 0), frame.rtt_measurement.flags);
    try std.testing.expectEqual(@intFromEnum(protocol.FrameType.rtt_measurement), frame.rtt_measurement.type);
    try std.testing.expectEqual(@as(i32, 0x1111_2222), frame.rtt_measurement.session_id);
    try std.testing.expectEqual(@as(i32, 0x3333_4444), frame.rtt_measurement.stream_id);
    try std.testing.expectEqual(@as(i64, 0x0102_0304_0506_0708), frame.rtt_measurement.echo_timestamp);
    try std.testing.expectEqual(@as(i64, 0x1112_1314_1516_1718), frame.rtt_measurement.reception_delta);
    try std.testing.expectEqual(@as(i64, 0x2122_2324_2526_2728), frame.rtt_measurement.receiver_id);
}

test "RttMeasurement matches upstream reply flag and reply semantics" {
    var buf align(8) = [_]u8{0} ** protocol.RttMeasurement.LENGTH;

    std.mem.writeInt(i32, buf[0..4], protocol.RttMeasurement.LENGTH, .little);
    buf[4] = protocol.VERSION;
    buf[5] = protocol.RttMeasurement.REPLY_FLAG;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.rtt_measurement), .little);
    std.mem.writeInt(i32, buf[8..12], 7, .little);
    std.mem.writeInt(i32, buf[12..16], 9, .little);
    std.mem.writeInt(i64, buf[16..24], 123456789, .little);
    std.mem.writeInt(i64, buf[24..32], 0, .little);
    std.mem.writeInt(i64, buf[32..40], 987654321, .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.rtt_measurement, std.meta.activeTag(frame));
    try std.testing.expectEqual(protocol.RttMeasurement.REPLY_FLAG, frame.rtt_measurement.flags);
    try std.testing.expectEqual(@as(i64, 123456789), frame.rtt_measurement.echo_timestamp);
    try std.testing.expectEqual(@as(i64, 0), frame.rtt_measurement.reception_delta);
    try std.testing.expectEqual(@as(i64, 987654321), frame.rtt_measurement.receiver_id);
}

// ===== New edge-case tests =====

test "DataHeader: BEGIN flag only" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.flags = protocol.DataHeader.BEGIN_FLAG;
    try std.testing.expect(protocol.isBeginFragment(hdr.flags));
    try std.testing.expect(!protocol.isEndFragment(hdr.flags));
}

test "DataHeader: END flag only" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.flags = protocol.DataHeader.END_FLAG;
    try std.testing.expect(!protocol.isBeginFragment(hdr.flags));
    try std.testing.expect(protocol.isEndFragment(hdr.flags));
}

test "DataHeader: BEGIN + END flags" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.flags = protocol.DataHeader.BEGIN_FLAG | protocol.DataHeader.END_FLAG;
    try std.testing.expect(protocol.isBeginFragment(hdr.flags));
    try std.testing.expect(protocol.isEndFragment(hdr.flags));
}

test "DataHeader: EOS flag only" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.flags = protocol.DataHeader.EOS_FLAG;
    try std.testing.expect(!protocol.isBeginFragment(hdr.flags));
    try std.testing.expect(!protocol.isEndFragment(hdr.flags));
}

test "DataHeader: session_id negative round-trip" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.session_id = std.math.minInt(i32);
    try std.testing.expectEqual(std.math.minInt(i32), hdr.session_id);
}

test "DataHeader: stream_id negative round-trip" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.stream_id = std.math.minInt(i32);
    try std.testing.expectEqual(std.math.minInt(i32), hdr.stream_id);
}

test "DataHeader: term_id negative round-trip" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.term_id = std.math.minInt(i32);
    try std.testing.expectEqual(std.math.minInt(i32), hdr.term_id);
}

test "DataHeader: term_offset INT_MAX" {
    var hdr: protocol.DataHeader = std.mem.zeroes(protocol.DataHeader);
    hdr.term_offset = std.math.maxInt(i32);
    try std.testing.expectEqual(std.math.maxInt(i32), hdr.term_offset);
}

test "alignedLength: 0 -> 32" {
    try std.testing.expectEqual(@as(usize, 32), protocol.alignedLength(0));
}

test "alignedLength: 1 -> 64" {
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(1));
}

test "alignedLength: 31 -> 64" {
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(31));
}

test "alignedLength: 32 -> 64" {
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(32));
}

test "alignedLength: 33 -> 96" {
    try std.testing.expectEqual(@as(usize, 96), protocol.alignedLength(33));
}

test "alignedLength: 64 -> 96" {
    try std.testing.expectEqual(@as(usize, 96), protocol.alignedLength(64));
}

test "computeMaxPayload: mtu=1408 -> 1376" {
    try std.testing.expectEqual(@as(usize, 1376), protocol.computeMaxPayload(1408));
}

test "computeMaxPayload: mtu=64 -> 32" {
    try std.testing.expectEqual(@as(usize, 32), protocol.computeMaxPayload(64));
}

test "computeMaxPayload: mtu=1024 -> 992" {
    try std.testing.expectEqual(@as(usize, 992), protocol.computeMaxPayload(1024));
}

test "SetupHeader size is exactly 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), protocol.SetupHeader.LENGTH);
}

test "StatusMessage size is exactly 36 bytes" {
    try std.testing.expectEqual(@as(usize, 36), protocol.StatusMessage.LENGTH);
}

test "NakHeader size is exactly 28 bytes" {
    try std.testing.expectEqual(@as(usize, 28), protocol.NakHeader.LENGTH);
}

test "RttMeasurement size is exactly 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), protocol.RttMeasurement.LENGTH);
}

test "decode: PADDING frame type" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 8, .little); // minimal frame_length
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.padding), .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.padding, std.meta.activeTag(frame));
}

test "decode: RESOLUTION_ENTRY frame type" {
    var buf align(8) = [_]u8{0} ** 32;
    std.mem.writeInt(i32, buf[0..4], protocol.ResolutionEntry.HEADER_LENGTH, .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.resolution_entry), .little);
    buf[8] = 2; // res_type
    buf[9] = 4; // address_length
    std.mem.writeInt(u16, buf[10..12], 12345, .little); // port
    std.mem.writeInt(i32, buf[12..16], 1000, .little); // age_in_ms

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.resolution_entry, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(u8, 2), frame.resolution_entry.res_type);
    try std.testing.expectEqual(@as(u8, 4), frame.resolution_entry.address_length);
    try std.testing.expectEqual(@as(u16, 12345), frame.resolution_entry.port);
    try std.testing.expectEqual(@as(i32, 1000), frame.resolution_entry.age_in_ms);
}

test "decode: RESPONSE_SETUP frame type" {
    var buf align(8) = [_]u8{0} ** 32;
    std.mem.writeInt(i32, buf[0..4], protocol.ResponseSetupHeader.LENGTH, .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.response_setup), .little);
    std.mem.writeInt(i32, buf[8..12], 101, .little); // session_id
    std.mem.writeInt(i32, buf[12..16], 102, .little); // stream_id
    std.mem.writeInt(i32, buf[16..20], 103, .little); // response_session_id

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.response_setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 101), frame.response_setup.session_id);
    try std.testing.expectEqual(@as(i32, 102), frame.response_setup.stream_id);
    try std.testing.expectEqual(@as(i32, 103), frame.response_setup.response_session_id);
}

test "decode: ExtensionHeader IGNORE_FLAG" {
    var buf align(8) = [_]u8{0} ** 64;
    const total_len = protocol.ExtensionHeader.LENGTH + 8;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.ext), .little);
    // header_length with IGNORE_FLAG set
    std.mem.writeInt(u16, buf[8..10], 8 | protocol.ExtensionHeader.IGNORE_FLAG, .little);
    std.mem.writeInt(u16, buf[10..12], 0x5678, .little); // extension_type

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.ext, std.meta.activeTag(frame));
    try std.testing.expect(frame.ext.header.isIgnorable());
    try std.testing.expectEqual(@as(u16, 8), frame.ext.header.length());
}

test "decode: rejects truncated NAK frame (frame_length < NakHeader.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 20, .little); // too short for NAK (28 bytes)
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.nak), .little);
    try std.testing.expectError(protocol.DecodeError.BufferTooShort, protocol.decode(&buf));
}

test "decode: rejects truncated STATUS frame (frame_length < StatusMessage.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 32, .little); // too short for STATUS (36 bytes)
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.status), .little);
    try std.testing.expectError(protocol.DecodeError.BufferTooShort, protocol.decode(&buf));
}

test "decode: rejects truncated SETUP frame (frame_length < SetupHeader.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 32, .little); // too short for SETUP (40 bytes)
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.setup), .little);
    try std.testing.expectError(protocol.DecodeError.BufferTooShort, protocol.decode(&buf));
}

test "decode: rejects truncated RTT frame (frame_length < RttMeasurement.LENGTH)" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], 32, .little); // too short for RTT (40 bytes)
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.rtt_measurement), .little);
    try std.testing.expectError(protocol.DecodeError.BufferTooShort, protocol.decode(&buf));
}

test "decode: ERROR frame with empty error message" {
    var buf align(8) = [_]u8{0} ** 128;
    const total_len = protocol.ErrorHeader.LENGTH; // no message body
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.err), .little);
    std.mem.writeInt(i32, buf[8..12], 100, .little);
    std.mem.writeInt(i32, buf[12..16], 200, .little);
    std.mem.writeInt(i64, buf[16..24], 300, .little);
    std.mem.writeInt(i64, buf[24..32], 400, .little);
    std.mem.writeInt(i32, buf[32..36], 500, .little);
    std.mem.writeInt(i32, buf[36..40], 0, .little); // error_message_length = 0

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.err, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 0), frame.err.header.error_message_length);
    try std.testing.expectEqual(@as(usize, 0), frame.err.error_message.len);
}

test "decode: ERROR frame with HAS_GROUP_ID_FLAG unset" {
    var buf align(8) = [_]u8{0} ** 128;
    const msg = "error";
    const total_len = protocol.ErrorHeader.LENGTH + msg.len;
    std.mem.writeInt(i32, buf[0..4], @as(i32, @intCast(total_len)), .little);
    buf[4] = protocol.VERSION;
    buf[5] = 0; // flags = 0 (no HAS_GROUP_ID_FLAG)
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.err), .little);
    std.mem.writeInt(i32, buf[8..12], 10, .little);
    std.mem.writeInt(i32, buf[12..16], 20, .little);
    std.mem.writeInt(i64, buf[16..24], 30, .little);
    std.mem.writeInt(i64, buf[24..32], 40, .little);
    std.mem.writeInt(i32, buf[32..36], 50, .little);
    std.mem.writeInt(i32, buf[36..40], @as(i32, @intCast(msg.len)), .little);
    @memcpy(buf[protocol.ErrorHeader.LENGTH..][0..msg.len], msg);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.err, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(u8, 0), frame.err.header.flags);
}

test "decode: ATS_STATUS variant uses status layout" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], protocol.StatusMessage.LENGTH, .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.ats_status), .little);
    std.mem.writeInt(i32, buf[8..12], 111, .little);
    std.mem.writeInt(i32, buf[12..16], 222, .little);
    std.mem.writeInt(i32, buf[16..20], 333, .little);
    std.mem.writeInt(i32, buf[20..24], 444, .little);
    std.mem.writeInt(i32, buf[24..28], 555, .little);
    std.mem.writeInt(i64, buf[28..36], 666, .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.ats_status, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 111), frame.ats_status.session_id);
    try std.testing.expectEqual(@as(i32, 555), frame.ats_status.receiver_window);
    try std.testing.expectEqual(@as(i64, 666), frame.ats_status.receiver_id);
}

test "decode: NAK frame with all fields at max values" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], protocol.NakHeader.LENGTH, .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.nak), .little);
    std.mem.writeInt(i32, buf[8..12], std.math.maxInt(i32), .little);
    std.mem.writeInt(i32, buf[12..16], std.math.maxInt(i32), .little);
    std.mem.writeInt(i32, buf[16..20], std.math.maxInt(i32), .little);
    std.mem.writeInt(i32, buf[20..24], std.math.maxInt(i32), .little);
    std.mem.writeInt(i32, buf[24..28], std.math.maxInt(i32), .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.nak, std.meta.activeTag(frame));
    try std.testing.expectEqual(std.math.maxInt(i32), frame.nak.session_id);
    try std.testing.expectEqual(std.math.maxInt(i32), frame.nak.length);
}

test "decode: SETUP frame with zero TTL" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], protocol.SetupHeader.LENGTH, .little);
    buf[4] = protocol.VERSION;
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.setup), .little);
    std.mem.writeInt(i32, buf[8..12], 1, .little);
    std.mem.writeInt(i32, buf[12..16], 2, .little);
    std.mem.writeInt(i32, buf[16..20], 3, .little);
    std.mem.writeInt(i32, buf[20..24], 4, .little);
    std.mem.writeInt(i32, buf[24..28], 5, .little);
    std.mem.writeInt(i32, buf[28..32], 65536, .little);
    std.mem.writeInt(i32, buf[32..36], 1408, .little);
    std.mem.writeInt(i32, buf[36..40], 0, .little); // ttl = 0

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(protocol.FrameType.setup, std.meta.activeTag(frame));
    try std.testing.expectEqual(@as(i32, 0), frame.setup.ttl);
}

test "isBeginFragment: flag mask correctness" {
    try std.testing.expect(protocol.isBeginFragment(0x80));
    try std.testing.expect(protocol.isBeginFragment(0x81));
    try std.testing.expect(protocol.isBeginFragment(0xFF));
    try std.testing.expect(!protocol.isBeginFragment(0x00));
    try std.testing.expect(!protocol.isBeginFragment(0x40));
    try std.testing.expect(!protocol.isBeginFragment(0x7F));
}

test "isEndFragment: flag mask correctness" {
    try std.testing.expect(protocol.isEndFragment(0x40));
    try std.testing.expect(protocol.isEndFragment(0x41));
    try std.testing.expect(protocol.isEndFragment(0xFF));
    try std.testing.expect(!protocol.isEndFragment(0x00));
    try std.testing.expect(!protocol.isEndFragment(0x80));
    try std.testing.expect(!protocol.isEndFragment(0x3F));
}

test "StatusMessage: all fields round-trip with arbitrary values" {
    var buf align(8) = [_]u8{0} ** 64;
    std.mem.writeInt(i32, buf[0..4], protocol.StatusMessage.LENGTH, .little);
    buf[4] = protocol.VERSION;
    buf[5] = 0x42; // arbitrary flags
    std.mem.writeInt(u16, buf[6..8], @intFromEnum(protocol.FrameType.status), .little);
    std.mem.writeInt(i32, buf[8..12], @as(i32, @bitCast(@as(u32, 0xDEAD_BEEF))), .little);
    std.mem.writeInt(i32, buf[12..16], @as(i32, @bitCast(@as(u32, 0xCAFE_BABE))), .little);
    std.mem.writeInt(i32, buf[16..20], @as(i32, @bitCast(@as(u32, 0x1234_5678))), .little);
    std.mem.writeInt(i32, buf[20..24], @as(i32, @bitCast(@as(u32, 0x9ABC_DEF0))), .little);
    std.mem.writeInt(i32, buf[24..28], @as(i32, @bitCast(@as(u32, 0x1111_2222))), .little);
    std.mem.writeInt(i64, buf[28..36], @as(i64, @bitCast(@as(u64, 0x0102_0304_0506_0708))), .little);

    const frame = try protocol.decode(&buf);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEAD_BEEF))), frame.status.session_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xCAFE_BABE))), frame.status.stream_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x1234_5678))), frame.status.consumption_term_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x9ABC_DEF0))), frame.status.consumption_term_offset);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x1111_2222))), frame.status.receiver_window);
    try std.testing.expectEqual(@as(i64, @bitCast(@as(u64, 0x0102_0304_0506_0708))), frame.status.receiver_id);
}
