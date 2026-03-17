// Aeron log buffer — three-term ring structure backed by mmap
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java
const std = @import("std");

pub const PARTITION_COUNT = 3;
pub const LOG_META_DATA_SECTION_INDEX = PARTITION_COUNT;
pub const TERM_MIN_LENGTH: i32 = 64 * 1024; // 64KB minimum
pub const TERM_MAX_LENGTH: i32 = 1024 * 1024 * 1024; // 1GB maximum

pub const LogBuffer = struct {
    // TODO: implement term buffers (mmap-backed slices)
    // TODO: implement metadata section
    // TODO: implement active term rotation
};

test "partition count" {
    try std.testing.expectEqual(3, PARTITION_COUNT);
}
