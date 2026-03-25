// Aeron log buffer — three-term ring structure backed by mmap
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java
const std = @import("std");
const metadata = @import("metadata.zig");

pub const term_reader = @import("term_reader.zig");

pub const PARTITION_COUNT = 3;
pub const LOG_META_DATA_SECTION_INDEX = PARTITION_COUNT;
pub const TERM_MIN_LENGTH: i32 = 64 * 1024;
pub const TERM_MAX_LENGTH: i32 = 1024 * 1024 * 1024;

// LESSON(log-buffer): Three rotating terms let the publisher wrap without the subscriber
// seeing a gap; term_count % 3 picks the active partition. See docs/tutorial/01-foundations/05-log-buffer.md
pub const LogBuffer = struct {
    terms: [PARTITION_COUNT][]u8,
    meta_raw: []u8,
    term_length: i32,
    allocator: std.mem.Allocator,
    mapped_buffer: ?[]align(std.heap.page_size_min) u8 = null,

    pub fn init(allocator: std.mem.Allocator, term_length: i32) !LogBuffer {
        // Validate term_length is power-of-2
        if (term_length < TERM_MIN_LENGTH or term_length > TERM_MAX_LENGTH) {
            return error.InvalidTermLength;
        }
        if ((term_length & (term_length - 1)) != 0) {
            return error.TermLengthNotPowerOfTwo;
        }

        // Allocate metadata buffer (page-aligned)
        const meta_raw = try allocator.alloc(u8, metadata.LOG_META_DATA_LENGTH);
        @memset(meta_raw, 0);

        // Allocate 3 term buffers
        var terms: [PARTITION_COUNT][]u8 = undefined;
        var i: usize = 0;
        while (i < PARTITION_COUNT) : (i += 1) {
            const term_bytes = try allocator.alloc(u8, @as(usize, @intCast(term_length)));
            @memset(term_bytes, 0);
            terms[i] = term_bytes;
        }

        return .{
            .terms = terms,
            .meta_raw = meta_raw,
            .term_length = term_length,
            .allocator = allocator,
            .mapped_buffer = null,
        };
    }

    pub fn initMapped(allocator: std.mem.Allocator, term_length: i32, path: []const u8) !LogBuffer {
        // Validate term_length is power-of-2
        if (term_length < TERM_MIN_LENGTH or term_length > TERM_MAX_LENGTH) {
            return error.InvalidTermLength;
        }
        if ((term_length & (term_length - 1)) != 0) {
            return error.TermLengthNotPowerOfTwo;
        }

        const total = @as(usize, @intCast(term_length)) * PARTITION_COUNT + metadata.LOG_META_DATA_LENGTH;

        // Create or open file and extend to required size
        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
        defer file.close();
        try file.setEndPos(total);

        const ptr = try std.posix.mmap(
            null,
            total,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        const buffer = @as([*]align(std.heap.page_size_min) u8, @ptrCast(ptr))[0..total];

        var terms: [PARTITION_COUNT][]u8 = undefined;
        for (0..PARTITION_COUNT) |i| {
            const start = i * @as(usize, @intCast(term_length));
            terms[i] = buffer[start .. start + @as(usize, @intCast(term_length))];
        }
        const meta_raw = buffer[total - metadata.LOG_META_DATA_LENGTH ..];

        return .{
            .terms = terms,
            .meta_raw = meta_raw,
            .term_length = term_length,
            .allocator = allocator,
            .mapped_buffer = buffer,
        };
    }

    pub fn deinit(self: *LogBuffer) void {
        if (self.mapped_buffer) |mapped| {
            std.posix.munmap(mapped);
        } else {
            var i: usize = 0;
            while (i < PARTITION_COUNT) : (i += 1) {
                self.allocator.free(self.terms[i]);
            }
            self.allocator.free(self.meta_raw);
        }
    }

    pub fn termBuffer(self: *const LogBuffer, partition: usize) []u8 {
        if (partition >= PARTITION_COUNT) return &[_]u8{};
        return self.terms[partition];
    }

    // LESSON(log-buffer): Log metadata stores term counts and append positions atomically;
    // readers use cas (compare-and-swap) to detect and retry when the active term changes.
    // See docs/tutorial/01-foundations/05-log-buffer.md
    pub fn metaData(self: *LogBuffer) metadata.LogBufferMetadata {
        return .{
            .buffer = self.meta_raw,
        };
    }
};

test "LogBuffer: mmap file created on disk" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-logbuf.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    var lb = try LogBuffer.initMapped(allocator, 64 * 1024, path);
    defer lb.deinit();

    // File must exist and have correct size
    const stat = try std.fs.cwd().statFile(path);
    const expected_size = 3 * 64 * 1024 + metadata.LOG_META_DATA_LENGTH;
    try std.testing.expectEqual(expected_size, stat.size);
}

test "LogBuffer init and deinit" {
    const allocator = std.testing.allocator;
    var log_buf = try LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    try std.testing.expectEqual(@as(i32, 64 * 1024), log_buf.term_length);
    for (0..PARTITION_COUNT) |i| {
        try std.testing.expectEqual(@as(usize, 64 * 1024), log_buf.termBuffer(i).len);
    }
}

test "LogBuffer rejects invalid term lengths" {
    const allocator = std.testing.allocator;

    // Too small
    const too_small = LogBuffer.init(allocator, 32 * 1024);
    try std.testing.expectError(error.InvalidTermLength, too_small);

    // Not power-of-2
    const not_pow2 = LogBuffer.init(allocator, 100 * 1024);
    try std.testing.expectError(error.TermLengthNotPowerOfTwo, not_pow2);
}

test "LogBuffer partition count" {
    try std.testing.expectEqual(3, PARTITION_COUNT);
}

test "activePartitionIndex wraps correctly" {
    try std.testing.expectEqual(@as(usize, 0), metadata.activePartitionIndex(0));
    try std.testing.expectEqual(@as(usize, 1), metadata.activePartitionIndex(1));
    try std.testing.expectEqual(@as(usize, 2), metadata.activePartitionIndex(2));
    try std.testing.expectEqual(@as(usize, 0), metadata.activePartitionIndex(3));
}

test "termId and termOffset extraction" {
    const raw: i64 = (@as(i64, 7) << 32) | 12345;
    try std.testing.expectEqual(@as(i32, 7), metadata.termId(raw));
    try std.testing.expectEqual(@as(i32, 12345), metadata.termOffset(raw, 65536));
}

test "nextPartitionIndex wraps correctly" {
    try std.testing.expectEqual(@as(usize, 1), metadata.nextPartitionIndex(0));
    try std.testing.expectEqual(@as(usize, 2), metadata.nextPartitionIndex(1));
    try std.testing.expectEqual(@as(usize, 0), metadata.nextPartitionIndex(2));
}
