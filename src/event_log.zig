// Ring-buffer-backed event log for driver debug/trace.
// External tools mmap this buffer to see events in real-time.
// Single writer (driver), multiple readers (external tools).
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/DriverEventLog.java
const std = @import("std");

pub const EventType = enum(u16) {
    padding = 0,
    frame_in = 1,
    frame_out = 2,
    cmd_in = 3,
    cmd_out = 4,
    send_nak = 5,
    send_status = 6,
    driver_error = 7,
};

pub const EVENT_HEADER_LENGTH: usize = 28;
pub const RECORD_ALIGNMENT: usize = 8;
pub const EVENT_LOG_BUFFER_LENGTH: usize = 64 * 1024; // 64KB default

/// Event record header (variable-length records, 8-byte aligned):
///   0..4   record_length: i32  (total including header, aligned to 8)
///   4..6   event_type: u16
///   6..8   reserved: u16
///   8..16  timestamp_ns: i64
///  16..20  session_id: i32
///  20..24  stream_id: i32
///  24..28  payload_length: i32
///  28..N   payload bytes (variable)
pub const EventLog = struct {
    buffer: []u8,
    capacity: usize,
    write_pos: usize,

    pub fn init(buffer: []u8) EventLog {
        @memset(buffer, 0);
        return .{
            .buffer = buffer,
            .capacity = buffer.len,
            .write_pos = 0,
        };
    }

    pub fn log(
        self: *EventLog,
        event_type: EventType,
        timestamp_ns: i64,
        session_id: i32,
        stream_id: i32,
        payload: []const u8,
    ) void {
        const payload_len = @as(i32, @intCast(payload.len));
        const raw_record_len = EVENT_HEADER_LENGTH + payload.len;
        const aligned_record_len = alignTo(raw_record_len, RECORD_ALIGNMENT);

        // Compute write offset within the ring buffer
        var offset = self.write_pos % self.capacity;

        // Check if record would straddle buffer end — if so, write padding and wrap
        if (offset + aligned_record_len > self.capacity) {
            const remaining = self.capacity - offset;
            // Write padding marker
            writeI32(self.buffer, offset + 0, @as(i32, @intCast(remaining)));
            writeU16(self.buffer, offset + 4, @intFromEnum(EventType.padding));
            self.write_pos += remaining;
            offset = self.write_pos % self.capacity;
        }

        // Write event record
        writeI32(self.buffer, offset + 0, @as(i32, @intCast(aligned_record_len)));
        writeU16(self.buffer, offset + 4, @intFromEnum(event_type));
        writeU16(self.buffer, offset + 6, 0); // reserved
        writeI64(self.buffer, offset + 8, timestamp_ns);
        writeI32(self.buffer, offset + 16, session_id);
        writeI32(self.buffer, offset + 20, stream_id);
        writeI32(self.buffer, offset + 24, payload_len);

        // Copy payload
        if (payload.len > 0) {
            const dst_start = offset + EVENT_HEADER_LENGTH;
            @memcpy(self.buffer[dst_start .. dst_start + payload.len], payload);
        }

        self.write_pos += aligned_record_len;
    }

    /// Scan forward from position 0, decode records, call handler for each valid
    /// record (event_type != 0). Stop when record_length == 0 (no more data).
    pub fn readAll(self: *const EventLog, handler_fn: *const fn (EventType, i64, i32, i32, []const u8) void) usize {
        var count: usize = 0;
        var pos: usize = 0;

        while (pos + EVENT_HEADER_LENGTH <= self.capacity) {
            const record_length = readI32(self.buffer, pos + 0);
            if (record_length <= 0) break;

            const record_len_usize = @as(usize, @intCast(record_length));
            const event_type_raw = readU16(self.buffer, pos + 4);

            if (event_type_raw != @intFromEnum(EventType.padding)) {
                const timestamp_ns = readI64(self.buffer, pos + 8);
                const session_id = readI32(self.buffer, pos + 16);
                const stream_id = readI32(self.buffer, pos + 20);
                const payload_length = readI32(self.buffer, pos + 24);
                const payload_len_usize = @as(usize, @intCast(payload_length));

                const payload_start = pos + EVENT_HEADER_LENGTH;
                const payload = if (payload_len_usize > 0 and payload_start + payload_len_usize <= self.capacity)
                    self.buffer[payload_start .. payload_start + payload_len_usize]
                else
                    self.buffer[payload_start..payload_start];

                const event_type = @as(EventType, @enumFromInt(event_type_raw));
                handler_fn(event_type, timestamp_ns, session_id, stream_id, payload);
                count += 1;
            }

            pos += record_len_usize;
        }

        return count;
    }

    // Helper: align value up to alignment boundary
    fn alignTo(value: usize, alignment: usize) usize {
        return (value + alignment - 1) / alignment * alignment;
    }

    fn writeI32(buf: []u8, offset: usize, value: i32) void {
        std.mem.writeInt(i32, buf[offset..][0..4], value, .little);
    }

    fn writeU16(buf: []u8, offset: usize, value: u16) void {
        std.mem.writeInt(u16, buf[offset..][0..2], value, .little);
    }

    fn writeI64(buf: []u8, offset: usize, value: i64) void {
        std.mem.writeInt(i64, buf[offset..][0..8], value, .little);
    }

    fn readI32(buf: []const u8, offset: usize) i32 {
        return std.mem.readInt(i32, buf[offset..][0..4], .little);
    }

    fn readU16(buf: []const u8, offset: usize) u16 {
        return std.mem.readInt(u16, buf[offset..][0..2], .little);
    }

    fn readI64(buf: []const u8, offset: usize) i64 {
        return std.mem.readInt(i64, buf[offset..][0..8], .little);
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

var test_count: usize = 0;

fn testHandler(_: EventType, _: i64, _: i32, _: i32, _: []const u8) void {
    test_count += 1;
}

test "EventLog: log and read single event" {
    var buffer = [_]u8{0} ** 1024;
    var log = EventLog.init(&buffer);

    log.log(.frame_in, 100_000, 1, 2, "hello");

    test_count = 0;
    const count = log.readAll(&testHandler);
    try std.testing.expect(count >= 1);
}

test "EventLog: multiple events" {
    var buffer = [_]u8{0} ** 1024;
    var log = EventLog.init(&buffer);

    log.log(.frame_in, 100_000, 1, 2, "aaa");
    log.log(.frame_out, 200_000, 3, 4, "bbb");
    log.log(.cmd_in, 300_000, 5, 6, "ccc");

    test_count = 0;
    const count = log.readAll(&testHandler);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "EventLog: wrap around with small buffer" {
    var buffer = [_]u8{0} ** 256;
    var log = EventLog.init(&buffer);

    // Log 20 events — buffer will wrap, old events overwritten
    for (0..20) |i| {
        log.log(.frame_in, @as(i64, @intCast(i)) * 1000, 1, 2, "x");
    }

    // Should still be able to read whatever is in the buffer
    test_count = 0;
    const count = log.readAll(&testHandler);
    try std.testing.expect(count > 0);
}

test "EventLog: event header length is 28" {
    try std.testing.expectEqual(@as(usize, 28), EVENT_HEADER_LENGTH);
}

test "EventLog: record alignment is 8" {
    try std.testing.expectEqual(@as(usize, 8), RECORD_ALIGNMENT);
}
