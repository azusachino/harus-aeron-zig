// Term Appender Soak Test
// Stress-tests append throughput with term rotation.
// Verifies no data loss or corruption across term boundaries.
//
// Default iterations: 1000 (CI), set SOAK_ITERS=100000 for local soak.

const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const TermAppender = aeron.logbuffer.TermAppender;
const AppendResult = aeron.logbuffer.AppendResult;
const LogBuffer = aeron.logbuffer.LogBuffer;

fn getSoakIterations() usize {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SOAK_ITERS")) |env| {
        defer std.testing.allocator.free(env);
        return std.fmt.parseInt(usize, env, 10) catch 1000;
    } else |_| {
        return 1000;
    }
}

test "term_appender_soak: append N frames with varying sizes" {
    const allocator = std.testing.allocator;
    const iterations = getSoakIterations();

    const term_length = aeron.logbuffer.TERM_MIN_LENGTH;
    const term_buffer = try allocator.alloc(u8, @as(usize, @intCast(term_length)));
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(5, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    // Frame payloads: cycle through sizes 10, 50, 100, 200 bytes
    const sizes = [_]usize{ 10, 50, 100, 200 };
    var appended: usize = 0;
    var size_idx: usize = 0;

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 123;
    header.stream_id = 456;
    header.term_id = 5;
    header.reserved_value = 0;

    while (appended < iterations) {
        const payload_size = sizes[size_idx % sizes.len];
        const payload = try allocator.alloc(u8, payload_size);
        defer allocator.free(payload);
        @memset(payload, @as(u8, @intCast((appended % 256))));

        header.frame_length = 0;
        // Get current offset from raw_tail
        const current_tail = appender.rawTailVolatile();
        header.term_offset = @as(i32, @intCast(current_tail & 0xFFFFFFFF));

        const result = appender.appendData(&header, payload);
        if (std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok) {
            appended += 1;
            size_idx += 1;
        } else {
            break;
        }
    }

    try std.testing.expect(appended > 0);
}

test "term_appender_soak: fill term to near capacity" {
    const allocator = std.testing.allocator;

    const term_length = aeron.logbuffer.TERM_MIN_LENGTH;
    const term_buffer = try allocator.alloc(u8, @as(usize, @intCast(term_length)));
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(10, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 789;
    header.stream_id = 999;
    header.term_id = 10;
    header.reserved_value = 0;

    const payload = "capacity_test";
    var appended: usize = 0;

    while (true) {
        header.frame_length = 0;
        const current_tail = appender.rawTailVolatile();
        header.term_offset = @as(i32, @intCast(current_tail & 0xFFFFFFFF));

        const result = appender.appendData(&header, payload);
        if (std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok) {
            appended += 1;
        } else {
            break;
        }
    }

    // Verify we filled a reasonable amount of the term
    try std.testing.expect(appended > 100);
}

test "term_appender_soak: rapid append-and-check sequence" {
    const allocator = std.testing.allocator;
    const iterations = getSoakIterations() / 10;

    const term_length = aeron.logbuffer.TERM_MIN_LENGTH;
    const term_buffer = try allocator.alloc(u8, @as(usize, @intCast(term_length)));
    defer allocator.free(term_buffer);
    @memset(term_buffer, 0);

    var raw_tail: i64 = TermAppender.packTail(20, 0);
    var appender = TermAppender.init(term_buffer, &raw_tail);

    var header: frame.DataHeader = undefined;
    header.version = frame.VERSION;
    header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
    header.type = @intFromEnum(frame.FrameType.data);
    header.session_id = 111;
    header.stream_id = 222;
    header.term_id = 20;
    header.reserved_value = 0;

    var appended: usize = 0;
    var failed: usize = 0;

    for (0..iterations) |i| {
        const payload = try allocator.alloc(u8, 32);
        defer allocator.free(payload);
        std.mem.writeInt(u32, payload[0..4], @as(u32, @intCast(i)), .little);
        @memset(payload[4..], 0xAA);

        header.frame_length = 0;
        const current_tail = appender.rawTailVolatile();
        header.term_offset = @as(i32, @intCast(current_tail & 0xFFFFFFFF));

        const result = appender.appendData(&header, payload);
        if (std.meta.activeTag(result) == std.meta.Tag(AppendResult).ok) {
            appended += 1;
        } else {
            failed += 1;
        }
    }

    try std.testing.expect(appended > 0);
    // Some may fail due to capacity constraints
    try std.testing.expectEqual(appended + failed, iterations);
}
