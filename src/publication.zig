const std = @import("std");
const logbuffer = @import("logbuffer/log_buffer.zig");
const term_appender = @import("logbuffer/term_appender.zig");
const frame = @import("protocol/frame.zig");
const metadata = @import("logbuffer/metadata.zig");

pub const OfferResult = union(enum) {
    ok: i64, // new stream position
    back_pressure, // publisher limit reached
    not_connected, // no active subscribers
    admin_action, // CAS retry needed
    closed,
    max_position_exceeded,
};

pub const ExclusivePublication = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    term_length: i32,
    mtu: i32,
    log_buffer: *logbuffer.LogBuffer,
    publisher_limit: i64, // max position allowed by flow control
    is_closed: bool,
    appender: term_appender.TermAppender,

    pub fn init(
        session_id: i32,
        stream_id: i32,
        initial_term_id: i32,
        term_length: i32,
        mtu: i32,
        log_buffer: *logbuffer.LogBuffer,
    ) ExclusivePublication {
        const meta = log_buffer.metaData();
        const active_term_count = meta.activeTermCount();
        const partition = metadata.activePartitionIndex(active_term_count);
        const term_buffer = log_buffer.termBuffer(partition);
        const term_id = initial_term_id + active_term_count;

        return .{
            .session_id = session_id,
            .stream_id = stream_id,
            .initial_term_id = initial_term_id,
            .term_length = term_length,
            .mtu = mtu,
            .log_buffer = log_buffer,
            .publisher_limit = @as(i64, term_length),
            .is_closed = false,
            .appender = term_appender.TermAppender.init(term_buffer, term_id),
        };
    }

    pub fn offer(self: *ExclusivePublication, data: []const u8) OfferResult {
        if (self.is_closed) return .closed;

        const raw_tail = self.appender.rawTailVolatile();
        const term_id = @as(i32, @intCast(raw_tail >> 32));
        const term_offset = @as(i32, @intCast(raw_tail & 0xFFFF_FFFF));
        const current_position = @as(i64, term_id - self.initial_term_id) * self.term_length + term_offset;

        if (current_position >= self.publisher_limit) {
            return .back_pressure;
        }

        var header: frame.DataHeader = undefined;
        header.version = frame.VERSION;
        header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
        header.type = @intFromEnum(frame.FrameType.data);
        header.term_offset = term_offset;
        header.session_id = self.session_id;
        header.stream_id = self.stream_id;
        header.term_id = term_id;
        header.reserved_value = 0;

        const result = self.appender.appendData(&header, data);

        return switch (result) {
            .ok => |offset| {
                const total_len = frame.DataHeader.LENGTH + data.len;
                const aligned_len = std.mem.alignForward(usize, total_len, frame.FRAME_ALIGNMENT);
                const new_position = @as(i64, term_id - self.initial_term_id) * self.term_length + offset + @as(i64, @intCast(aligned_len));
                return .{ .ok = new_position };
            },
            .tripped => .back_pressure,
            .admin_action => .admin_action,
            .padding_applied => .admin_action,
        };
    }

    pub fn position(self: *const ExclusivePublication) i64 {
        const raw_tail = self.appender.rawTailVolatile();
        const term_id = @as(i32, @intCast(raw_tail >> 32));
        const term_offset = @as(i32, @intCast(raw_tail & 0xFFFF_FFFF));
        return @as(i64, term_id - self.initial_term_id) * self.term_length + term_offset;
    }

    pub fn isConnected(self: *const ExclusivePublication) bool {
        return self.publisher_limit > 0;
    }

    pub fn close(self: *ExclusivePublication) void {
        self.is_closed = true;
    }
};

test "ExclusivePublication offer writes to log buffer" {
    const allocator = std.testing.allocator;
    const term_length = 64 * 1024;
    var log_buf = try logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();

    var pub_instance = ExclusivePublication.init(1, 2, 100, term_length, 1408, &log_buf);
    pub_instance.publisher_limit = 1024 * 1024;

    const test_payload = "hello world";
    const result = pub_instance.offer(test_payload);

    switch (result) {
        .ok => |pos| {
            const expected_len = std.mem.alignForward(usize, frame.DataHeader.LENGTH + test_payload.len, frame.FRAME_ALIGNMENT);
            try std.testing.expectEqual(@as(i64, @intCast(expected_len)), pos);
        },
        else => return error.UnexpectedResult,
    }

    // Verify data in log buffer
    const term0 = log_buf.termBuffer(0);
    const frame_length = std.mem.readInt(i32, term0[0..4], .little);
    const expected_aligned_len = std.mem.alignForward(i32, @as(i32, @intCast(frame.DataHeader.LENGTH + test_payload.len)), frame.FRAME_ALIGNMENT);
    try std.testing.expectEqual(expected_aligned_len, frame_length);
    try std.testing.expectEqualSlices(u8, test_payload, term0[frame.DataHeader.LENGTH .. frame.DataHeader.LENGTH + test_payload.len]);
}

test "offer: first message succeeds when publisher_limit equals term_length" {
    const allocator = std.testing.allocator;
    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var pub_instance = ExclusivePublication.init(1, 1001, 0, 64 * 1024, 1408, &log_buf);
    const result = pub_instance.offer("hello");
    try std.testing.expect(result == .ok);
}
