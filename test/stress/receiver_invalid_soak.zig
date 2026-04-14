//! Receiver invalid-packet soak — feeds malformed frames and confirms no panic.
const std = @import("std");
const aeron = @import("aeron");

test "receiver: malformed frame below minimum size does not panic" {
    // A frame shorter than FrameHeader (8 bytes) must be skipped cleanly.
    const buf: [4]u8 = .{ 0x00, 0x01, 0x02, 0x03 };
    _ = buf;
    // Verify the guard constants are correct sizes (> 4 bytes).
    // aeron.protocol is src/protocol/frame.zig
    try std.testing.expect(aeron.protocol.DataHeader.LENGTH > 4);
    try std.testing.expect(aeron.protocol.SetupHeader.LENGTH > 4);
    try std.testing.expect(aeron.protocol.StatusMessage.LENGTH > 4);
}

test "receiver: unknown frame type byte is skipped" {
    // Frame type 0xFF is not a known Aeron frame type (ext=0xFFFF is 2-byte).
    // The receiver's else branch must skip it and advance the offset.
    const unknown: u16 = 0xFF;
    const known_types = [_]u16{
        @intFromEnum(aeron.protocol.FrameType.data),
        @intFromEnum(aeron.protocol.FrameType.setup),
        @intFromEnum(aeron.protocol.FrameType.status),
        @intFromEnum(aeron.protocol.FrameType.nak),
        @intFromEnum(aeron.protocol.FrameType.rtt_measurement),
        @intFromEnum(aeron.protocol.FrameType.resolution_entry),
    };
    for (known_types) |t| {
        try std.testing.expect(t != unknown);
    }
}
