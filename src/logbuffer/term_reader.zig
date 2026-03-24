// Aeron term reader — scan forward from term buffer offset
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/logbuffer/TermReader.java

const std = @import("std");
const frame = @import("../protocol/frame.zig");

// LESSON(term-reader/zig): FragmentHandler is a typed function pointer that accepts header, payload, and a type-erased context.
// Callers cast their concrete state to *anyopaque; the callback casts back with @ptrCast + @alignCast. See docs/tutorial/02-data-path/02-term-reader.md
pub const FragmentHandler = *const fn (header: *const frame.DataHeader, buffer: []const u8, ctx: *anyopaque) void;

pub const ReadResult = struct {
    fragments_read: i32,
    offset: i32,
};

pub const TermReader = struct {
    /// Read frames forward from term buffer at given offset.
    /// - Scan forward from offset
    /// - Skip padding frames (type == .padding)
    /// - Call handler for DATA frames only
    /// - Stop when:
    ///   1. fragments_limit reached
    ///   2. frame_length <= 0 (no data committed yet)
    ///   3. reach end of term buffer
    /// - Return fragments_read count and next offset
    pub fn read(
        term: []const u8,
        offset: i32,
        handler: FragmentHandler,
        ctx: *anyopaque,
        fragments_limit: i32,
    ) ReadResult {
        var current_offset = offset;
        var fragments_read: i32 = 0;

        while (fragments_read < fragments_limit) {
            // Bounds check: can we read frame_length (i32)?
            const offset_usize = @as(usize, @intCast(current_offset));
            if (offset_usize + 4 > term.len) {
                break;
            }

            // LESSON(term-reader/aeron): frame_length is the commit signal. Appender writes it last with store-release semantics.
            // Reader sees either zero (not yet committed) or positive (complete frame). See docs/tutorial/02-data-path/02-term-reader.md
            // Read frame_length (i32, little-endian) at current_offset
            const frame_length_bytes = term[offset_usize .. offset_usize + 4];
            const frame_length = std.mem.readInt(i32, frame_length_bytes[0..4], .little);

            // If frame_length <= 0, we've reached the end of committed data
            if (frame_length <= 0) {
                break;
            }

            // Compute aligned length (pad to FRAME_ALIGNMENT)
            // LESSON(term-reader/zig): Alignment is computed at read time, not stored. Frames are always aligned, so we compute padding needed.
            // All operations use wrapping arithmetic for overflow safety. See docs/tutorial/02-data-path/02-term-reader.md
            const frame_len_u32 = @as(u32, @intCast(frame_length));
            const aligned_len_u32 = (frame_len_u32 + 31) & ~@as(u32, 31);
            const aligned_length = @as(i32, @intCast(aligned_len_u32));

            // Bounds check: can we read the entire aligned frame?
            if (offset_usize + @as(usize, @intCast(aligned_length)) > term.len) {
                break;
            }

            // Read type (u16, little-endian) at offset + 6
            if (offset_usize + 8 > term.len) {
                break;
            }
            const type_bytes = term[offset_usize + 6 .. offset_usize + 8];
            const frame_type_raw = std.mem.readInt(u16, type_bytes[0..2], .little);

            // LESSON(term-reader/aeron): Padding frames are written by appender at term end to signal rotation.
            // Reader skips them; they don't count toward fragments_limit. See docs/tutorial/02-data-path/02-term-reader.md
            // Check if this is a padding frame
            const is_padding = frame_type_raw == @intFromEnum(frame.FrameType.padding);

            if (!is_padding) {
                // This is a DATA frame (or other non-padding frame)
                // Call handler with DataHeader pointer and payload slice
                if (offset_usize + frame.DataHeader.LENGTH <= term.len) {
                    // LESSON(term-reader/zig): Header pointer requires @ptrCast + @alignCast because we read from an arbitrary slice offset.
                    // Alignment is guaranteed by the appender's 32-byte alignment, but the type system doesn't know that. See docs/tutorial/02-data-path/02-term-reader.md
                    const header_ptr = @as(*const frame.DataHeader, @ptrCast(@alignCast(&term[offset_usize])));

                    // Payload: from (current_offset + DataHeader.LENGTH) to (current_offset + frame_length)
                    const payload_start = offset_usize + frame.DataHeader.LENGTH;
                    const payload_length = @as(usize, @intCast(frame_length - @as(i32, @intCast(frame.DataHeader.LENGTH))));

                    if (payload_start + payload_length <= term.len) {
                        const payload_slice = term[payload_start .. payload_start + payload_length];
                        handler(header_ptr, payload_slice, ctx);
                    }
                }

                fragments_read += 1;
            }

            // Advance offset
            current_offset += aligned_length;
        }

        return .{
            .fragments_read = fragments_read,
            .offset = current_offset,
        };
    }
};

// ===== Unit Tests =====

test "read single data frame" {
    const allocator = std.testing.allocator;
    var term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    // Write a DataHeader + payload
    const test_payload_data = "hello";
    const frame_length: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(test_payload_data.len));
    const frame_len_u32 = @as(u32, @intCast(frame_length));
    const aligned_length = @as(i32, @intCast((frame_len_u32 + 31) & ~@as(u32, 31)));

    var frame_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame_buf[0..4], frame_length, .little);
    std.mem.writeInt(u8, frame_buf[4..5], 0, .little); // version
    std.mem.writeInt(u8, frame_buf[5..6], 0, .little); // flags
    std.mem.writeInt(u16, frame_buf[6..8], @intFromEnum(frame.FrameType.data), .little); // type = DATA
    std.mem.writeInt(i32, frame_buf[8..12], 0, .little); // term_offset
    std.mem.writeInt(i32, frame_buf[12..16], 1, .little); // session_id
    std.mem.writeInt(i32, frame_buf[16..20], 2, .little); // stream_id
    std.mem.writeInt(i32, frame_buf[20..24], 3, .little); // term_id
    std.mem.writeInt(i64, frame_buf[24..32], 0, .little); // reserved_value

    @memcpy(term[0..32], &frame_buf);
    @memcpy(term[32 .. 32 + test_payload_data.len], test_payload_data);

    var test_ctx = struct { called: bool = false, captured_payload: [32]u8 = undefined, captured_payload_len: usize = 0 }{};

    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const state_ptr = @as(*struct { called: bool, captured_payload: [32]u8, captured_payload_len: usize }, @ptrCast(@alignCast(ctx)));
            state_ptr.called = true;
            @memcpy(state_ptr.captured_payload[0..payload_in.len], payload_in);
            state_ptr.captured_payload_len = payload_in.len;
            _ = header;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_ctx, 10);

    try std.testing.expect(test_ctx.called);
    try std.testing.expectEqual(@as(i32, 1), result.fragments_read);
    try std.testing.expectEqual(aligned_length, result.offset);
    try std.testing.expectEqualSlices(u8, test_payload_data, test_ctx.captured_payload[0..test_ctx.captured_payload_len]);
}

test "read multiple frames" {
    const allocator = std.testing.allocator;
    var term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    // Frame 1: DATA with "frame1"
    const payload1_data = "frame1";
    const frame_length1: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload1_data.len));
    const frame_len1_u32 = @as(u32, @intCast(frame_length1));
    const aligned_length1 = @as(i32, @intCast((frame_len1_u32 + 31) & ~@as(u32, 31)));

    var frame1_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame1_buf[0..4], frame_length1, .little);
    std.mem.writeInt(u16, frame1_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
    @memcpy(term[0..32], &frame1_buf);
    @memcpy(term[32 .. 32 + payload1_data.len], payload1_data);

    // Frame 2: DATA with "frame2" at aligned offset
    const offset2: i32 = aligned_length1;
    const payload2_data = "frame2";
    const frame_length2: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(payload2_data.len));
    const frame_len2_u32 = @as(u32, @intCast(frame_length2));
    const aligned_length2 = @as(i32, @intCast((frame_len2_u32 + 31) & ~@as(u32, 31)));

    const offset2_usize = @as(usize, @intCast(offset2));
    var frame2_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame2_buf[0..4], frame_length2, .little);
    std.mem.writeInt(u16, frame2_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
    @memcpy(term[offset2_usize .. offset2_usize + 32], &frame2_buf);
    @memcpy(term[offset2_usize + 32 .. offset2_usize + 32 + payload2_data.len], payload2_data);

    var test_count: i32 = undefined;
    const handler = struct {
        fn handle(header: *const frame.DataHeader, payload_in: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            _ = header;
            _ = payload_in;
        }
    }.handle;

    const result = TermReader.read(term, 0, handler, &test_count, 10);

    try std.testing.expectEqual(@as(i32, 2), result.fragments_read);
    try std.testing.expectEqual(offset2 + aligned_length2, result.offset);
}

test "stop at fragments_limit" {
    const allocator = std.testing.allocator;
    var term = try allocator.alloc(u8, 512);
    defer allocator.free(term);
    @memset(term, 0);

    // Write 3 data frames
    const frame_length: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + 1;
    const frame_len_u32 = @as(u32, @intCast(frame_length));
    const aligned_length = @as(i32, @intCast((frame_len_u32 + 31) & ~@as(u32, 31)));

    var offset: i32 = 0;
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const offset_usize = @as(usize, @intCast(offset));
        var frame_buf: [32]u8 = undefined;
        std.mem.writeInt(i32, frame_buf[0..4], frame_length, .little);
        std.mem.writeInt(u16, frame_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
        @memcpy(term[offset_usize .. offset_usize + 32], &frame_buf);
        term[offset_usize + 32] = 'x';
        offset += aligned_length;
    }

    var test_count: i32 = undefined;
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
}

test "skip padding frames" {
    const allocator = std.testing.allocator;
    var term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    // Frame 1: PADDING
    const padding_length: i32 = 64;
    const padding_len_u32 = @as(u32, @intCast(padding_length));
    const aligned_padding = @as(i32, @intCast((padding_len_u32 + 31) & ~@as(u32, 31)));

    var padding_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, padding_buf[0..4], padding_length, .little);
    std.mem.writeInt(u16, padding_buf[6..8], @intFromEnum(frame.FrameType.padding), .little);
    @memcpy(term[0..32], &padding_buf);

    // Frame 2: DATA
    const data_payload_data = "data";
    const frame_length2: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + @as(i32, @intCast(data_payload_data.len));
    const frame_len2_u32 = @as(u32, @intCast(frame_length2));
    const aligned_length2 = @as(i32, @intCast((frame_len2_u32 + 31) & ~@as(u32, 31)));

    const offset2_usize = @as(usize, @intCast(aligned_padding));
    var frame2_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame2_buf[0..4], frame_length2, .little);
    std.mem.writeInt(u16, frame2_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
    @memcpy(term[offset2_usize .. offset2_usize + 32], &frame2_buf);
    @memcpy(term[offset2_usize + 32 .. offset2_usize + 32 + data_payload_data.len], data_payload_data);

    var test_count: i32 = undefined;
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
    try std.testing.expectEqual(aligned_padding + aligned_length2, result.offset);
}

test "stop at frame_length zero" {
    const allocator = std.testing.allocator;
    var term = try allocator.alloc(u8, 256);
    defer allocator.free(term);
    @memset(term, 0);

    // Write one data frame
    const frame_length: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH)) + 1;
    const frame_len_u32 = @as(u32, @intCast(frame_length));
    const aligned_length = @as(i32, @intCast((frame_len_u32 + 31) & ~@as(u32, 31)));

    var frame_buf: [32]u8 = undefined;
    std.mem.writeInt(i32, frame_buf[0..4], frame_length, .little);
    std.mem.writeInt(u16, frame_buf[6..8], @intFromEnum(frame.FrameType.data), .little);
    @memcpy(term[0..32], &frame_buf);
    term[32] = 'x';

    // Write a zero frame_length at aligned_length (signals end of committed data)
    const offset2_usize = @as(usize, @intCast(aligned_length));
    std.mem.writeInt(i32, term[offset2_usize .. offset2_usize + 4], 0, .little);

    var test_count: i32 = undefined;
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
    try std.testing.expectEqual(aligned_length, result.offset);
}
