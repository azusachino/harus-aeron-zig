// EXERCISE: Chapter 2.1 — Term Appender
// Reference: docs/tutorial/02-data-path/01-term-appender.md
//
// Your task: implement `appendData` and `packTail`.
// The AppendResult union and struct layout are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");
const frame = @import("../protocol/frame.zig");

pub const AppendResult = union(enum) {
    ok: i32, // term_offset where data was written
    tripped, // term is full, rotation needed
    admin_action, // CAS failure, caller should retry
    padding_applied, // padding frame written at end, retry in next term
};

pub const TermAppender = struct {
    term_buffer: []u8,
    term_length: i32,
    raw_tail: *i64, // pointer to packed tail in shared mmap metadata

    pub fn init(term_buffer: []u8, raw_tail_ptr: *i64) TermAppender {
        return .{
            .term_buffer = term_buffer,
            .term_length = @as(i32, @intCast(term_buffer.len)),
            .raw_tail = raw_tail_ptr,
        };
    }

    /// Pack term_id and term_offset into a 64-bit value: high 32 = term_id, low 32 = offset.
    pub fn packTail(term_id: i32, term_offset: i32) i64 {
        _ = term_id;
        _ = term_offset;
        @panic("TODO: implement packTail");
    }

    /// Append a data frame (header + payload) to the current term.
    pub fn appendData(
        self: *TermAppender,
        header: *const frame.DataHeader,
        payload: []const u8,
    ) AppendResult {
        _ = self;
        _ = header;
        _ = payload;
        @panic("TODO: implement appendData");
    }

    pub fn appendPadding(self: *TermAppender, _length: i32) AppendResult {
        _ = self;
        _ = _length;
        @panic("TODO: implement appendPadding");
    }
};

test "TermAppender packTail and extraction round-trip" {
    // const term_id = @as(i32, 42);
    // const term_offset = @as(i32, 12345);
    // const packed_tail = TermAppender.packTail(term_id, term_offset);
    // try std.testing.expectEqual(term_id, @as(i32, @intCast(packed_tail >> 32)));
}
