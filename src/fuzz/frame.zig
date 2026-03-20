const std = @import("std");
const frame = @import("aeron").protocol;

/// Fuzz parser for wire frame types.
/// Attempts to interpret input bytes as various frame headers.
pub fn fuzz(input: []const u8) void {
    // Try interpreting as FrameHeader
    if (input.len >= frame.FrameHeader.LENGTH) {
        _ = @as(*const frame.FrameHeader, @ptrCast(@alignCast(input.ptr)));
    }

    // Try interpreting as DataHeader
    if (input.len >= frame.DataHeader.LENGTH) {
        const hdr = @as(*const frame.DataHeader, @ptrCast(@alignCast(input.ptr)));
        // Safely read fields; frame_length may be invalid
        _ = hdr.frame_length;
        _ = hdr.version;
        _ = hdr.flags;
        _ = hdr.type;
        _ = hdr.session_id;
        _ = hdr.stream_id;
        _ = hdr.term_id;
    }

    // Try interpreting as SetupHeader
    if (input.len >= frame.SetupHeader.LENGTH) {
        const hdr = @as(*const frame.SetupHeader, @ptrCast(@alignCast(input.ptr)));
        _ = hdr.frame_length;
        _ = hdr.session_id;
        _ = hdr.mtu;
    }

    // Try interpreting as StatusMessage
    if (input.len >= frame.StatusMessage.LENGTH) {
        const hdr = @as(*const frame.StatusMessage, @ptrCast(@alignCast(input.ptr)));
        _ = hdr.frame_length;
        _ = hdr.receiver_window;
    }

    // Try interpreting as NakHeader
    if (input.len >= frame.NakHeader.LENGTH) {
        const hdr = @as(*const frame.NakHeader, @ptrCast(@alignCast(input.ptr)));
        _ = hdr.frame_length;
        _ = hdr.length;
    }

    // Try interpreting as RttMeasurement
    if (input.len >= frame.RttMeasurement.LENGTH) {
        const hdr = @as(*const frame.RttMeasurement, @ptrCast(@alignCast(input.ptr)));
        _ = hdr.frame_length;
        _ = hdr.echo_timestamp;
    }

    // Test alignedLength with corrupted values
    _ = frame.alignedLength(input.len);
    _ = frame.computeMaxPayload(input.len);
}

test "fuzz_frame: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_frame: single byte" {
    fuzz(&[_]u8{0xFF});
}

test "fuzz_frame: all zeros" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_frame: all 0xFF" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_frame: minimal DataHeader size" {
    var buf: [32]u8 = undefined;
    @memset(&buf, 0x42);
    fuzz(&buf);
}

test "fuzz_frame: max size" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}
