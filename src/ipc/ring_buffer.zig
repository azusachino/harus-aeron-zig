// Lock-free many-to-one ring buffer for client→driver IPC
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java
const std = @import("std");

pub const INSUFFICIENT_CAPACITY: i32 = -1;
pub const PADDING_MSG_TYPE_ID: i32 = -1;

pub const RecordDescriptor = struct {
    pub const ALIGNMENT = 8;
    pub const HEADER_LENGTH = 8; // type(4) + length(4)

    pub fn aligned(length: usize) usize {
        return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
    }
};

pub const ManyToOneRingBuffer = struct {
    buffer: []u8,

    // TODO: implement write/read with atomic tail/head
    // TODO: implement padding record insertion on wrap
};

test "record alignment" {
    try std.testing.expectEqual(16, RecordDescriptor.aligned(5));
    try std.testing.expectEqual(16, RecordDescriptor.aligned(8));
}
