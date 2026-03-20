const std = @import("std");
const catalog = @import("aeron").archive.catalog;

/// Fuzz parser for archive catalog operations.
/// Creates catalog entries from corrupted data and attempts lookups.
pub fn fuzz(input: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cat = catalog.Catalog.init(allocator);
    defer cat.deinit();

    // Try to parse corrupted input as recording entries
    var offset: usize = 0;
    while (offset + 64 <= input.len) {
        // Extract channel and source identity from fuzzing input
        const channel_len = (input[offset] % 32) + 1;
        const source_len = (input[offset + 1] % 32) + 1;

        const channel = if (offset + 32 + channel_len <= input.len)
            input[offset + 32 .. offset + 32 + channel_len]
        else
            input[offset..input.len];

        const source = if (offset + 64 + source_len <= input.len)
            input[offset + 64 .. offset + 64 + source_len]
        else
            input[offset..input.len];

        // Try to add recording (may fail due to invalid channel/source lengths)
        _ = cat.addNewRecording(
            123, // session_id
            456, // stream_id
            channel,
            source,
            1, // initial_term_id
            16384, // segment_file_length
            32768, // term_buffer_length
            1408, // mtu_length
            0, // start_position
            0, // start_timestamp
        ) catch {
            // Expected to fail on invalid input
        };

        offset += 65;
    }

    // Try lookups on possibly-populated catalog
    _ = cat.recordingDescriptor(1);
    _ = cat.recordingDescriptor(999);

    // Try updates (safe even if no entries exist)
    cat.updateStopPosition(1, 1024);
    cat.updateStopTimestamp(1, std.time.milliTimestamp());
}

test "fuzz_catalog: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_catalog: small input" {
    fuzz(&[_]u8{ 0x01, 0x02, 0x03 });
}

test "fuzz_catalog: all zeros" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_catalog: all 0xFF" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_catalog: typical entry size" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0x42);
    fuzz(&buf);
}

test "fuzz_catalog: max size" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}
