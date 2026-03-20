const std = @import("std");
const frame = @import("aeron").protocol;
const term_reader = @import("aeron").logbuffer.term_reader;

// Callback context for fuzz testing
const FuzzContext = struct {
    fragment_count: usize = 0,
};

fn fuzzHandler(header: *const frame.DataHeader, buffer: []const u8, ctx: *anyopaque) void {
    const fctx = @as(*FuzzContext, @ptrCast(ctx));
    fctx.fragment_count += 1;
    _ = header;
    _ = buffer;
}

/// Fuzz parser for term buffer operations.
/// Feeds corrupted term data to the term reader and attempts to read frames.
pub fn fuzz(input: []const u8) void {
    // Create a term buffer from fuzzing input
    var term_buf = input;
    if (term_buf.len < 256) {
        // Pad if necessary for sensible testing
        return;
    }

    // Create context for fragment handler
    var ctx = FuzzContext{};

    // Try to read frames from corrupted buffer
    const result = term_reader.TermReader.read(
        term_buf,
        0,
        fuzzHandler,
        &ctx,
        1000, // fragments_limit
    );

    // Access result (may indicate partial reads due to corruption)
    _ = result.fragments_read;
    _ = result.offset;
}

test "fuzz_log_buffer: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_log_buffer: small input" {
    fuzz(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
}

test "fuzz_log_buffer: all zeros" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_log_buffer: all 0xFF" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_log_buffer: minimal DataHeader with invalid frame_length" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    // Write invalid frame_length (negative)
    std.mem.writeInt(i32, buf[0..4], -1, .little);
    fuzz(&buf);
}

test "fuzz_log_buffer: frame_length = 0" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}
