const std = @import("std");
const logbuffer = @import("logbuffer/log_buffer.zig");
const term_appender = @import("logbuffer/term_appender.zig");
const frame = @import("protocol/frame.zig");
const metadata = @import("logbuffer/metadata.zig");
const agrona = @import("agrona");
const counters = agrona.counters;

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
        var meta = log_buffer.metaData();
        const active_term_count = meta.activeTermCount();
        const partition = metadata.activePartitionIndex(active_term_count);
        const term_buffer = log_buffer.termBuffer(partition);
        const term_id = initial_term_id + active_term_count;

        // Get pointer to raw_tail slot in metadata for this partition
        const raw_tail_offset = metadata.TERM_TAIL_COUNTERS_OFFSET + (partition * @sizeOf(i64));
        const raw_tail_ptr: *i64 = @ptrCast(@alignCast(&meta.buffer[raw_tail_offset]));

        // Initialize metadata with the starting term_id (offset starts at 0)
        meta.setRawTailVolatile(partition, term_appender.TermAppender.packTail(term_id, 0));

        var appender = term_appender.TermAppender.init(term_buffer, raw_tail_ptr);
        appender.setPaddingIdentity(session_id, stream_id);

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
            .appender = appender,
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

    // LESSON(publications): A term boundary is completed with padding, then the next ring partition is initialized and published through activeTermCount. See docs/tutorial/04-client/01-publications.md
    fn rotateTerm(self: *ExclusivePublication, term_id: i32, active_term_count: i32) OfferResult {
        var meta = self.log_buffer.metaData();
        const current_partition = metadata.activePartitionIndex(active_term_count);
        const current_raw_tail = meta.rawTailVolatile(current_partition);
        const current_offset = metadata.termOffset(current_raw_tail, self.term_length);

        if (current_offset < self.term_length) {
            const current_buffer = self.log_buffer.termBuffer(current_partition);
            const current_tail_offset = metadata.TERM_TAIL_COUNTERS_OFFSET + (current_partition * @sizeOf(i64));
            const current_tail_ptr: *i64 = @ptrCast(@alignCast(&meta.buffer[current_tail_offset]));
            var current_appender = term_appender.TermAppender.init(current_buffer, current_tail_ptr);
            current_appender.setPaddingIdentity(self.session_id, self.stream_id);
            switch (current_appender.appendPadding(0)) {
                .padding_applied => {},
                .admin_action => return .admin_action,
                .tripped => return .admin_action,
                .ok => return .admin_action,
            }
        }

        const next_term_count = active_term_count + 1;
        const next_partition = metadata.activePartitionIndex(next_term_count);
        const next_term_id = term_id +% 1;
        meta.setRawTailVolatile(next_partition, term_appender.TermAppender.packTail(next_term_id, 0));
        meta.setActiveTermCount(next_term_count);

        const next_buffer = self.log_buffer.termBuffer(next_partition);
        const next_tail_offset = metadata.TERM_TAIL_COUNTERS_OFFSET + (next_partition * @sizeOf(i64));
        const next_tail_ptr: *i64 = @ptrCast(@alignCast(&meta.buffer[next_tail_offset]));
        self.appender = term_appender.TermAppender.init(next_buffer, next_tail_ptr);
        self.appender.setPaddingIdentity(self.session_id, self.stream_id);
        return .admin_action;
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

        if (term_offset >= self.term_length) {
            return self.rotateTerm(term_id, self.log_buffer.metaData().activeTermCount());
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
            .tripped => self.rotateTerm(term_id, self.log_buffer.metaData().activeTermCount()),
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

    /// Read the current live flow-control ceiling for diagnostics and pacing.
    pub fn publisherLimit(self: *ExclusivePublication) i64 {
        return self.livePublisherLimit();
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
    const expected_unaligned_len = @as(i32, @intCast(frame.DataHeader.LENGTH + test_payload.len));
    try std.testing.expectEqual(expected_unaligned_len, frame_length);
    try std.testing.expectEqualSlices(u8, test_payload, term0[frame.DataHeader.LENGTH .. frame.DataHeader.LENGTH + test_payload.len]);
}

test "ExclusivePublication rotates after term is full" {
    const allocator = std.testing.allocator;
    const term_length = 64 * 1024;
    var log_buf = try logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();

    var pub_instance = ExclusivePublication.init(1, 2, 100, term_length, 1408, &log_buf);
    pub_instance.publisher_limit = 1024 * 1024;

    const payload = [_]u8{'x'} ** 1000;
    var saw_rotation = false;
    var offers: usize = 0;
    while (offers < 100) : (offers += 1) {
        switch (pub_instance.offer(&payload)) {
            .ok => {},
            .admin_action => {
                saw_rotation = true;
                offers -= 1;
            },
            else => return error.UnexpectedResult,
        }
    }

    try std.testing.expect(saw_rotation);
    try std.testing.expectEqual(@as(i32, 1), log_buf.metaData().activeTermCount());
    try std.testing.expectEqual(@as(i32, 101), metadata.termId(log_buf.metaData().rawTailVolatile(1)));
    try std.testing.expect(metadata.termOffset(log_buf.metaData().rawTailVolatile(1), term_length) > 0);
    const next_term_header = @as(*const frame.DataHeader, @ptrCast(@alignCast(&log_buf.termBuffer(1)[0])));
    try std.testing.expectEqual(@as(i32, 101), next_term_header.term_id);
    try std.testing.expectEqual(@as(i32, 0), next_term_header.term_offset);
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
