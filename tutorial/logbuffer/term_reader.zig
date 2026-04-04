// EXERCISE: Chapter 2.2 — Term Reader
// Reference: docs/tutorial/02-data-path/02-term-reader.md
//
// Your task: implement `read` logic.
// The FragmentHandler signature and ReadResult struct are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");
const frame = @import("../protocol/frame.zig");

pub const FragmentHandler = *const fn (header: *const frame.DataHeader, buffer: []const u8, ctx: *anyopaque) void;

pub const ReadResult = struct {
    fragments_read: i32,
    offset: i32,
};

pub const TermReader = struct {
    /// Read frames forward from term buffer at given offset.
    /// - Scan forward from offset
    /// - Skip padding frames (type == .padding)
    /// - Call handler for DATA frames only
    /// - Stop when:
    ///   1. fragments_limit reached
    ///   2. frame_length <= 0 (no data committed yet)
    ///   3. reach end of term buffer
    /// - Return fragments_read count and next offset
    pub fn read(
        term: []const u8,
        offset: i32,
        handler: FragmentHandler,
        ctx: *anyopaque,
        fragments_limit: i32,
    ) ReadResult {
        _ = term;
        _ = offset;
        _ = handler;
        _ = ctx;
        _ = fragments_limit;
        @panic("TODO: implement TermReader.read");
    }
};

test "TermReader.read: stops at frame_length zero" {
    // const allocator = std.testing.allocator;
    // var term = try allocator.alloc(u8, 256);
    // defer allocator.free(term);
    // @memset(term, 0);
    // ...
    // const result = TermReader.read(term, 0, handler, &test_count, 10);
    // try std.testing.expectEqual(@as(i32, 0), result.fragments_read);
}
