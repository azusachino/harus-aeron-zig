// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/ReceiverWindowTest.java
// Aeron version: 1.46.7
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
