// EXERCISE: Chapter 1.1 — Frame Codec
// Reference: docs/tutorial/01-foundations/01-frame-codec.md
//
// Your task: implement `alignedLength` and `computeMaxPayload`.
// The frame structs and constants are provided — do not change them.
// Run `make tutorial-check` to verify your solution.
// Stuck? Compare against src/protocol/frame.zig or run:
//   git diff chapter-01-frame-codec chapter-02-ring-buffer

const std = @import("std");

pub const FRAME_ALIGNMENT: usize = 32;
pub const VERSION: u8 = 0x00;

pub const FrameType = enum(u16) {
    padding = 0x00,
    data = 0x01,
    setup = 0x03,
    status = 0x04,
    nak = 0x05,
    rtt_measurement = 0x0B,
    resolution_entry = 0x0E,
};

pub const DataHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    type: u16,
    term_offset: i32,
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    reserved_value: i64,

    pub const LENGTH = @sizeOf(DataHeader);
    pub const BEGIN_FLAG: u8 = 0x80;
    pub const END_FLAG: u8 = 0x40;
};

/// Returns `data_length` rounded up to the nearest FRAME_ALIGNMENT boundary.
/// Aeron requires all frames to be aligned so receivers can scan forward safely.
pub fn alignedLength(data_length: usize) usize {
    _ = data_length;
    @panic("TODO: implement");
}

/// Returns the maximum payload bytes that fit in a single DATA frame given `mtu`.
/// The DataHeader occupies the first 32 bytes of every data frame.
pub fn computeMaxPayload(mtu: usize) usize {
    _ = mtu;
    @panic("TODO: implement");
}

test "alignedLength pads to 32-byte boundary" {
    try std.testing.expectEqual(@as(usize, 32), alignedLength(1));
    try std.testing.expectEqual(@as(usize, 32), alignedLength(32));
    try std.testing.expectEqual(@as(usize, 64), alignedLength(33));
    try std.testing.expectEqual(@as(usize, 64), alignedLength(64));
}

test "computeMaxPayload subtracts header" {
    try std.testing.expectEqual(@as(usize, 1376), computeMaxPayload(1408));
}
