//! SBE codecs for the Aeron Cluster member consensus channel.
//!
//! These layouts are taken from the vendored aeron-cluster-codecs.xml
//! (schema 111, version 15). They are deliberately separate from the older
//! educational protocol.zig types, which model the repository's internal
//! state machine rather than Java Aeron Cluster wire messages.

const std = @import("std");

pub const SCHEMA_ID: u16 = 111;
pub const SCHEMA_VERSION: u16 = 15;
pub const HEADER_LENGTH: usize = 8;

pub const Template = enum(u16) {
    canvass_position = 50,
    request_vote = 51,
    vote = 52,
    new_leadership_term = 53,
    append_position = 54,
    commit_position = 55,
    catchup_position = 56,
    stop_catchup = 57,
};

pub const Header = struct {
    block_length: u16,
    template_id: Template,
    schema_id: u16,
    version: u16,
};

pub const CanvassPosition = struct {
    log_leadership_term_id: i64,
    log_position: i64,
    leadership_term_id: i64,
    follower_member_id: i32,
    protocol_version: i32,
};

pub const RequestVote = struct {
    log_leadership_term_id: i64,
    log_position: i64,
    candidate_term_id: i64,
    candidate_member_id: i32,
    protocol_version: i32,
};

pub const Vote = struct {
    candidate_term_id: i64,
    log_leadership_term_id: i64,
    log_position: i64,
    candidate_member_id: i32,
    follower_member_id: i32,
    vote: i32,
};

pub const AppendPosition = struct {
    leadership_term_id: i64,
    log_position: i64,
    follower_member_id: i32,
    flags: u8,
};

pub const CommitPosition = struct {
    leadership_term_id: i64,
    log_position: i64,
    leader_member_id: i32,
};

pub const StopCatchup = struct {
    leadership_term_id: i64,
    follower_member_id: i32,
};

pub const CatchupPosition = struct {
    leadership_term_id: i64,
    log_position: i64,
    follower_member_id: i32,
    catchup_endpoint: []const u8,
};

pub const NewLeadershipTerm = struct {
    log_leadership_term_id: i64,
    next_leadership_term_id: i64,
    next_term_base_log_position: i64,
    next_log_position: i64,
    leadership_term_id: i64,
    term_base_log_position: i64,
    log_position: i64,
    leader_recording_id: i64,
    timestamp: i64,
    leader_member_id: i32,
    log_session_id: i32,
    app_version: i32,
    is_startup: i32,
    commit_position: i64,
};

pub const CanvassPositionBlockLength = 32;
pub const RequestVoteBlockLength = 32;
pub const VoteBlockLength = 36;
pub const NewLeadershipTermBlockLength = 96;
pub const AppendPositionBlockLength = 21;
pub const CommitPositionBlockLength = 20;
pub const CatchupPositionBlockLength = 20;
pub const StopCatchupBlockLength = 12;

fn put(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, buffer: []const u8, offset: usize) T {
    return std.mem.readInt(T, buffer[offset..][0..@sizeOf(T)], .little);
}

pub fn encodeHeader(buffer: []u8, block_length: u16, template: Template) !void {
    if (buffer.len < HEADER_LENGTH) return error.BufferTooSmall;
    put(u16, buffer, 0, block_length);
    put(u16, buffer, 2, @intFromEnum(template));
    put(u16, buffer, 4, SCHEMA_ID);
    put(u16, buffer, 6, SCHEMA_VERSION);
}

pub fn decodeHeader(buffer: []const u8) !Header {
    if (buffer.len < HEADER_LENGTH) return error.BufferTooSmall;
    if (get(u16, buffer, 4) != SCHEMA_ID) return error.SchemaMismatch;
    const template_id: Template = switch (get(u16, buffer, 2)) {
        50 => .canvass_position,
        51 => .request_vote,
        52 => .vote,
        53 => .new_leadership_term,
        54 => .append_position,
        55 => .commit_position,
        56 => .catchup_position,
        57 => .stop_catchup,
        else => return error.UnknownTemplate,
    };
    return .{
        .block_length = get(u16, buffer, 0),
        .template_id = template_id,
        .schema_id = get(u16, buffer, 4),
        .version = get(u16, buffer, 6),
    };
}

pub fn encodeCanvassPosition(buffer: []u8, value: CanvassPosition) !usize {
    try encodeFixedHeader(buffer, CanvassPositionBlockLength, .canvass_position);
    if (buffer.len < HEADER_LENGTH + CanvassPositionBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.log_leadership_term_id);
    put(i64, buffer, 16, value.log_position);
    put(i64, buffer, 24, value.leadership_term_id);
    put(i32, buffer, 32, value.follower_member_id);
    put(i32, buffer, 36, value.protocol_version);
    return HEADER_LENGTH + CanvassPositionBlockLength;
}

pub fn decodeCanvassPosition(buffer: []const u8) !CanvassPosition {
    try validateFixed(buffer, .canvass_position, CanvassPositionBlockLength);
    return .{
        .log_leadership_term_id = get(i64, buffer, 8),
        .log_position = get(i64, buffer, 16),
        .leadership_term_id = get(i64, buffer, 24),
        .follower_member_id = get(i32, buffer, 32),
        .protocol_version = get(i32, buffer, 36),
    };
}

pub fn encodeRequestVote(buffer: []u8, value: RequestVote) !usize {
    try encodeFixedHeader(buffer, RequestVoteBlockLength, .request_vote);
    if (buffer.len < HEADER_LENGTH + RequestVoteBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.log_leadership_term_id);
    put(i64, buffer, 16, value.log_position);
    put(i64, buffer, 24, value.candidate_term_id);
    put(i32, buffer, 32, value.candidate_member_id);
    put(i32, buffer, 36, value.protocol_version);
    return HEADER_LENGTH + RequestVoteBlockLength;
}

pub fn decodeRequestVote(buffer: []const u8) !RequestVote {
    try validateFixed(buffer, .request_vote, RequestVoteBlockLength);
    return .{
        .log_leadership_term_id = get(i64, buffer, 8),
        .log_position = get(i64, buffer, 16),
        .candidate_term_id = get(i64, buffer, 24),
        .candidate_member_id = get(i32, buffer, 32),
        .protocol_version = get(i32, buffer, 36),
    };
}

pub fn encodeVote(buffer: []u8, value: Vote) !usize {
    try encodeFixedHeader(buffer, VoteBlockLength, .vote);
    if (buffer.len < HEADER_LENGTH + VoteBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.candidate_term_id);
    put(i64, buffer, 16, value.log_leadership_term_id);
    put(i64, buffer, 24, value.log_position);
    put(i32, buffer, 32, value.candidate_member_id);
    put(i32, buffer, 36, value.follower_member_id);
    put(i32, buffer, 40, value.vote);
    return HEADER_LENGTH + VoteBlockLength;
}

pub fn decodeVote(buffer: []const u8) !Vote {
    try validateFixed(buffer, .vote, VoteBlockLength);
    return .{
        .candidate_term_id = get(i64, buffer, 8),
        .log_leadership_term_id = get(i64, buffer, 16),
        .log_position = get(i64, buffer, 24),
        .candidate_member_id = get(i32, buffer, 32),
        .follower_member_id = get(i32, buffer, 36),
        .vote = get(i32, buffer, 40),
    };
}

pub fn encodeAppendPosition(buffer: []u8, value: AppendPosition) !usize {
    try encodeFixedHeader(buffer, AppendPositionBlockLength, .append_position);
    if (buffer.len < HEADER_LENGTH + AppendPositionBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.leadership_term_id);
    put(i64, buffer, 16, value.log_position);
    put(i32, buffer, 24, value.follower_member_id);
    buffer[28] = value.flags;
    return HEADER_LENGTH + AppendPositionBlockLength;
}

pub fn encodeNewLeadershipTerm(buffer: []u8, value: NewLeadershipTerm) !usize {
    try encodeFixedHeader(buffer, NewLeadershipTermBlockLength, .new_leadership_term);
    if (buffer.len < HEADER_LENGTH + NewLeadershipTermBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.log_leadership_term_id);
    put(i64, buffer, 16, value.next_leadership_term_id);
    put(i64, buffer, 24, value.next_term_base_log_position);
    put(i64, buffer, 32, value.next_log_position);
    put(i64, buffer, 40, value.leadership_term_id);
    put(i64, buffer, 48, value.term_base_log_position);
    put(i64, buffer, 56, value.log_position);
    put(i64, buffer, 64, value.leader_recording_id);
    put(i64, buffer, 72, value.timestamp);
    put(i32, buffer, 80, value.leader_member_id);
    put(i32, buffer, 84, value.log_session_id);
    put(i32, buffer, 88, value.app_version);
    put(i32, buffer, 92, value.is_startup);
    put(i64, buffer, 96, value.commit_position);
    return HEADER_LENGTH + NewLeadershipTermBlockLength;
}

pub fn decodeNewLeadershipTerm(buffer: []const u8) !NewLeadershipTerm {
    try validateFixed(buffer, .new_leadership_term, NewLeadershipTermBlockLength);
    return .{
        .log_leadership_term_id = get(i64, buffer, 8),
        .next_leadership_term_id = get(i64, buffer, 16),
        .next_term_base_log_position = get(i64, buffer, 24),
        .next_log_position = get(i64, buffer, 32),
        .leadership_term_id = get(i64, buffer, 40),
        .term_base_log_position = get(i64, buffer, 48),
        .log_position = get(i64, buffer, 56),
        .leader_recording_id = get(i64, buffer, 64),
        .timestamp = get(i64, buffer, 72),
        .leader_member_id = get(i32, buffer, 80),
        .log_session_id = get(i32, buffer, 84),
        .app_version = get(i32, buffer, 88),
        .is_startup = get(i32, buffer, 92),
        .commit_position = get(i64, buffer, 96),
    };
}

pub fn encodeCatchupPosition(buffer: []u8, value: CatchupPosition) !usize {
    try encodeFixedHeader(buffer, CatchupPositionBlockLength, .catchup_position);
    const total_length = HEADER_LENGTH + CatchupPositionBlockLength + 4 + value.catchup_endpoint.len;
    if (buffer.len < total_length) return error.BufferTooSmall;
    put(i64, buffer, 8, value.leadership_term_id);
    put(i64, buffer, 16, value.log_position);
    put(i32, buffer, 24, value.follower_member_id);
    put(u32, buffer, 28, @intCast(value.catchup_endpoint.len));
    @memcpy(buffer[32 .. 32 + value.catchup_endpoint.len], value.catchup_endpoint);
    return total_length;
}

pub fn decodeAppendPosition(buffer: []const u8) !AppendPosition {
    try validateFixed(buffer, .append_position, AppendPositionBlockLength);
    return .{
        .leadership_term_id = get(i64, buffer, 8),
        .log_position = get(i64, buffer, 16),
        .follower_member_id = get(i32, buffer, 24),
        .flags = buffer[28],
    };
}

pub fn encodeCommitPosition(buffer: []u8, value: CommitPosition) !usize {
    try encodeFixedHeader(buffer, CommitPositionBlockLength, .commit_position);
    if (buffer.len < HEADER_LENGTH + CommitPositionBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.leadership_term_id);
    put(i64, buffer, 16, value.log_position);
    put(i32, buffer, 24, value.leader_member_id);
    return HEADER_LENGTH + CommitPositionBlockLength;
}

pub fn decodeCommitPosition(buffer: []const u8) !CommitPosition {
    try validateFixed(buffer, .commit_position, CommitPositionBlockLength);
    return .{
        .leadership_term_id = get(i64, buffer, 8),
        .log_position = get(i64, buffer, 16),
        .leader_member_id = get(i32, buffer, 24),
    };
}

pub fn decodeCatchupPosition(buffer: []const u8) !CatchupPosition {
    try validateFixed(buffer, .catchup_position, CatchupPositionBlockLength);
    const endpoint_length = @as(usize, @intCast(get(u32, buffer, 28)));
    if (HEADER_LENGTH + CatchupPositionBlockLength + 4 + endpoint_length > buffer.len) return error.BufferTooSmall;
    return .{
        .leadership_term_id = get(i64, buffer, 8),
        .log_position = get(i64, buffer, 16),
        .follower_member_id = get(i32, buffer, 24),
        .catchup_endpoint = buffer[32 .. 32 + endpoint_length],
    };
}

pub fn encodeStopCatchup(buffer: []u8, value: StopCatchup) !usize {
    try encodeFixedHeader(buffer, StopCatchupBlockLength, .stop_catchup);
    if (buffer.len < HEADER_LENGTH + StopCatchupBlockLength) return error.BufferTooSmall;
    put(i64, buffer, 8, value.leadership_term_id);
    put(i32, buffer, 16, value.follower_member_id);
    return HEADER_LENGTH + StopCatchupBlockLength;
}

pub fn decodeStopCatchup(buffer: []const u8) !StopCatchup {
    try validateFixed(buffer, .stop_catchup, StopCatchupBlockLength);
    return .{
        .leadership_term_id = get(i64, buffer, 8),
        .follower_member_id = get(i32, buffer, 16),
    };
}

fn encodeFixedHeader(buffer: []u8, block_length: u16, template: Template) !void {
    try encodeHeader(buffer, block_length, template);
}

fn validateFixed(buffer: []const u8, template: Template, block_length: u16) !void {
    const header = try decodeHeader(buffer);
    if (header.template_id != template) return error.TemplateMismatch;
    if (header.block_length != block_length) return error.BlockLengthMismatch;
    if (buffer.len < HEADER_LENGTH + block_length) return error.BufferTooSmall;
}

test "Aeron consensus SBE header matches vendored Java schema" {
    var buffer: [HEADER_LENGTH]u8 = undefined;
    try encodeHeader(&buffer, RequestVoteBlockLength, .request_vote);
    const header = try decodeHeader(&buffer);
    try std.testing.expectEqual(@as(u16, 32), header.block_length);
    try std.testing.expectEqual(Template.request_vote, header.template_id);
    try std.testing.expectEqual(@as(u16, 111), header.schema_id);
    try std.testing.expectEqual(@as(u16, 15), header.version);
}

test "Aeron consensus RequestVote encodes Java field offsets" {
    var buffer: [HEADER_LENGTH + RequestVoteBlockLength]u8 = undefined;
    const length = try encodeRequestVote(&buffer, .{
        .log_leadership_term_id = 1,
        .log_position = 2,
        .candidate_term_id = 3,
        .candidate_member_id = 4,
        .protocol_version = 5,
    });
    try std.testing.expectEqual(@as(usize, 40), length);
    try std.testing.expectEqual(@as(i64, 1), get(i64, &buffer, 8));
    try std.testing.expectEqual(@as(i64, 2), get(i64, &buffer, 16));
    try std.testing.expectEqual(@as(i64, 3), get(i64, &buffer, 24));
    try std.testing.expectEqual(@as(i32, 4), get(i32, &buffer, 32));
    try std.testing.expectEqual(@as(i32, 5), get(i32, &buffer, 36));
    const decoded = try decodeRequestVote(&buffer);
    try std.testing.expectEqual(@as(i64, 3), decoded.candidate_term_id);
    try std.testing.expectEqual(@as(i32, 4), decoded.candidate_member_id);
}

test "Aeron consensus codec rejects unknown schema and template" {
    var buffer: [HEADER_LENGTH]u8 = undefined;
    try encodeHeader(&buffer, VoteBlockLength, .vote);
    put(u16, &buffer, 4, 999);
    try std.testing.expectError(error.SchemaMismatch, decodeHeader(&buffer));
    put(u16, &buffer, 4, SCHEMA_ID);
    put(u16, &buffer, 2, 999);
    try std.testing.expectError(error.UnknownTemplate, decodeHeader(&buffer));
}

test "Aeron consensus variable catchup data follows the SBE block" {
    var buffer: [64]u8 = undefined;
    const length = try encodeCatchupPosition(&buffer, .{
        .leadership_term_id = 7,
        .log_position = 8,
        .follower_member_id = 2,
        .catchup_endpoint = "aeron:udp?endpoint=member:9000",
    });
    try std.testing.expectEqual(@as(usize, 8 + 20 + 4 + "aeron:udp?endpoint=member:9000".len), length);
    try std.testing.expectEqual(@as(u32, "aeron:udp?endpoint=member:9000".len), get(u32, &buffer, 28));
    try std.testing.expectEqualStrings("aeron:udp?endpoint=member:9000", buffer[32..length]);
}
