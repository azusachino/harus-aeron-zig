//! Wire codecs for the upstream Aeron Cluster client protocol.
//!
//! These are deliberately kept separate from `cluster/protocol.zig`. The latter is the
//! repository's internal consensus model and is not the SBE protocol spoken by Java Aeron.

const std = @import("std");

pub const SCHEMA_ID: u16 = 111;
pub const SCHEMA_VERSION: u16 = 15;
// Aeron Cluster's session-connect `version` field is a SemanticVersion (0.3.0),
// distinct from the SBE schema version above.
pub const PROTOCOL_SEMANTIC_VERSION: i32 = 0x000300;
pub const MESSAGE_HEADER_LENGTH: usize = 8;
pub const SESSION_MESSAGE_HEADER_LENGTH: usize = 24;
pub const SESSION_HEADER_LENGTH: usize = MESSAGE_HEADER_LENGTH + SESSION_MESSAGE_HEADER_LENGTH;

pub const TemplateId = enum(u16) {
    session_message_header = 1,
    session_event = 2,
    session_connect_request = 3,
    session_close_request = 4,
    session_keep_alive = 5,
    new_leader_event = 6,
};

pub const EventCode = enum(i32) {
    ok = 0,
    error_code = 1,
    redirect = 2,
    authentication_rejected = 3,
    closed = 4,
};

pub const MessageHeader = struct {
    block_length: u16,
    template_id: TemplateId,
    schema_id: u16,
    version: u16,
};

pub const SessionEvent = struct {
    cluster_session_id: i64,
    correlation_id: i64,
    leadership_term_id: i64,
    leader_member_id: i32,
    code: EventCode,
    version: i32,
    leader_heartbeat_timeout_ns: i64,
    detail: []const u8,
};

pub const NewLeaderEvent = struct {
    leadership_term_id: i64,
    cluster_session_id: i64,
    leader_member_id: i32,
    ingress_endpoints: []const u8,
};

pub fn encodeMessageHeader(
    buffer: []u8,
    block_length: u16,
    template_id: TemplateId,
    version: u16,
) !void {
    if (buffer.len < MESSAGE_HEADER_LENGTH) return error.BufferTooSmall;
    write(u16, buffer[0..2], block_length);
    write(u16, buffer[2..4], @intFromEnum(template_id));
    write(u16, buffer[4..6], SCHEMA_ID);
    write(u16, buffer[6..8], version);
}

pub fn decodeMessageHeader(buffer: []const u8) !MessageHeader {
    if (buffer.len < MESSAGE_HEADER_LENGTH) return error.BufferTooSmall;
    const template_id = std.enums.fromInt(TemplateId, read(u16, buffer[2..4])) orelse return error.InvalidTemplateId;
    return .{
        .block_length = read(u16, buffer[0..2]),
        .template_id = template_id,
        .schema_id = read(u16, buffer[4..6]),
        .version = read(u16, buffer[6..8]),
    };
}

/// Encode the fixed header prepended to application ingress/egress payloads.
pub fn encodeSessionMessageHeader(
    buffer: []u8,
    leadership_term_id: i64,
    cluster_session_id: i64,
    timestamp: i64,
) !usize {
    if (buffer.len < SESSION_HEADER_LENGTH) return error.BufferTooSmall;
    try encodeMessageHeader(buffer, SESSION_MESSAGE_HEADER_LENGTH, .session_message_header, SCHEMA_VERSION);
    write(i64, buffer[8..16], leadership_term_id);
    write(i64, buffer[16..24], cluster_session_id);
    write(i64, buffer[24..32], timestamp);
    return SESSION_HEADER_LENGTH;
}

pub fn encodeSessionKeepAlive(buffer: []u8, leadership_term_id: i64, cluster_session_id: i64) !usize {
    if (buffer.len < MESSAGE_HEADER_LENGTH + 16) return error.BufferTooSmall;
    try encodeMessageHeader(buffer, 16, .session_keep_alive, SCHEMA_VERSION);
    write(i64, buffer[8..16], leadership_term_id);
    write(i64, buffer[16..24], cluster_session_id);
    return 24;
}

/// Encode the SessionEvent sent by a cluster member during client connect.
/// This is shared by the Zig cluster sample and the client decoder so the
/// process-boundary example cannot drift from the Java-compatible layout.
pub fn encodeSessionEvent(
    buffer: []u8,
    cluster_session_id: i64,
    correlation_id: i64,
    leadership_term_id: i64,
    leader_member_id: i32,
    code: EventCode,
    detail: []const u8,
) !usize {
    const block_length: usize = 44;
    const total = MESSAGE_HEADER_LENGTH + block_length + 4 + detail.len;
    if (buffer.len < total) return error.BufferTooSmall;
    if (detail.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    try encodeMessageHeader(buffer, @intCast(block_length), .session_event, SCHEMA_VERSION);
    write(i64, buffer[8..16], cluster_session_id);
    write(i64, buffer[16..24], correlation_id);
    write(i64, buffer[24..32], leadership_term_id);
    write(i32, buffer[32..36], leader_member_id);
    write(i32, buffer[36..40], @intFromEnum(code));
    write(i32, buffer[40..44], PROTOCOL_SEMANTIC_VERSION);
    write(i64, buffer[44..52], 5_000_000_000);
    write(u32, buffer[52..56], @intCast(detail.len));
    @memcpy(buffer[56 .. 56 + detail.len], detail);
    return total;
}

pub fn encodeSessionCloseRequest(buffer: []u8, leadership_term_id: i64, cluster_session_id: i64) !usize {
    if (buffer.len < MESSAGE_HEADER_LENGTH + 16) return error.BufferTooSmall;
    try encodeMessageHeader(buffer, 16, .session_close_request, SCHEMA_VERSION);
    write(i64, buffer[8..16], leadership_term_id);
    write(i64, buffer[16..24], cluster_session_id);
    return 24;
}

/// Encode the Java Aeron Cluster session-connect request.
///
/// The three variable fields must remain in schema order: response channel, credentials,
/// then client info. Each is prefixed by a little-endian uint32 length.
pub fn encodeSessionConnectRequest(
    buffer: []u8,
    correlation_id: i64,
    response_stream_id: i32,
    version: i32,
    response_channel: []const u8,
    encoded_credentials: []const u8,
    client_info: []const u8,
) !usize {
    const fixed_length = MESSAGE_HEADER_LENGTH + 16;
    const total = fixed_length + 4 + response_channel.len + 4 + encoded_credentials.len + 4 + client_info.len;
    if (buffer.len < total) return error.BufferTooSmall;
    if (response_channel.len > std.math.maxInt(u32) or
        encoded_credentials.len > std.math.maxInt(u32) or
        client_info.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    try encodeMessageHeader(buffer, 16, .session_connect_request, SCHEMA_VERSION);
    write(i64, buffer[8..16], correlation_id);
    write(i32, buffer[16..20], response_stream_id);
    write(i32, buffer[20..24], version);

    var offset: usize = fixed_length;
    offset = putVar(buffer, offset, response_channel);
    offset = putVar(buffer, offset, encoded_credentials);
    offset = putVar(buffer, offset, client_info);
    return offset;
}

pub fn decodeSessionEvent(buffer: []const u8) !SessionEvent {
    const header = try decodeMessageHeader(buffer);
    if (header.schema_id != SCHEMA_ID) return error.InvalidSchemaId;
    if (header.template_id != .session_event) return error.UnexpectedTemplate;
    if (header.block_length < 44 or buffer.len < MESSAGE_HEADER_LENGTH + header.block_length) return error.InvalidMessage;

    const base = MESSAGE_HEADER_LENGTH;
    const detail_offset = base + header.block_length;
    const detail = try getVar(buffer, detail_offset);
    return .{
        .cluster_session_id = read(i64, buffer[base..][0..8]),
        .correlation_id = read(i64, buffer[base + 8 ..][0..8]),
        .leadership_term_id = read(i64, buffer[base + 16 ..][0..8]),
        .leader_member_id = read(i32, buffer[base + 24 ..][0..4]),
        .code = std.enums.fromInt(EventCode, read(i32, buffer[base + 28 ..][0..4])) orelse return error.InvalidEventCode,
        .version = read(i32, buffer[base + 32 ..][0..4]),
        .leader_heartbeat_timeout_ns = read(i64, buffer[base + 36 ..][0..8]),
        .detail = detail,
    };
}

pub fn decodeNewLeaderEvent(buffer: []const u8) !NewLeaderEvent {
    const header = try decodeMessageHeader(buffer);
    if (header.schema_id != SCHEMA_ID) return error.InvalidSchemaId;
    if (header.template_id != .new_leader_event) return error.UnexpectedTemplate;
    if (header.block_length < 20 or buffer.len < MESSAGE_HEADER_LENGTH + header.block_length) return error.InvalidMessage;
    const base = MESSAGE_HEADER_LENGTH;
    return .{
        .leadership_term_id = read(i64, buffer[base..][0..8]),
        .cluster_session_id = read(i64, buffer[base + 8 ..][0..8]),
        .leader_member_id = read(i32, buffer[base + 16 ..][0..4]),
        .ingress_endpoints = try getVar(buffer, base + header.block_length),
    };
}

fn putVar(buffer: []u8, offset: usize, value: []const u8) usize {
    write(u32, buffer[offset..][0..4], @intCast(value.len));
    @memcpy(buffer[offset + 4 ..][0..value.len], value);
    return offset + 4 + value.len;
}

fn getVar(buffer: []const u8, offset: usize) ![]const u8 {
    if (offset + 4 > buffer.len) return error.InvalidMessage;
    const length: usize = @intCast(read(u32, buffer[offset..][0..4]));
    if (offset + 4 + length > buffer.len) return error.InvalidMessage;
    return buffer[offset + 4 ..][0..length];
}

fn write(comptime T: type, destination: []u8, value: T) void {
    const width = @divExact(@typeInfo(T).int.bits, 8);
    std.mem.writeInt(T, @as(*[width]u8, @ptrCast(destination.ptr)), value, .little);
}

fn read(comptime T: type, source: []const u8) T {
    const width = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, @as(*const [width]u8, @ptrCast(source.ptr)), .little);
}

test "upstream session connect request layout" {
    var buffer: [128]u8 = undefined;
    const length = try encodeSessionConnectRequest(&buffer, 7, 10, PROTOCOL_SEMANTIC_VERSION, "aeron:udp?endpoint=client:0", &.{}, "zig-test");
    try std.testing.expectEqual(@as(u16, 16), read(u16, buffer[0..2]));
    try std.testing.expectEqual(@as(u16, 3), read(u16, buffer[2..4]));
    try std.testing.expectEqual(@as(u16, SCHEMA_ID), read(u16, buffer[4..6]));
    try std.testing.expectEqual(PROTOCOL_SEMANTIC_VERSION, read(i32, buffer[20..24]));
    try std.testing.expectEqual(@as(i64, 7), read(i64, buffer[8..16]));
    try std.testing.expectEqual(@as(i32, 10), read(i32, buffer[16..20]));
    try std.testing.expectEqual(@as(u32, 27), read(u32, buffer[24..28]));
    try std.testing.expectEqual(@as(usize, 24 + 4 + 27 + 4 + 0 + 4 + 8), length);
}

test "session event decoder follows SBE fixed block and var data" {
    var buffer: [96]u8 = undefined;
    try encodeMessageHeader(&buffer, 44, .session_event, SCHEMA_VERSION);
    write(i64, buffer[8..16], 12);
    write(i64, buffer[16..24], 99);
    write(i64, buffer[24..32], 4);
    write(i32, buffer[32..36], 1);
    write(i32, buffer[36..40], @intFromEnum(EventCode.ok));
    write(i32, buffer[40..44], 15);
    write(i64, buffer[44..52], 5_000_000_000);
    write(u32, buffer[52..56], 2);
    @memcpy(buffer[56..58], "ok");

    const event = try decodeSessionEvent(buffer[0..58]);
    try std.testing.expectEqual(@as(i64, 99), event.correlation_id);
    try std.testing.expectEqual(EventCode.ok, event.code);
    try std.testing.expectEqualStrings("ok", event.detail);
}

test "session event encoder round trips the Java-compatible layout" {
    var buffer: [128]u8 = undefined;
    const length = try encodeSessionEvent(&buffer, 12, 99, 4, 1, .ok, "ready");
    const event = try decodeSessionEvent(buffer[0..length]);
    try std.testing.expectEqual(@as(i64, 12), event.cluster_session_id);
    try std.testing.expectEqual(@as(i64, 99), event.correlation_id);
    try std.testing.expectEqual(@as(i64, 4), event.leadership_term_id);
    try std.testing.expectEqual(@as(i32, 1), event.leader_member_id);
    try std.testing.expectEqual(EventCode.ok, event.code);
    try std.testing.expectEqualStrings("ready", event.detail);
}
