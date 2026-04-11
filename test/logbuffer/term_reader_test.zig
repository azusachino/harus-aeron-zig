const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const TermReader = aeron.logbuffer.term_reader.TermReader;

fn buildDataFrame(buffer: []u8, offset: usize, session_id: i32, stream_id: i32, term_id: i32, payload_data: []const u8) i32 {
    const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload_data.len));
    const frame_len_u32 = @as(u32, @intCast(frame_len));
    const aligned_len = @as(i32, @intCast((frame_len_u32 + 31) & ~@as(u32, 31)));

    var frame_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame_buf[0..4], frame_len, .little);
    std.mem.writeInt(u8, frame_buf[4..5], frame.VERSION, .little);
    std.mem.writeInt(u8, frame_buf[5..6], 0, .little);
    std.mem.writeInt(u16, frame_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
    std.mem.writeInt(i32, frame_buf[8..12], 0, .little);
    std.mem.writeInt(i32, frame_buf[12..16], session_id, .little);
    std.mem.writeInt(i32, frame_buf[16..20], stream_id, .little);
    std.mem.writeInt(i32, frame_buf[20..24], term_id, .little);
    std.mem.writeInt(i64, frame_buf[24..32], 0, .little);

    @memcpy(buffer[offset .. offset + 32], &frame_buf);
    if (payload_data.len > 0) {
        @memcpy(buffer[offset + 32 .. offset + 32 + payload_data.len], payload_data);
    }

    return aligned_len;
}

fn buildPaddingFrame(buffer: []u8, offset: usize) i32 {
    const padding_len: i32 = 64;
    const padding_len_u32 = @as(u32, @intCast(padding_len));
    const aligned_padding = @as(i32, @intCast((padding_len_u32 + 31) & ~@as(u32, 31)));

    var padding_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, padding_buf[0..4], padding_len, .little);
    std.mem.writeInt(u8, padding_buf[4..5], frame.VERSION, .little);
    std.mem.writeInt(u8, padding_buf[5..6], frame.DataHeader.PADDING_FLAG, .little);
    std.mem.writeInt(u16, padding_buf[6..8], @intFromEnum(frame.FrameType.padding), .little);
    std.mem.writeInt(i32, padding_buf[8..12], 0, .little);
    std.mem.writeInt(i32, padding_buf[12..16], 0, .little);
    std.mem.writeInt(i32, padding_buf[16..20], 0, .little);
    std.mem.writeInt(i32, padding_buf[20..24], 0, .little);
    std.mem.writeInt(i64, padding_buf[24..32], 0, .little);

    @memcpy(buffer[offset .. offset + 32], &padding_buf);
    return aligned_padding;
}

test "TermReader: read single committed frame" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const payload_data = "hello";
    _ = buildDataFrame(term, 0, 1, 2, 3, payload_data);

    var test_ctx = struct { called: bool = false, captured_payload: [32]u8 = undefined, captured_payload_len: usize = 0, session_id: i32 = 0 }{};

    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const state_ptr = @as(*struct { called: bool, captured_payload: [32]u8, captured_payload_len: usize, session_id: i32 }, @ptrCast(@alignCast(ctx)));
            state_ptr.called = true;
            state_ptr.session_id = header.session_id;
            @memcpy(state_ptr.captured_payload[0..payload_in.len], payload_in);
            state_ptr.captured_payload_len = payload_in.len;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_ctx, 10);

    try std.testing.expect(test_ctx.called);
    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqualSlices(u8, payload_data, test_ctx.captured_payload[0..test_ctx.captured_payload_len]);
    try std.testing.expectEqual(@as(i32, 1), test_ctx.session_id);
}

test "TermReader: read multiple committed frames" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload1_data = "frame1";
    const aligned_len1 = buildDataFrame(term, 0, 10, 20, 5, payload1_data);

    const payload2_data = "frame2";
    const aligned_len2 = buildDataFrame(term, @intCast(aligned_len1), 11, 21, 5, payload2_data);

    const payload3_data = "frame3";
    _ = buildDataFrame(term, @intCast(aligned_len1 + aligned_len2), 12, 22, 5, payload3_data);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 3), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 3), test_count);
}

test "TermReader: stop at fragments_limit" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    var offset: i32 = 0;
    for (0..5) |_| {
        const aligned_len = buildDataFrame(term, @intCast(offset), 1, 2, 5, payload);
        offset += aligned_len;
    }

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 2);

    try std.testing.expectEqual(@as(i32, 2), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 2), test_count);
}

test "TermReader: skip padding frame" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const aligned_padding = buildPaddingFrame(term, 0);

    const data_payload = "data";
    _ = buildDataFrame(term, @intCast(aligned_padding), 1, 2, 5, data_payload);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 1), test_count);
}

test "TermReader: skip multiple padding frames" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    var offset: i32 = 0;
    for (0..2) |_| {
        const aligned_padding = buildPaddingFrame(term, @intCast(offset));
        offset += aligned_padding;
    }

    const data_payload = "data";
    _ = buildDataFrame(term, @intCast(offset), 1, 2, 5, data_payload);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
}

test "TermReader: stop at frame_length zero (uncommitted)" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    const aligned_len = buildDataFrame(term, 0, 1, 2, 5, payload);

    // Write a zero frame_length at aligned_len (signals end of committed data)
    const offset_usize: usize = @intCast(aligned_len);
    var frame_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &frame_buf, 0, .little);
    @memcpy(term[offset_usize .. offset_usize + 4], &frame_buf);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(aligned_len, result.offset);
}

test "TermReader: read with non-zero starting offset" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload1 = "frame1";
    const aligned_len1 = buildDataFrame(term, 0, 1, 2, 5, payload1);

    const payload2 = "frame2";
    _ = buildDataFrame(term, @intCast(aligned_len1), 1, 2, 5, payload2);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    // Start reading from offset of second frame
    const result = TermReader.read(term, aligned_len1, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
}

test "TermReader: read to exact term end" {
    const allocator = std.testing.allocator;
    const term_size = 256;
    const term = try allocator.alloc(u8, term_size);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    const aligned_len = buildDataFrame(term, 0, 1, 2, 5, payload);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(aligned_len, result.offset);
}

test "TermReader: offset after reading frames is sum of aligned lengths" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload1 = "frame1";
    const aligned_len1 = buildDataFrame(term, 0, 1, 2, 5, payload1);

    const payload2 = "frame2more";
    const aligned_len2 = buildDataFrame(term, @intCast(aligned_len1), 1, 2, 5, payload2);

    const payload3 = "f3";
    const aligned_len3 = buildDataFrame(term, @intCast(aligned_len1 + aligned_len2), 1, 2, 5, payload3);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 3), result.fragments_read);
    try std.testing.expectEqual(aligned_len1 + aligned_len2 + aligned_len3, result.offset);
}

test "TermReader: fragments_read count correct with mixed padding and data" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    var offset: i32 = 0;

    const payload1 = "data1";
    const aligned_len1 = buildDataFrame(term, @intCast(offset), 1, 2, 5, payload1);
    offset += aligned_len1;

    const aligned_padding = buildPaddingFrame(term, @intCast(offset));
    offset += aligned_padding;

    const payload2 = "data2";
    _ = buildDataFrame(term, @intCast(offset), 1, 2, 5, payload2);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    // Only 2 DATA frames should be counted, padding is skipped
    try std.testing.expectEqual(@as(i32, 2), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 2), test_count);
}

test "TermReader: read preserves header fields" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "data";
    _ = buildDataFrame(term, 0, 9999, 8888, 7777, payload);

    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const ctx_ptr = @as(*struct { captured_session: i32, captured_stream: i32, captured_term: i32 }, @ptrCast(@alignCast(ctx)));
            ctx_ptr.captured_session = header.session_id;
            ctx_ptr.captured_stream = header.stream_id;
            ctx_ptr.captured_term = header.term_id;
            _ = payload_in;
        }
    }.handle;

    var ctx = struct { captured_session: i32 = 0, captured_stream: i32 = 0, captured_term: i32 = 0 }{};
    _ = TermReader.read(term, 0, handler, &ctx, 10);

    try std.testing.expectEqual(@as(i32, 9999), ctx.captured_session);
    try std.testing.expectEqual(@as(i32, 8888), ctx.captured_stream);
    try std.testing.expectEqual(@as(i32, 7777), ctx.captured_term);
}

test "TermReader: read with limit 0" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    _ = buildDataFrame(term, 0, 1, 2, 5, "data");

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 0);

    try std.testing.expectEqual(@as(i32, 0), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 0), test_count);
}

test "TermReader: read with limit 1" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload1 = "data1";
    const aligned_len1 = buildDataFrame(term, 0, 1, 2, 5, payload1);
    _ = buildDataFrame(term, @intCast(aligned_len1), 1, 2, 5, "data2");

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 1);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 1), test_count);
}

test "TermReader: negative frame_length treated as uncommitted" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    const aligned_len = buildDataFrame(term, 0, 1, 2, 5, payload);

    // Write negative frame_length at aligned_len
    const offset_usize: usize = @intCast(aligned_len);
    var frame_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &frame_buf, -100, .little);
    @memcpy(term[offset_usize .. offset_usize + 4], &frame_buf);

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(aligned_len, result.offset);
}

test "TermReader: read large number of frames" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    var offset: i32 = 0;

    // Write 50 frames
    for (0..50) |_| {
        const aligned_len = buildDataFrame(term, @intCast(offset), 1, 2, 5, payload);
        offset += aligned_len;
    }

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 100);

    try std.testing.expectEqual(@as(i32, 50), result.fragments_read);
    try std.testing.expectEqual(@as(i32, 50), test_count);
}

test "TermReader: read with offset that skips multiple frames" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    const payload = "x";
    var offset: i32 = 0;

    for (0..5) |_| {
        const aligned_len = buildDataFrame(term, @intCast(offset), 1, 2, 5, payload);
        offset += aligned_len;
    }

    // Now read starting from frame 3
    var skip_offset: i32 = 0;
    for (0..2) |_| {
        const frame_len = @as(i32, @intCast(frame.DataHeader.LENGTH)) + 1;
        const aligned = @as(i32, @intCast(((@as(u32, @intCast(frame_len)) + 31) & ~@as(u32, 31))));
        skip_offset += aligned;
    }

    var test_count: i32 = 0;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, skip_offset, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 3), result.fragments_read);
}

test "TermReader: read payload slice is correct" {
    const allocator = std.testing.allocator;
    const term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    const test_payload = "test payload data";
    _ = buildDataFrame(term, 0, 1, 2, 5, test_payload);

    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const ctx_ptr = @as(*struct { captured_payload: [64]u8, captured_len: usize }, @ptrCast(@alignCast(ctx)));
            @memcpy(ctx_ptr.captured_payload[0..payload_in.len], payload_in);
            ctx_ptr.captured_len = payload_in.len;
            _ = header;
        }
    }.handle;

    var ctx = struct { captured_payload: [64]u8 = undefined, captured_len: usize = 0 }{};
    _ = TermReader.read(term, 0, handler, &ctx, 10);

    try std.testing.expectEqualSlices(u8, test_payload, ctx.captured_payload[0..ctx.captured_len]);
}
