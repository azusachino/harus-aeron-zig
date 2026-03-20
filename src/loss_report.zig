// Shared-memory loss report for tracking gap observations.
// External tools mmap this buffer to show live loss stats.
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/reports/LossReport.java
const std = @import("std");

pub const LossEntry = extern struct {
    observation_count: i64,
    total_bytes_lost: i64,
    first_observation_ns: i64,
    last_observation_ns: i64,
    session_id: i32,
    stream_id: i32,
    channel_len: i32,
    channel: [20]u8,

    comptime {
        std.debug.assert(@sizeOf(LossEntry) == 64);
    }
};

pub const LOSS_REPORT_BUFFER_LENGTH: usize = 4096; // 64 entries

pub const LossReport = struct {
    buffer: []align(64) u8,
    max_entries: usize,

    pub fn init(buffer: []align(64) u8) LossReport {
        return .{
            .buffer = buffer,
            .max_entries = buffer.len / @sizeOf(LossEntry),
        };
    }

    pub fn recordObservation(
        self: *LossReport,
        bytes_lost: i64,
        timestamp_ns: i64,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
    ) void {
        // Try to find existing entry by session_id + stream_id and coalesce
        var i: usize = 0;
        while (i < self.max_entries) : (i += 1) {
            const entry_ptr = self.entryMut(i);
            const count = @atomicLoad(i64, &entry_ptr.observation_count, .acquire);

            if (count > 0) {
                if (entry_ptr.session_id == session_id and entry_ptr.stream_id == stream_id) {
                    // Coalesce: atomic increment count and bytes, update last timestamp
                    _ = @atomicRmw(i64, &entry_ptr.observation_count, .Add, 1, .release);
                    _ = @atomicRmw(i64, &entry_ptr.total_bytes_lost, .Add, bytes_lost, .release);
                    @atomicStore(i64, &entry_ptr.last_observation_ns, timestamp_ns, .release);
                    return;
                }
            } else {
                break; // Found first empty slot
            }
        }

        // Create new entry in first empty slot
        if (i < self.max_entries) {
            const entry_ptr = self.entryMut(i);
            entry_ptr.first_observation_ns = timestamp_ns;
            entry_ptr.last_observation_ns = timestamp_ns;
            entry_ptr.session_id = session_id;
            entry_ptr.stream_id = stream_id;
            entry_ptr.total_bytes_lost = bytes_lost;

            // Copy channel (truncate if longer than 20 bytes)
            const copy_len = @min(channel.len, 20);
            @memcpy(entry_ptr.channel[0..copy_len], channel[0..copy_len]);
            if (copy_len < 20) {
                @memset(entry_ptr.channel[copy_len..20], 0);
            }
            entry_ptr.channel_len = @as(i32, @intCast(copy_len));

            // Write observation_count LAST to signal entry is committed
            @atomicStore(i64, &entry_ptr.observation_count, 1, .release);
        }
    }

    pub fn entryCount(self: *const LossReport) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.max_entries) : (i += 1) {
            const entry_ptr = self.entryConst(i);
            const obs = @atomicLoad(i64, &entry_ptr.observation_count, .acquire);
            if (obs > 0) {
                count += 1;
            }
        }
        return count;
    }

    pub fn entry(self: *const LossReport, index: usize) ?*const LossEntry {
        if (index >= self.max_entries) return null;
        const entry_ptr = self.entryConst(index);
        const obs = @atomicLoad(i64, &entry_ptr.observation_count, .acquire);
        if (obs <= 0) return null;
        return entry_ptr;
    }

    fn entryMut(self: *LossReport, index: usize) *LossEntry {
        const offset = index * @sizeOf(LossEntry);
        return @ptrCast(@alignCast(self.buffer[offset .. offset + @sizeOf(LossEntry)]));
    }

    fn entryConst(self: *const LossReport, index: usize) *const LossEntry {
        const offset = index * @sizeOf(LossEntry);
        return @ptrCast(@alignCast(self.buffer[offset .. offset + @sizeOf(LossEntry)]));
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "LossEntry is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(LossEntry));
}

test "Record single observation — verify count, bytes, session_id, stream_id" {
    var buffer align(64) = [_]u8{0} ** LOSS_REPORT_BUFFER_LENGTH;
    var report = LossReport.init(&buffer);

    report.recordObservation(1024, 100_000, 1, 2, "aeron:udp?endpoint");

    try std.testing.expectEqual(@as(usize, 1), report.entryCount());

    const e = report.entry(0).?;
    try std.testing.expectEqual(@as(i64, 1), e.observation_count);
    try std.testing.expectEqual(@as(i64, 1024), e.total_bytes_lost);
    try std.testing.expectEqual(@as(i32, 1), e.session_id);
    try std.testing.expectEqual(@as(i32, 2), e.stream_id);
    try std.testing.expectEqual(@as(i64, 100_000), e.first_observation_ns);
    try std.testing.expectEqual(@as(i64, 100_000), e.last_observation_ns);
}

test "Coalesce duplicate session/stream — count=2, bytes summed, timestamps correct" {
    var buffer align(64) = [_]u8{0} ** LOSS_REPORT_BUFFER_LENGTH;
    var report = LossReport.init(&buffer);

    report.recordObservation(1024, 100_000, 1, 2, "aeron:udp?endpoint");
    report.recordObservation(512, 200_000, 1, 2, "aeron:udp?endpoint");

    try std.testing.expectEqual(@as(usize, 1), report.entryCount());

    const e = report.entry(0).?;
    try std.testing.expectEqual(@as(i64, 2), e.observation_count);
    try std.testing.expectEqual(@as(i64, 1536), e.total_bytes_lost);
    try std.testing.expectEqual(@as(i64, 100_000), e.first_observation_ns);
    try std.testing.expectEqual(@as(i64, 200_000), e.last_observation_ns);
}

test "Different sessions get separate entries" {
    var buffer align(64) = [_]u8{0} ** LOSS_REPORT_BUFFER_LENGTH;
    var report = LossReport.init(&buffer);

    report.recordObservation(1024, 100_000, 1, 2, "channel-a");
    report.recordObservation(512, 200_000, 3, 4, "channel-b");

    try std.testing.expectEqual(@as(usize, 2), report.entryCount());

    const e0 = report.entry(0).?;
    try std.testing.expectEqual(@as(i32, 1), e0.session_id);
    try std.testing.expectEqual(@as(i32, 2), e0.stream_id);

    const e1 = report.entry(1).?;
    try std.testing.expectEqual(@as(i32, 3), e1.session_id);
    try std.testing.expectEqual(@as(i32, 4), e1.stream_id);
}
