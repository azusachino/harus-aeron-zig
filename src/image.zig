const std = @import("std");
const logbuffer = @import("logbuffer/log_buffer.zig");
const term_reader = @import("logbuffer/term_reader.zig");
const metadata = @import("logbuffer/metadata.zig");
const frame = @import("protocol/frame.zig");

pub const Image = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    term_length: i32,
    log_buffer: *logbuffer.LogBuffer,
    subscriber_position: i64,
    is_eos: bool,

    pub fn init(session_id: i32, stream_id: i32, initial_term_id: i32, log_buffer: *logbuffer.LogBuffer) Image {
        return .{
            .session_id = session_id,
            .stream_id = stream_id,
            .initial_term_id = initial_term_id,
            .term_length = log_buffer.term_length,
            .log_buffer = log_buffer,
            .subscriber_position = 0,
            .is_eos = false,
        };
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
