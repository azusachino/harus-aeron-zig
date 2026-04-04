// EXERCISE: Chapter 1.5 — Log Buffer
// Reference: docs/tutorial/01-foundations/05-log-buffer.md
//
// Your task: implement `LogBuffer.init`.
// The partition layout and metadata mapping are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");
const metadata = @import("metadata.zig");

pub const PARTITION_COUNT = 3;
pub const TERM_MIN_LENGTH: i32 = 64 * 1024;
pub const TERM_MAX_LENGTH: i32 = 1024 * 1024 * 1024;

pub const LogBuffer = struct {
    terms: [PARTITION_COUNT][]u8,
    meta_raw: []u8,
    term_length: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, term_length: i32) !LogBuffer {
        _ = allocator;
        _ = term_length;
        @panic("TODO: implement LogBuffer.init");
    }

    pub fn deinit(self: *LogBuffer) void {
        var i: usize = 0;
        while (i < PARTITION_COUNT) : (i += 1) {
            self.allocator.free(self.terms[i]);
        }
        self.allocator.free(self.meta_raw);
    }

    pub fn termBuffer(self: *const LogBuffer, partition: usize) []u8 {
        if (partition >= PARTITION_COUNT) return &[_]u8{};
        return self.terms[partition];
    }

    pub fn metaData(self: *LogBuffer) metadata.LogBufferMetadata {
        return .{
            .buffer = self.meta_raw,
        };
    }
};

test "LogBuffer init and deinit" {
    // const allocator = std.testing.allocator;
    // var log_buf = try LogBuffer.init(allocator, 64 * 1024);
    // defer log_buf.deinit();
    // try std.testing.expectEqual(@as(i32, 64 * 1024), log_buf.term_length);
}
