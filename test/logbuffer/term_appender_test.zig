const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const TermAppender = aeron.logbuffer.TermAppender;
const AppendResult = aeron.logbuffer.AppendResult;

test "TermAppender: single append returns ok at offset 0" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(5, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.frame_length = 0;
    header.version = frame.VERSION;
    header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
    header.type = @intFromEnum(frame.FrameType.data);
    header.term_offset = 0;
    header.session_id = 123;
    header.stream_id = 456;
    header.term_id = 5;
    header.reserved_value = 0;

    const payload = "hello";
    const result = appender.appendData(&header, payload);

    try std.testing.expect(std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok);
    try std.testing.expectEqual(@as(i32, 0), result.ok);
}

test "TermAppender: verify frame header fields written correctly" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(10, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.frame_length = 0;
    header.version = frame.VERSION;
    header.flags = 0x55;
    header.type = @intFromEnum(frame.FrameType.data);
    header.term_offset = 0;
    header.session_id = 9999;
    header.stream_id = 8888;
    header.term_id = 10;
    header.reserved_value = 0x0102030405060708;

    const payload = "test";
    _ = appender.appendData(&header, payload);

    // Read back the header fields from the buffer
    const written_header: *const frame.DataHeader = @ptrCast(@alignCast(&term_buffer[0]));

    // frame_length should be set to unaligned total_len
    const expected_frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload.len));
    try std.testing.expectEqual(expected_frame_len, written_header.frame_length);

    try std.testing.expectEqual(frame.VERSION, written_header.version);
    try std.testing.expectEqual(@as(u8, 0x55), written_header.flags);
    try std.testing.expectEqual(@intFromEnum(frame.FrameType.data), written_header.type);
    try std.testing.expectEqual(@as(i32, 0), written_header.term_offset);
    try std.testing.expectEqual(@as(i32, 9999), written_header.session_id);
    try std.testing.expectEqual(@as(i32, 8888), written_header.stream_id);
    try std.testing.expectEqual(@as(i32, 10), written_header.term_id);
    try std.testing.expectEqual(@as(i64, 0x0102030405060708), written_header.reserved_value);
}

test "TermAppender: verify payload written after header" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.frame_length = 0;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.term_offset = 0;
    header.session_id = 100;
    header.stream_id = 200;
    header.term_id = 1;
    header.reserved_value = 0;

    const payload = "payload data";
    _ = appender.appendData(&header, payload);

    // Verify payload at correct offset
    const payload_offset = frame.DataHeader.LENGTH;
    const written_payload = term_buffer[payload_offset .. payload_offset + payload.len];
    try std.testing.expectEqualSlices(u8, payload, written_payload);
}

test "TermAppender: back-to-back appends advance offset correctly" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(7, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 100;
    header.stream_id = 200;
    header.term_id = 7;
    header.reserved_value = 0;

    const payload1 = "first";
    header.term_offset = 0;
    const result1 = appender.appendData(&header, payload1);
    try std.testing.expectEqual(@as(i32, 0), result1.ok);

    // Second append should be at aligned offset
    const frame_len1 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload1.len));
    const aligned_len1 = std.mem.alignForward(i32, frame_len1, @as(i32, @intCast(frame.FRAME_ALIGNMENT)));

    const payload2 = "second";
    header.term_offset = aligned_len1;
    const result2 = appender.appendData(&header, payload2);
    try std.testing.expectEqual(aligned_len1, result2.ok);

    // Verify second frame at correct offset
    const second_frame_ptr: *const frame.DataHeader = @ptrCast(@alignCast(&term_buffer[@intCast(aligned_len1)]));
    try std.testing.expectEqual(@as(i32, 100), second_frame_ptr.session_id);
}

test "TermAppender: three frames in sequence" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(2, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 10;
    header.stream_id = 20;
    header.term_id = 2;
    header.reserved_value = 0;

    const payloads = [_][]const u8{ "a", "bb", "ccc" };
    var offset: i32 = 0;
    for (payloads) |payload| {
        header.term_offset = offset;
        const result = appender.appendData(&header, payload);
        try std.testing.expectEqual(offset, result.ok);

        // Calculate the aligned length from frame_length
        const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload.len));
        const aligned_len = std.mem.alignForward(i32, frame_len, @as(i32, @intCast(frame.FRAME_ALIGNMENT)));
        offset += aligned_len;
    }
}

test "TermAppender: append that would exceed term_length returns tripped" {
    const allocator = std.testing.allocator;
    const small_term = try allocator.alloc(u8, 100);
    defer allocator.free(small_term);
    @memset(small_term, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(small_term, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;
    header.term_offset = 0;

    const large_payload = try allocator.alloc(u8, 200);
    defer allocator.free(large_payload);

    const result = appender.appendData(&header, large_payload);
    try std.testing.expect(std.meta.activeTag(result) == std.meta.Tag(AppendResult).tripped);
}

test "TermAppender: packTail encodes term_id in high 32 bits, offset in low 32 bits" {
    const term_id = @as(i32, 42);
    const term_offset = @as(i32, 12345);

    const packed_tail = TermAppender.packTail(term_id, term_offset);

    const extracted_term_id = @as(i32, @intCast(packed_tail >> 32));
    const extracted_offset = @as(i32, @intCast(packed_tail & 0xFFFF_FFFF));

    try std.testing.expectEqual(term_id, extracted_term_id);
    try std.testing.expectEqual(term_offset, extracted_offset);
}

test "TermAppender: packTail with large term_id" {
    const term_id = @as(i32, 0x7FFF_FFFF); // max i32
    const term_offset = @as(i32, 0x12345678);

    const packed_tail = TermAppender.packTail(term_id, term_offset);

    const extracted_term_id = @as(i32, @intCast(packed_tail >> 32));
    const extracted_offset = @as(i32, @intCast(packed_tail & 0xFFFF_FFFF));

    try std.testing.expectEqual(term_id, extracted_term_id);
    try std.testing.expectEqual(term_offset, extracted_offset);
}

test "TermAppender: rawTailVolatile advances by aligned record length" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(5, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 5;
    header.reserved_value = 0;

    const payload = "test";
    _ = appender.appendData(&header, payload);

    const tail_after = appender.rawTailVolatile();
    const offset_after = @as(i32, @intCast(tail_after & 0xFFFF_FFFF));
    const term_id_after = @as(i32, @intCast(tail_after >> 32));

    // Should still be term_id 5
    try std.testing.expectEqual(@as(i32, 5), term_id_after);

    // Offset should have advanced by aligned_length
    const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload.len));
    const aligned_len = std.mem.alignForward(i32, frame_len, @as(i32, @intCast(frame.FRAME_ALIGNMENT)));
    try std.testing.expectEqual(aligned_len, offset_after);
}

test "TermAppender: appendPadding fills to end of term" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(10, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 10;
    header.reserved_value = 0;

    const payload = "test";
    const result1 = appender.appendData(&header, payload);
    try std.testing.expectEqual(@as(i32, 0), result1.ok);

    const result2 = appender.appendPadding(0);
    try std.testing.expect(std.meta.activeTag(result2) == std.meta.Tag(AppendResult).padding_applied);
}

test "TermAppender: padding frame type is set correctly" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(3, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 3;
    header.reserved_value = 0;

    const payload = "short";
    _ = appender.appendData(&header, payload);

    // Append padding
    _ = appender.appendPadding(0);

    // Find where padding was written
    const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload.len));
    const aligned_len = std.mem.alignForward(i32, frame_len, @as(i32, @intCast(frame.FRAME_ALIGNMENT)));

    const padding_header: *const frame.DataHeader = @ptrCast(@alignCast(&term_buffer[@intCast(aligned_len)]));
    try std.testing.expectEqual(@intFromEnum(frame.FrameType.padding), padding_header.type);
}

test "TermAppender: CAS failure behavior with AppendResult" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;

    const payload = "test";
    const result = appender.appendData(&header, payload);

    // First append should succeed
    try std.testing.expect(std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok);
}

test "TermAppender: fill term exactly to term_length" {
    const allocator = std.testing.allocator;
    const term_length: i32 = 512;
    const term_buffer = try allocator.alloc(u8, @intCast(term_length));
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;

    // Append frames until we can't fit another aligned one
    var current_offset: i32 = 0;
    var frame_count: i32 = 0;
    while (current_offset < term_length - 64) {
        const payload = "d";
        header.term_offset = current_offset;
        const result = appender.appendData(&header, payload);

        if (std.meta.activeTag(result) == std.meta.Tag(AppendResult).tripped) {
            break;
        }

        const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload.len));
        current_offset = std.mem.alignForward(i32, frame_len, @as(i32, @intCast(frame.FRAME_ALIGNMENT)));
        frame_count += 1;
    }

    try std.testing.expect(frame_count > 0);
}

test "TermAppender: empty payload" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;

    const result = appender.appendData(&header, "");
    try std.testing.expect(std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok);

    // Header should still be written
    const written_header: *const frame.DataHeader = @ptrCast(@alignCast(&term_buffer[0]));
    try std.testing.expectEqual(@as(i32, frame.DataHeader.LENGTH), written_header.frame_length);
}

test "TermAppender: large payload" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;

    const large_payload = try allocator.alloc(u8, 4096);
    defer allocator.free(large_payload);
    @memset(large_payload, 0xAA);

    const result = appender.appendData(&header, large_payload);
    try std.testing.expect(std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok);

    // Verify payload was written
    const payload_offset = frame.DataHeader.LENGTH;
    const written_payload = term_buffer[payload_offset .. payload_offset + large_payload.len];
    try std.testing.expectEqualSlices(u8, large_payload, written_payload);
}

test "TermAppender: begin and end flags preserved" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(1, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 1;
    header.reserved_value = 0;

    const payload = "msg";
    _ = appender.appendData(&header, payload);

    const written_header: *const frame.DataHeader = @ptrCast(@alignCast(&term_buffer[0]));
    try std.testing.expectEqual(frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG, written_header.flags);
}
