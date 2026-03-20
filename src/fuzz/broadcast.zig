const std = @import("std");
const broadcast = @import("aeron").ipc.broadcast;

/// Fuzz parser for broadcast buffer operations.
/// Creates broadcast buffer with corrupted data and attempts to receive.
pub fn fuzz(input: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create transmitter with capacity derived from input
    const capacity = if (input.len > 64) input.len else 1024;
    var transmitter = broadcast.BroadcastTransmitter.init(allocator, capacity) catch return;
    defer transmitter.deinit(allocator);

    // Fill buffer with fuzzing data
    for (0..transmitter.buffer.len) |i| {
        transmitter.buffer[i] = input[i % input.len];
    }

    // Create receiver
    var receiver = broadcast.BroadcastReceiver.init(allocator, &transmitter) catch return;

    // Try to receive records from corrupted buffer
    var count = 0;
    while (receiver.receiveNext() and count < 100) {
        _ = receiver.typeId();
        _ = receiver.buffer();
        count += 1;
    }
}

test "fuzz_broadcast: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_broadcast: small input" {
    fuzz(&[_]u8{0xFF});
}

test "fuzz_broadcast: all zeros" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_broadcast: all 0xFF" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_broadcast: valid header pattern" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    // Minimal record header: type (4 bytes) + length (4 bytes) + reserved (4 bytes)
    std.mem.writeInt(i32, buf[0..4], 1, .little); // type = 1
    std.mem.writeInt(i32, buf[4..8], 8, .little); // length = 8
    fuzz(&buf);
}
