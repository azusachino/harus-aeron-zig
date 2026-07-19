const std = @import("std");
const logbuffer = @import("logbuffer/log_buffer.zig");
const term_reader = @import("logbuffer/term_reader.zig");
const metadata = @import("logbuffer/metadata.zig");
const frame = @import("protocol/frame.zig");
const counters = @import("agrona").counters;

pub const Image = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    term_length: i32,
    log_buffer: *logbuffer.LogBuffer,
    subscriber_position: i64,
    subscriber_position_counter: ?*counters.CountersMap,
    subscriber_position_counter_id: i32,
    is_eos: bool,
    owns_log_buffer: bool = false,

    pub fn init(session_id: i32, stream_id: i32, initial_term_id: i32, log_buffer: *logbuffer.LogBuffer) Image {
        return .{
            .session_id = session_id,
            .stream_id = stream_id,
            .initial_term_id = initial_term_id,
            .term_length = log_buffer.term_length,
            .log_buffer = log_buffer,
            .subscriber_position = 0,
            .subscriber_position_counter = null,
            .subscriber_position_counter_id = counters.NULL_COUNTER_ID,
            .is_eos = false,
            .owns_log_buffer = false,
        };
    }

    // The client publishes its consumed position through the counter advertised
    // by IMAGE_READY so the driver can apply authentic subscriber flow control.
    pub fn setSubscriberPositionCounter(self: *Image, counters_map: *counters.CountersMap, counter_id: i32) void {
        self.subscriber_position_counter = counters_map;
        self.subscriber_position_counter_id = counter_id;
        counters_map.set(counter_id, self.subscriber_position);
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        if (self.owns_log_buffer) {
            self.log_buffer.deinit();
            allocator.destroy(self.log_buffer);
        }
    }

    pub fn poll(self: *Image, handler: term_reader.FragmentHandler, ctx: *anyopaque, fragment_limit: i32) i32 {
        // Compute partition from subscriber_position and initial_term_id, not log metadata
        // (the receiver writes frames by term_id but never updates activeTermCount in metadata)
        const term_count: usize = @intCast(@divTrunc(self.subscriber_position, @as(i64, self.term_length)));
        const partition = @mod(term_count, metadata.PARTITION_COUNT);
        const term_buffer = self.log_buffer.termBuffer(partition);

        const term_offset = @as(i32, @intCast(@mod(self.subscriber_position, @as(i64, self.term_length))));

        const result = term_reader.TermReader.read(term_buffer, term_offset, handler, ctx, fragment_limit);

        const read_bytes = result.offset - term_offset;
        self.subscriber_position += read_bytes;
        if (self.subscriber_position_counter) |counters_map| {
            counters_map.set(self.subscriber_position_counter_id, self.subscriber_position);
        }

        return result.fragments_read;
    }

    pub fn position(self: *const Image) i64 {
        return self.subscriber_position;
    }

    pub fn isEndOfStream(self: *const Image) bool {
        return self.is_eos;
    }

    pub fn close(self: *Image) void {
        // In a real implementation this might involve notifying the conductor
        _ = self;
    }
};

test "Image poll reads from term buffer" {
    const allocator = std.testing.allocator;
    const term_length = 64 * 1024;
    var log_buf = try logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();

    var image = Image.init(1, 2, 100, &log_buf);

    const test_payload = "hello world";
    const frame_length: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH + test_payload.len));
    const aligned_length = std.mem.alignForward(usize, @as(usize, @intCast(frame_length)), frame.FRAME_ALIGNMENT);

    // Prepare a frame in term 0
    const term0 = log_buf.termBuffer(0);
    std.mem.writeInt(i32, term0[0..4], frame_length, .little);
    term0[6] = @intFromEnum(frame.FrameType.data) & 0xFF;
    term0[7] = (@intFromEnum(frame.FrameType.data) >> 8) & 0xFF;
    @memcpy(term0[frame.DataHeader.LENGTH .. frame.DataHeader.LENGTH + test_payload.len], test_payload);

    var context = struct {
        received: bool = false,
    }{};

    const handler = struct {
        fn handle(_: *const frame.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const c = @as(*@TypeOf(context), @ptrCast(@alignCast(ctx)));
            c.received = true;
        }
    }.handle;

    const fragments = image.poll(handler, &context, 10);

    try std.testing.expectEqual(@as(i32, 1), fragments);
    try std.testing.expect(context.received);
    try std.testing.expectEqual(@as(i64, @intCast(aligned_length)), image.position());
}

test "Image poll publishes the client-owned subscriber position" {
    const allocator = std.testing.allocator;
    var meta: [counters.METADATA_LENGTH * 4]u8 = undefined;
    var values: [counters.COUNTER_LENGTH * 4]u8 = undefined;
    @memset(&meta, 0);
    @memset(&values, 0);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const position_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "image-position");

    const term_length = 64 * 1024;
    var log_buf = try logbuffer.LogBuffer.init(allocator, term_length);
    defer log_buf.deinit();
    var image = Image.init(1, 2, 100, &log_buf);
    image.setSubscriberPositionCounter(&counters_map, position_handle.counter_id);

    const payload = "position";
    const frame_length: i32 = @as(i32, @intCast(frame.DataHeader.LENGTH + payload.len));
    const term0 = log_buf.termBuffer(0);
    std.mem.writeInt(i32, term0[0..4], frame_length, .little);
    std.mem.writeInt(u16, term0[6..8], @intFromEnum(frame.FrameType.data), .little);
    @memcpy(term0[frame.DataHeader.LENGTH .. frame.DataHeader.LENGTH + payload.len], payload);

    const handler = struct {
        fn handle(_: *const frame.DataHeader, _: []const u8, _: *anyopaque) void {}
    }.handle;
    _ = image.poll(handler, undefined, 1);

    try std.testing.expectEqual(image.position(), counters_map.get(position_handle.counter_id));
}
