// Log buffer metadata descriptor.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java
const std = @import("std");

pub const PARTITION_COUNT: usize = 3;
pub const TERM_MIN_LENGTH: i32 = 64 * 1024;
pub const TERM_MAX_LENGTH: i32 = 1024 * 1024 * 1024;
pub const TERM_TAIL_COUNTERS_OFFSET: usize = 0;
pub const LOG_ACTIVE_TERM_COUNT_OFFSET: usize = TERM_TAIL_COUNTERS_OFFSET + (PARTITION_COUNT * @sizeOf(i64));
pub const CACHE_LINE_LENGTH: usize = 64;
pub const LOG_END_OF_STREAM_POSITION_OFFSET: usize = CACHE_LINE_LENGTH * 2;
pub const LOG_IS_CONNECTED_OFFSET: usize = LOG_END_OF_STREAM_POSITION_OFFSET + @sizeOf(i64);
pub const LOG_ACTIVE_TRANSPORT_COUNT_OFFSET: usize = LOG_IS_CONNECTED_OFFSET + @sizeOf(i32);

// Metadata length: align to 4096 (page boundary)
// Need: 3 * i64 (tail counters) + 1 * i32 (active term count) + padding
pub const LOG_META_DATA_LENGTH: usize = 4096;

pub const LogBufferMetadata = struct {
    buffer: []u8,

    pub fn activeTermCount(self: *const LogBufferMetadata) i32 {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TERM_COUNT_OFFSET]));
        return @atomicLoad(i32, ptr, .acquire);
    }

    pub fn setActiveTermCount(self: *LogBufferMetadata, val: i32) void {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TERM_COUNT_OFFSET]));
        @atomicStore(i32, ptr, val, .release);
    }

    pub fn rawTailVolatile(self: *const LogBufferMetadata, partition: usize) i64 {
        if (partition >= PARTITION_COUNT) return 0;
        const offset = TERM_TAIL_COUNTERS_OFFSET + (partition * @sizeOf(i64));
        const ptr: *i64 = @ptrCast(@alignCast(&self.buffer[offset]));
        return @atomicLoad(i64, ptr, .acquire);
    }

    pub fn setRawTailVolatile(self: *LogBufferMetadata, partition: usize, val: i64) void {
        if (partition >= PARTITION_COUNT) return;
        const offset = TERM_TAIL_COUNTERS_OFFSET + (partition * @sizeOf(i64));
        const ptr: *i64 = @ptrCast(@alignCast(&self.buffer[offset]));
        @atomicStore(i64, ptr, val, .release);
    }

    pub fn isConnected(self: *const LogBufferMetadata) bool {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_IS_CONNECTED_OFFSET]));
        return @atomicLoad(i32, ptr, .acquire) == 1;
    }

    pub fn setIsConnected(self: *LogBufferMetadata, connected: bool) void {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_IS_CONNECTED_OFFSET]));
        @atomicStore(i32, ptr, if (connected) 1 else 0, .release);
    }

    pub fn activeTransportCount(self: *const LogBufferMetadata) i32 {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TRANSPORT_COUNT_OFFSET]));
        return @atomicLoad(i32, ptr, .acquire);
    }

    pub fn setActiveTransportCount(self: *LogBufferMetadata, val: i32) void {
        const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TRANSPORT_COUNT_OFFSET]));
        @atomicStore(i32, ptr, val, .release);
    }
};

pub fn termId(raw_tail: i64) i32 {
    return @as(i32, @intCast(raw_tail >> 32));
}

pub fn termOffset(raw_tail: i64, term_length: i32) i32 {
    return @min(@as(i32, @intCast(raw_tail & 0xFFFF_FFFF)), term_length);
}

pub fn activePartitionIndex(term_count: i32) usize {
    return @as(usize, @intCast(@abs(term_count))) % PARTITION_COUNT;
}

pub fn nextPartitionIndex(current: usize) usize {
    return (current + 1) % PARTITION_COUNT;
}

test "termId extracts high 32 bits" {
    const raw: i64 = (@as(i64, 5) << 32) | 1234;
    try std.testing.expectEqual(@as(i32, 5), termId(raw));
}

test "termOffset extracts low 32 bits" {
    const raw: i64 = (@as(i64, 5) << 32) | 4567;
    try std.testing.expectEqual(@as(i32, 4567), termOffset(raw, 65536));
}

test "termOffset clamps to term length" {
    const raw: i64 = (@as(i64, 5) << 32) | 100000;
    try std.testing.expectEqual(@as(i32, 65536), termOffset(raw, 65536));
}

test "activePartitionIndex wraps correctly" {
    try std.testing.expectEqual(@as(usize, 0), activePartitionIndex(0));
    try std.testing.expectEqual(@as(usize, 1), activePartitionIndex(1));
    try std.testing.expectEqual(@as(usize, 2), activePartitionIndex(2));
    try std.testing.expectEqual(@as(usize, 0), activePartitionIndex(3));
    try std.testing.expectEqual(@as(usize, 1), activePartitionIndex(4));
}

test "nextPartitionIndex wraps correctly" {
    try std.testing.expectEqual(@as(usize, 1), nextPartitionIndex(0));
    try std.testing.expectEqual(@as(usize, 2), nextPartitionIndex(1));
    try std.testing.expectEqual(@as(usize, 0), nextPartitionIndex(2));
}

test "LOG_META_DATA_LENGTH is page-aligned" {
    try std.testing.expectEqual(@as(usize, 0), LOG_META_DATA_LENGTH % 4096);
}

test "connected flag and active transport count round trip" {
    var raw align(64) = [_]u8{0} ** LOG_META_DATA_LENGTH;
    var meta = LogBufferMetadata{ .buffer = &raw };

    try std.testing.expect(!meta.isConnected());
    try std.testing.expectEqual(@as(i32, 0), meta.activeTransportCount());

    meta.setIsConnected(true);
    meta.setActiveTransportCount(1);

    try std.testing.expect(meta.isConnected());
    try std.testing.expectEqual(@as(i32, 1), meta.activeTransportCount());
}
