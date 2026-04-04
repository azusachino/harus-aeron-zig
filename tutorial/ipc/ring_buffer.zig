// EXERCISE: Chapter 1.2 — Many-to-One Ring Buffer
// Reference: docs/tutorial/01-foundations/02-ring-buffer.md
//
// Your task: implement `write` and `read`.
// The metadata layout and RecordDescriptor are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const INSUFFICIENT_CAPACITY: i32 = -1;
pub const PADDING_MSG_TYPE_ID: i32 = -1;

// Metadata positions (last 768 bytes of buffer)
pub const TAIL_POSITION_OFFSET: usize = 0;
pub const HEAD_CACHE_POSITION_OFFSET: usize = 128;
pub const HEAD_POSITION_OFFSET: usize = 256;
pub const CORRELATION_COUNTER_OFFSET: usize = 384;
pub const METADATA_LENGTH: usize = 768;

pub const RecordDescriptor = struct {
    pub const ALIGNMENT = 8;
    pub const HEADER_LENGTH = 8; // type(4) + length(4)

    pub fn aligned(length: usize) usize {
        return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
    }
};

pub const MessageHandler = *const fn (msg_type_id: i32, data: []const u8, ctx: *anyopaque) void;

pub const ManyToOneRingBuffer = struct {
    buffer: []u8,
    capacity: usize,

    pub fn init(buf: []u8) ManyToOneRingBuffer {
        return .{
            .buffer = buf,
            .capacity = buf.len - METADATA_LENGTH,
        };
    }

    /// Write a message into the ring buffer.
    /// Claims space using atomic CAS on the tail.
    /// Returns true on success, false if buffer is full.
    pub fn write(self: *ManyToOneRingBuffer, msg_type_id: i32, data: []const u8) bool {
        _ = self;
        _ = msg_type_id;
        _ = data;
        @panic("TODO: implement ManyToOneRingBuffer.write");
    }

    /// Read up to `limit` messages from the ring buffer.
    /// Advances the head cursor.
    /// Returns the number of messages read.
    pub fn read(self: *ManyToOneRingBuffer, handler: MessageHandler, ctx: *anyopaque, limit: i32) i32 {
        _ = self;
        _ = handler;
        _ = ctx;
        _ = limit;
        @panic("TODO: implement ManyToOneRingBuffer.read");
    }

    pub fn nextCorrelationId(self: *ManyToOneRingBuffer) i64 {
        const addr = self.buffer.ptr + self.capacity + CORRELATION_COUNTER_OFFSET;
        const current = @atomicRmw(i64, @as(*i64, @ptrCast(@alignCast(addr))), .Add, 1, .acq_rel);
        return current + 1;
    }
};

test "ManyToOneRingBuffer write and read" {
    // const buf = try std.testing.allocator.alloc(u8, 1024);
    // defer std.testing.allocator.free(buf);
    // @memset(buf, 0);
    // var rb = ManyToOneRingBuffer.init(buf);
    // try std.testing.expect(rb.write(1, "hello"));
}
