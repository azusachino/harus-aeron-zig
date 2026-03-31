// Term appender — lock-free append to a single term partition
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/logbuffer/TermAppender.java
const std = @import("std");
const frame = @import("../protocol/frame.zig");

pub const AppendResult = union(enum) {
    ok: i32, // term_offset where data was written
    tripped, // term is full, rotation needed
    admin_action, // CAS failure, caller should retry
    padding_applied, // padding frame written at end, retry in next term
};

pub const TermAppender = struct {
    term_buffer: []u8,
    term_length: i32,
    raw_tail: *i64, // pointer to packed tail in shared mmap metadata

    /// Initialize a TermAppender with a buffer and pointer to raw_tail in metadata.
    pub fn init(term_buffer: []u8, raw_tail_ptr: *i64) TermAppender {
        return .{
            .term_buffer = term_buffer,
            .term_length = @as(i32, @intCast(term_buffer.len)),
            .raw_tail = raw_tail_ptr,
        };
    }

    /// Pack term_id and term_offset into a 64-bit value: high 32 = term_id, low 32 = offset.
    pub fn packTail(term_id: i32, term_offset: i32) i64 {
        // LESSON(term-appender): Packing two signed i32 values into one i64 requires careful bitwise handling.
        // We cast term_offset to u32 first to preserve bit patterns, then shift and OR. See docs/tutorial/02-data-path/01-term-appender.md
        return (@as(i64, term_id) << 32) | @as(i64, @as(u32, @bitCast(term_offset)));
    }

    /// Load raw_tail atomically with acquire semantics.
    pub fn rawTailVolatile(self: *const TermAppender) i64 {
        // LESSON(term-appender): @atomicLoad with .acquire ensures we see all writes by the appender thread
        // before the load returns. This pairs with .acq_rel on the CAS to enforce happens-before. See docs/tutorial/02-data-path/01-term-appender.md
        return @atomicLoad(i64, self.raw_tail, .acquire);
    }

    /// Append a data frame (header + payload) to the current term.
    /// Returns the term_offset where the frame was written, or an error.
    pub fn appendData(
        self: *TermAppender,
        header: *const frame.DataHeader,
        payload: []const u8,
    ) AppendResult {
        // 1. Compute aligned frame length: header + payload, aligned to 32 bytes
        const total_len = frame.DataHeader.LENGTH + payload.len;
        const aligned_len = std.mem.alignForward(usize, total_len, frame.FRAME_ALIGNMENT);
        const aligned_len_i32 = @as(i32, @intCast(aligned_len));

        // 2. Load raw_tail atomically
        const current_raw_tail = @atomicLoad(i64, self.raw_tail, .acquire);

        // 3. Extract current term_offset from low 32 bits
        const current_offset = @as(i32, @intCast(current_raw_tail & 0xFFFF_FFFF));
        const current_term_id = @as(i32, @intCast(current_raw_tail >> 32));

        // 4. Check if append would exceed term_length
        if (current_offset +% aligned_len_i32 > self.term_length) {
            return .tripped;
        }

        // 5. CAS raw_tail to advance by aligned_len
        // LESSON(term-appender): Atomic CAS atomically reserves a byte range and publishes the term_id+offset pair.
        // Multiple publishers race here; losers return .admin_action so the caller retries from the new tail. See docs/tutorial/02-data-path/01-term-appender.md
        const new_raw_tail = packTail(current_term_id, current_offset +% aligned_len_i32);
        const cas_result = @cmpxchgStrong(i64, self.raw_tail, current_raw_tail, new_raw_tail, .acq_rel, .acquire);

        if (cas_result != null) {
            return .admin_action;
        }

        // 6. Write header and payload to buffer at current_offset
        // LESSON(term-appender): After CAS succeeds, we own [current_offset, current_offset+aligned_len).
        // Conversion from slice index to pointer uses @ptrCast + @alignCast; the slice points to aligned buffer. See docs/tutorial/02-data-path/01-term-appender.md
        const frame_offset = @as(usize, @intCast(current_offset));

        // Write header fields (except frame_length, which is the commit signal)
        const header_ptr: *frame.DataHeader = @ptrCast(@alignCast(&self.term_buffer[frame_offset]));
        header_ptr.version = header.version;
        header_ptr.flags = header.flags;
        header_ptr.type = header.type;
        header_ptr.term_offset = header.term_offset;
        header_ptr.session_id = header.session_id;
        header_ptr.stream_id = header.stream_id;
        header_ptr.term_id = header.term_id;
        header_ptr.reserved_value = header.reserved_value;

        // 7. Copy payload after header
        if (payload.len > 0) {
            const payload_offset = frame_offset + frame.DataHeader.LENGTH;
            @memcpy(
                self.term_buffer[payload_offset .. payload_offset + payload.len],
                payload,
            );
        }

        // 8. COMMIT: atomic store-release of frame_length (unaligned total_len, not aligned_len).
        // This is the commit signal to readers; store-release ensures payload writes are visible first.
        const frame_len_ptr: *i32 = @ptrCast(@alignCast(&self.term_buffer[frame_offset]));
        @atomicStore(i32, frame_len_ptr, @as(i32, @intCast(total_len)), .release);

        // 9. Return the term_offset where this frame was written
        return .{ .ok = current_offset };
    }

    /// Write a padding frame at the current tail to fill to end of term.
    /// Returns .padding_applied on success.
    pub fn appendPadding(self: *TermAppender, _length: i32) AppendResult {
        _ = _length;

        // Load current raw_tail
        const current_raw_tail = @atomicLoad(i64, self.raw_tail, .acquire);

        // Extract current offset and term_id
        const current_offset = @as(i32, @intCast(current_raw_tail & 0xFFFF_FFFF));
        const current_term_id = @as(i32, @intCast(current_raw_tail >> 32));

        // Compute padding length (from current_offset to term_length, aligned)
        const padding_len: i32 = self.term_length - current_offset;

        // If no room for padding header, return tripped
        if (padding_len < @as(i32, @intCast(frame.DataHeader.LENGTH))) {
            return .tripped;
        }

        // CAS to advance raw_tail to term_length
        // LESSON(term-appender): Padding frame marks end of term and triggers rotation. See docs/tutorial/02-data-path/01-term-appender.md
        // Publisher writes padding when next append would exceed term_length, signaling subscribers to rotate to next partition. See docs/tutorial/02-data-path/01-term-appender.md
        const new_raw_tail = packTail(current_term_id, self.term_length);
        const cas_result = @cmpxchgStrong(i64, self.raw_tail, current_raw_tail, new_raw_tail, .acq_rel, .acquire);

        if (cas_result != null) {
            return .admin_action;
        }

        // Write padding header at current_offset (except frame_length, which is the commit signal)
        const frame_offset = @as(usize, @intCast(current_offset));
        const padding_header: *frame.DataHeader = @ptrCast(@alignCast(&self.term_buffer[frame_offset]));

        padding_header.version = frame.VERSION;
        padding_header.flags = frame.DataHeader.PADDING_FLAG;
        padding_header.type = @intFromEnum(frame.FrameType.padding);
        padding_header.term_offset = current_offset;
        padding_header.session_id = 0;
        padding_header.stream_id = 0;
        padding_header.term_id = current_term_id;
        padding_header.reserved_value = 0;

        // COMMIT: atomic store-release of frame_length (padding_len).
        // This is the commit signal to readers; store-release ensures header writes are visible first.
        const frame_len_ptr: *i32 = @ptrCast(@alignCast(&self.term_buffer[frame_offset]));
        @atomicStore(i32, frame_len_ptr, padding_len, .release);

        return .padding_applied;
    }
};

test "TermAppender single append returns ok at offset 0" {
    const allocator = std.testing.allocator;
    const term_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(5, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.frame_length = 0; // Will be set by append
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

    try std.testing.expectEqual(@as(i32, 0), result.ok);
}

test "TermAppender multiple appends advance offset correctly" {
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

    const payload2 = "second";
    header.term_offset = 64; // Next aligned position after first frame
    const result2 = appender.appendData(&header, payload2);
    try std.testing.expectEqual(@as(i32, 64), result2.ok);
}

test "TermAppender append that would exceed term_length returns tripped" {
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

    // Create a very large payload that won't fit
    const large_payload = try allocator.alloc(u8, 200);
    defer allocator.free(large_payload);

    const result = appender.appendData(&header, large_payload);
    try std.testing.expectEqual(AppendResult.tripped, result);
}

test "TermAppender packTail and extraction round-trip" {
    const term_id = @as(i32, 42);
    const term_offset = @as(i32, 12345);

    const packed_tail = TermAppender.packTail(term_id, term_offset);

    const extracted_term_id = @as(i32, @intCast(packed_tail >> 32));
    const extracted_offset = @as(i32, @intCast(packed_tail & 0xFFFF_FFFF));

    try std.testing.expectEqual(term_id, extracted_term_id);
    try std.testing.expectEqual(term_offset, extracted_offset);
}

test "TermAppender appendPadding fills to end of term" {
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
    header.term_offset = 0;

    // Append some data first
    const result1 = appender.appendData(&header, "test");
    try std.testing.expectEqual(@as(i32, 0), result1.ok);

    // Now append padding
    const result2 = appender.appendPadding(0);
    try std.testing.expectEqual(AppendResult.padding_applied, result2);
}
