const std = @import("std");
const ring_buffer = @import("aeron").ipc.ring_buffer;

/// Fuzz parser for ring buffer operations.
/// Creates a ring buffer backed by corrupted memory and attempts reads.
pub fn fuzz(input: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Minimum buffer size: capacity + metadata
    const min_size = 1024 + ring_buffer.METADATA_LENGTH;
    if (input.len < min_size) return;

    // Create a buffer and fill with fuzzing input (cycling if necessary)
    const buf = allocator.alloc(u8, input.len) catch return;
    defer allocator.free(buf);

    for (0..buf.len) |i| {
        buf[i] = input[i % input.len];
    }

    // Initialize ring buffer with corrupted data
    var rb = ring_buffer.ManyToOneRingBuffer.init(buf);

    // Try to write a message (may fail due to bad metadata)
    const test_msg = "test";
    _ = rb.write(1, test_msg);

    // Safely read metadata positions (atomic loads may read garbage)
    const tail = rb.loadTail();
    const head = rb.loadHead();
    _ = tail;
    _ = head;
}

test "fuzz_ring_buffer: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_ring_buffer: minimal buffer" {
    var buf: [1280]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_ring_buffer: all zeros" {
    var buf: [2048]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_ring_buffer: all 0xFF" {
    var buf: [2048]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_ring_buffer: alternating pattern" {
    var buf: [1280]u8 = undefined;
    for (0..buf.len) |i| {
        buf[i] = if (i % 2 == 0) 0xAA else 0x55;
    }
    fuzz(&buf);
}
