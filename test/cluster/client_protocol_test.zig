//! Translated conformance cases from upstream Aeron Cluster client tests.

const std = @import("std");
const codecs = @import("aeron").cluster.client_codecs;

fn read(comptime T: type, bytes: []const u8) T {
    const width = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, @as(*const [width]u8, @ptrCast(bytes.ptr)), .little);
}

test "AeronClusterTest: session message header uses upstream field order" {
    var buffer: [codecs.SESSION_HEADER_LENGTH]u8 = undefined;
    _ = try codecs.encodeSessionMessageHeader(&buffer, 17, 19, 23);

    try std.testing.expectEqual(@as(u16, 24), read(u16, buffer[0..2]));
    try std.testing.expectEqual(@as(u16, 1), read(u16, buffer[2..4]));
    try std.testing.expectEqual(@as(u16, codecs.SCHEMA_ID), read(u16, buffer[4..6]));
    try std.testing.expectEqual(@as(i64, 17), read(i64, buffer[8..16])); // leadershipTermId
    try std.testing.expectEqual(@as(i64, 19), read(i64, buffer[16..24])); // clusterSessionId
    try std.testing.expectEqual(@as(i64, 23), read(i64, buffer[24..32])); // timestamp
}

test "IngressAdapterTest: session connect preserves SBE variable-data order" {
    var buffer: [256]u8 = undefined;
    const length = try codecs.encodeSessionConnectRequest(&buffer, 17, 19, 15, "x", &.{}, "test");

    try std.testing.expectEqual(@as(u16, 16), read(u16, buffer[0..2]));
    try std.testing.expectEqual(@as(u16, 3), read(u16, buffer[2..4]));
    try std.testing.expectEqual(@as(i64, 17), read(i64, buffer[8..16]));
    try std.testing.expectEqual(@as(i32, 19), read(i32, buffer[16..20]));
    try std.testing.expectEqual(@as(i32, 15), read(i32, buffer[20..24]));
    try std.testing.expectEqual(@as(u32, 1), read(u32, buffer[24..28]));
    try std.testing.expectEqualStrings("x", buffer[28..29]);
    try std.testing.expectEqual(@as(u32, 0), read(u32, buffer[29..33]));
    try std.testing.expectEqual(@as(u32, 4), read(u32, buffer[33..37]));
    try std.testing.expectEqualStrings("test", buffer[37..41]);
    try std.testing.expectEqual(@as(usize, 41), length);
}

test "EgressPollerTest: session event decodes application event fields" {
    var buffer: [128]u8 = undefined;
    try codecs.encodeMessageHeader(&buffer, 44, .session_event, codecs.SCHEMA_VERSION);
    std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(buffer[8..16].ptr)), 7777, .little);
    std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(buffer[16..24].ptr)), 42, .little);
    std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(buffer[24..32].ptr)), 5, .little);
    std.mem.writeInt(i32, @as(*[4]u8, @ptrCast(buffer[32..36].ptr)), 2, .little);
    std.mem.writeInt(i32, @as(*[4]u8, @ptrCast(buffer[36..40].ptr)), @intFromEnum(codecs.EventCode.redirect), .little);
    std.mem.writeInt(i32, @as(*[4]u8, @ptrCast(buffer[40..44].ptr)), 15, .little);
    std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(buffer[44..52].ptr)), 1_000_000, .little);
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(buffer[52..56].ptr)), 0, .little);

    const event = try codecs.decodeSessionEvent(buffer[0..56]);
    try std.testing.expectEqual(@as(i64, 7777), event.cluster_session_id);
    try std.testing.expectEqual(@as(i64, 42), event.correlation_id);
    try std.testing.expectEqual(codecs.EventCode.redirect, event.code);
}
