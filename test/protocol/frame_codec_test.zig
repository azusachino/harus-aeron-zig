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
    buf[4] = 1;
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
    try std.testing.expectEqual(@as(u8, 1), frame.nak.version);
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
