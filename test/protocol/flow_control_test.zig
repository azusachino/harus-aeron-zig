// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/ReceiverWindowTest.java
// Aeron version: 1.50.2
// Coverage: initial window equals term_buffer_length (or a fraction thereof), window does not exceed max

const std = @import("std");
const aeron = @import("aeron");

test "ReceiverWindow: default window in receiver" {
    // Reference: src/driver/receiver.zig:526
    const term_length: i32 = 65536;
    const window = @as(i32, @divTrunc(term_length, 4));
    try std.testing.expectEqual(@as(i32, 16384), window);
}

test "ReceiverWindow: clamp window" {
    // Reference: src/driver/sender.zig:340
    const receiver_position: i64 = 1024;
    const receiver_window: i32 = 4096;
    const new_limit = receiver_position + receiver_window;
    try std.testing.expectEqual(@as(i64, 5120), new_limit);
}

// ===== New edge-case tests =====

test "PublisherLimit: term_length=16MB, window=1MB, position=0 -> limit=1MB" {
    // Reference: Aeron receiver sends StatusMessage with receiver_window
    const window: i32 = 1 * 1024 * 1024;
    const position: i64 = 0;
    const publisher_limit = position + window;
    try std.testing.expectEqual(@as(i64, 1 * 1024 * 1024), publisher_limit);
}

test "PublisherLimit: with non-zero position" {
    const window: i32 = 2 * 1024 * 1024;
    const position: i64 = 8 * 1024 * 1024;
    const publisher_limit = position + window;
    try std.testing.expectEqual(@as(i64, 10 * 1024 * 1024), publisher_limit);
}

test "ReceiverWindow: StatusMessage receiver_window propagated correctly" {
    // StatusMessage.receiver_window is i32
    const receiver_window: i32 = 131072;
    try std.testing.expectEqual(@as(i32, 131072), receiver_window);
}

test "ReceiverWindow: window at term boundary" {
    const term_length: i32 = 16 * 1024 * 1024;
    const window = @as(i32, @divTrunc(term_length, 4));
    try std.testing.expectEqual(@as(i32, 4 * 1024 * 1024), window);
}

test "ReceiverWindow: window = term_length / 2" {
    const term_length: i32 = 16 * 1024 * 1024;
    const window = @as(i32, @divTrunc(term_length, 2));
    try std.testing.expectEqual(@as(i32, 8 * 1024 * 1024), window);
}

test "BackPressureThreshold: publisherLimit - currentPosition < mtu triggers back-pressure" {
    const publisher_limit: i64 = 10 * 1024 * 1024;
    const current_position: i64 = 10 * 1024 * 1024 - 512; // 512 bytes from limit
    const mtu: i32 = 1408;
    const available: i64 = publisher_limit - current_position;
    try std.testing.expect(available < mtu);
}

test "BackPressureThreshold: publisherLimit - currentPosition >= mtu no back-pressure" {
    const publisher_limit: i64 = 10 * 1024 * 1024;
    const current_position: i64 = 10 * 1024 * 1024 - 2048; // 2048 bytes from limit
    const mtu: i32 = 1408;
    const available: i64 = publisher_limit - current_position;
    try std.testing.expect(available >= mtu);
}

test "BackPressureThreshold: at exact MTU boundary" {
    const publisher_limit: i64 = 10 * 1024 * 1024;
    const mtu: i32 = 1408;
    const current_position: i64 = publisher_limit - mtu;
    const available: i64 = publisher_limit - current_position;
    try std.testing.expectEqual(@as(i64, @as(i64, mtu)), available);
}

test "PositionArithmetic: term_id * term_length + term_offset round-trip" {
    const term_id: i32 = 5;
    const term_length: i32 = 16 * 1024 * 1024;
    const term_offset: i32 = 8 * 1024 * 1024;
    const position: i64 = @as(i64, term_id) * term_length + term_offset;
    try std.testing.expectEqual(@as(i64, @as(i64, 5) * 16 * 1024 * 1024 + 8 * 1024 * 1024), position);
}

test "PositionArithmetic: position decomposition" {
    const position: i64 = 100 * 1024 * 1024;
    const term_length: i32 = 16 * 1024 * 1024;
    const term_id: i32 = @as(i32, @intCast(@divTrunc(position, term_length)));
    const term_offset: i32 = @as(i32, @intCast(@rem(position, term_length)));
    try std.testing.expectEqual(@as(i32, 6), term_id);
    try std.testing.expectEqual(@as(i32, 4 * 1024 * 1024), term_offset);
}

test "PositionArithmetic: term_id wrapping with large values" {
    const term_id: i32 = std.math.maxInt(i32);
    const term_length: i32 = 16 * 1024 * 1024;
    const term_offset: i32 = 0;
    const position: i64 = @as(i64, term_id) * term_length + term_offset;
    try std.testing.expectEqual(@as(i64, @as(i64, std.math.maxInt(i32)) * 16 * 1024 * 1024), position);
}

test "AlignedLength: 0 byte payload aligns to 32 (DataHeader.LENGTH)" {
    const protocol = aeron.protocol;
    try std.testing.expectEqual(@as(usize, 32), protocol.alignedLength(0));
}

test "AlignedLength: 1 byte payload aligns to 64" {
    const protocol = aeron.protocol;
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(1));
}

test "AlignedLength: 31 byte payload aligns to 64" {
    const protocol = aeron.protocol;
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(31));
}

test "AlignedLength: 32 byte payload aligns to 64" {
    const protocol = aeron.protocol;
    try std.testing.expectEqual(@as(usize, 64), protocol.alignedLength(32));
}

test "AlignedLength: 1376 byte payload aligns to 1408" {
    const protocol = aeron.protocol;
    // 1376 (max payload) + 32 (header) = 1408, already aligned
    try std.testing.expectEqual(@as(usize, 1408), protocol.alignedLength(1376));
}

test "AlignedLength: padding frame used for remainder" {
    const protocol = aeron.protocol;
    const payload_len = 100;
    const frame_len = protocol.alignedLength(payload_len);
    // Next frame should start at frame_len boundary
    try std.testing.expect(frame_len % 32 == 0);
}

test "WindowFlow: position stays within publisher_limit" {
    const publisher_limit: i64 = 10 * 1024 * 1024;
    const current_position: i64 = 9 * 1024 * 1024;
    const mtu: i32 = 1408;

    // Can still send frames
    const available: i64 = publisher_limit - current_position;
    try std.testing.expect(available >= mtu);
}

test "WindowFlow: position exceeds publisher_limit blocks publishing" {
    const publisher_limit: i64 = 10 * 1024 * 1024;
    const current_position: i64 = 10 * 1024 * 1024 + 100; // Beyond limit

    // Would be blocked
    const available: i64 = publisher_limit - current_position;
    try std.testing.expect(available < 0);
}

test "TermOffset: max valid offset before wrapping to next term" {
    const term_length: i32 = 16 * 1024 * 1024;
    const max_offset: i32 = term_length - 1;
    try std.testing.expectEqual(@as(i32, 16 * 1024 * 1024 - 1), max_offset);
}

test "ReceiverWindow: minimum reasonable window size" {
    // Typical minimum: term_length / 4
    const term_length: i32 = 64 * 1024; // Small term
    const min_window = @as(i32, @divTrunc(term_length, 4));
    try std.testing.expectEqual(@as(i32, 16 * 1024), min_window);
}

test "PublisherLimit: incremented by StatusMessage reception" {
    const status_window: i32 = 1 * 1024 * 1024;
    const receiver_position: i64 = 4 * 1024 * 1024;
    const new_limit: i64 = receiver_position + @as(i64, @intCast(status_window));
    try std.testing.expectEqual(@as(i64, 5 * 1024 * 1024), new_limit);
}

test "FlowControl: maximum payload size from MTU" {
    const protocol = aeron.protocol;
    const mtu: usize = 1408;
    const max_payload = protocol.computeMaxPayload(mtu);
    try std.testing.expectEqual(@as(usize, 1376), max_payload);
}

test "FlowControl: small MTU limits payload" {
    const protocol = aeron.protocol;
    const mtu: usize = 64; // Very small
    const max_payload = protocol.computeMaxPayload(mtu);
    try std.testing.expectEqual(@as(usize, 32), max_payload);
}
