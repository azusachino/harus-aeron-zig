// EXERCISE: Chapter 1.5 — Log Buffer Metadata
// Reference: docs/tutorial/01-foundations/05-log-buffer.md
//
// Your task: implement `activePartitionIndex` and `nextPartitionIndex`.
// The metadata layout and helper functions are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const PARTITION_COUNT = 3;
pub const LOG_META_DATA_LENGTH = 4096;

pub const LogBufferMetadata = struct {
    buffer: []u8,

    pub fn activeTermCount(self: *const LogBufferMetadata) i32 {
        return std.mem.readInt(i32, self.buffer[0..4], .little);
    }

    pub fn setActiveTermCount(self: *LogBufferMetadata, val: i32) void {
        std.mem.writeInt(i32, self.buffer[0..4], val, .little);
    }
};

/// Returns the partition index (0, 1, or 2) for a given term count.
/// Aeron rotates through 3 partitions sequentially.
pub fn activePartitionIndex(term_count: i32) usize {
    _ = term_count;
    @panic("TODO: implement activePartitionIndex");
}

/// Returns the next partition index in the rotation.
pub fn nextPartitionIndex(current: usize) usize {
    _ = current;
    @panic("TODO: implement nextPartitionIndex");
}

pub fn termId(raw_tail: i64) i32 {
    return @intCast(raw_tail >> 32);
}

pub fn termOffset(raw_tail: i64, term_length: i32) i32 {
    const offset = @as(i32, @intCast(raw_tail & 0xFFFFFFFF));
    return if (offset > term_length) term_length else offset;
}

test "activePartitionIndex wraps correctly" {
    // try std.testing.expectEqual(@as(usize, 0), activePartitionIndex(0));
    // try std.testing.expectEqual(@as(usize, 1), activePartitionIndex(1));
    // try std.testing.expectEqual(@as(usize, 2), activePartitionIndex(2));
    // try std.testing.expectEqual(@as(usize, 0), activePartitionIndex(3));
}
