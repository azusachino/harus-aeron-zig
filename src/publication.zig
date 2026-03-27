const std = @import("std");
const logbuffer = @import("logbuffer/log_buffer.zig");
const term_appender = @import("logbuffer/term_appender.zig");
const frame = @import("protocol/frame.zig");
const metadata = @import("logbuffer/metadata.zig");
const counters = @import("ipc/counters.zig");

// LESSON(publications): Tagged union result type encodes expected operational states (back_pressure, not_connected) as values, not error codes. See docs/tutorial/04-client/01-publications.md
pub const OfferResult = union(enum) {
    ok: i64, // new stream position
    back_pressure, // publisher limit reached
    not_connected, // no active subscribers
    admin_action, // CAS retry needed
    closed,
    max_position_exceeded,
};

// LESSON(publications): publisher_limit is a flow-control ceiling set by Sender Agent; write succeeds only if current_position < publisher_limit. See docs/tutorial/04-client/01-publications.md
pub const ExclusivePublication = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    term_length: i32,
    mtu: i32,
    log_buffer: *logbuffer.LogBuffer,
    publisher_limit: i64, // max position allowed by flow control
    counters_map: ?*counters.CountersMap,
    publisher_limit_counter_id: i32,
    is_closed: bool,
    owns_log_buffer: bool,
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
            .publisher_limit = 0,
            .counters_map = null,
            .publisher_limit_counter_id = counters.NULL_COUNTER_ID,
            .is_closed = false,
            .owns_log_buffer = false,
            .appender = term_appender.TermAppender.init(term_buffer, term_id),
        };
    }

    pub fn attachPublisherLimitCounter(self: *ExclusivePublication, counters_map: *counters.CountersMap, counter_id: i32) void {
        self.counters_map = counters_map;
        self.publisher_limit_counter_id = counter_id;
        self.publisher_limit = counters_map.get(counter_id);
    }

    // LESSON(publications): A publication is not truly connected until a receiver STATUS
    // advances the shared publisher-limit counter. Client handles must read that live counter
    // from CnC.dat instead of assuming the ready response implies connectivity. See docs/tutorial/04-client/01-publications.md
    fn livePublisherLimit(self: *ExclusivePublication) i64 {
        if (self.counters_map) |cm| {
            self.publisher_limit = cm.get(self.publisher_limit_counter_id);
        }
        return self.publisher_limit;
    }

    // LESSON(publications): offer() reads volatile tail (term_id || offset), computes stream position, checks publisher_limit for back_pressure. See docs/tutorial/04-client/01-publications.md
    pub fn offer(self: *ExclusivePublication, data: []const u8) OfferResult {
        if (self.is_closed) return .closed;

        const raw_tail = self.appender.rawTailVolatile();
        const term_id = @as(i32, @intCast(raw_tail >> 32));
        const term_offset = @as(i32, @intCast(raw_tail & 0xFFFF_FFFF));
        const current_position = @as(i64, term_id - self.initial_term_id) * self.term_length + term_offset;
        const publisher_limit = self.livePublisherLimit();

        if (publisher_limit <= 0) {
            return .not_connected;
        }

        if (current_position >= publisher_limit) {
            return .back_pressure;
        }

        // LESSON(publications): Single-frame messages use BEGIN_FLAG | END_FLAG; multi-frame fragmentation uses BEGIN/no-flag/END across appends. See docs/tutorial/04-client/01-publications.md
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

    // LESSON(publications): Term-relative positioning: stream position is (term_id_delta * term_length) + offset_within_term. See docs/tutorial/04-client/01-publications.md
    pub fn position(self: *const ExclusivePublication) i64 {
        const raw_tail = self.appender.rawTailVolatile();
        const term_id = @as(i32, @intCast(raw_tail >> 32));
        const term_offset = @as(i32, @intCast(raw_tail & 0xFFFF_FFFF));
        return @as(i64, term_id - self.initial_term_id) * self.term_length + term_offset;
    }

    pub fn isConnected(self: *const ExclusivePublication) bool {
        return self.log_buffer.metaData().isConnected();
    }

    pub fn close(self: *ExclusivePublication) void {
        self.is_closed = true;
    }

    pub fn deinit(self: *ExclusivePublication, allocator: std.mem.Allocator) void {
        if (self.owns_log_buffer) {
            self.log_buffer.deinit();
            allocator.destroy(self.log_buffer);
        }
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
    pub_instance.publisher_limit = 64 * 1024;
    const result = pub_instance.offer("hello");
    try std.testing.expect(result == .ok);
}

test "offer: returns not_connected until publisher limit counter advances" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const pub_limit = counters_map.allocate(counters.PUBLISHER_LIMIT, "pub-limit");

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var pub_instance = ExclusivePublication.init(1, 1001, 0, 64 * 1024, 1408, &log_buf);
    pub_instance.attachPublisherLimitCounter(&counters_map, pub_limit.counter_id);

    try std.testing.expect(!pub_instance.isConnected());
    try std.testing.expect(pub_instance.offer("hello") == .not_connected);

    counters_map.set(pub_limit.counter_id, 64 * 1024);
    var meta_data = log_buf.metaData();
    meta_data.setIsConnected(true);
    try std.testing.expect(pub_instance.isConnected());
    try std.testing.expect(pub_instance.offer("hello") == .ok);
}
