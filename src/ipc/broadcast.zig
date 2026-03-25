// One-writer-many-reader broadcast buffer for driver→client notifications.
// LESSON(broadcast-buffer): lock-free broadcast using a shared ring buffer with atomic cursors. See docs/tutorial/01-foundations/03-broadcast.md
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/org/agrona/concurrent/broadcast/

const std = @import("std");

// Broadcast message type IDs
pub const ON_OPERATION_SUCCESS_MSG_TYPE: i32 = 0x0F04;

pub const RecordDescriptor = struct {
    pub const ALIGNMENT = 8;
    pub const HEADER_LENGTH = 8; // type(4) + length(4)

    pub fn aligned(length: usize) usize {
        return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
    }
};

/// BroadcastTransmitter: one-writer side
/// Writes records atomically, advancing the tail cursor.
pub const BroadcastTransmitter = struct {
    buffer: []u8,
    capacity: usize,
    tail: *std.atomic.Value(usize), // cursor into buffer

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !BroadcastTransmitter {
        const buffer = try allocator.alloc(u8, capacity + @sizeOf(std.atomic.Value(usize)));
        const tail_ptr = @as(*std.atomic.Value(usize), @ptrCast(@alignCast(buffer[capacity..])));
        tail_ptr.* = std.atomic.Value(usize).init(0);

        return BroadcastTransmitter{
            .buffer = buffer[0..capacity],
            .capacity = capacity,
            .tail = tail_ptr,
        };
    }

    pub fn wrap(buffer: []u8) BroadcastTransmitter {
        const capacity = buffer.len - @sizeOf(std.atomic.Value(usize));
        const tail_ptr = @as(*std.atomic.Value(usize), @ptrCast(@alignCast(buffer[capacity..])));

        return BroadcastTransmitter{
            .buffer = buffer[0..capacity],
            .capacity = capacity,
            .tail = tail_ptr,
        };
    }

    pub fn deinit(self: *BroadcastTransmitter, allocator: std.mem.Allocator) void {
        const full_buffer = @as([*]u8, @ptrCast(self.buffer.ptr))[0 .. self.buffer.len + @sizeOf(std.atomic.Value(usize))];
        allocator.free(full_buffer);
    }

    pub fn transmit(self: *BroadcastTransmitter, msg_type_id: i32, data: []const u8) void {
        const record_length = @as(i32, @intCast(data.len));
        const aligned_length = @as(usize, @intCast(RecordDescriptor.aligned(data.len)));

        var tail = self.tail.load(.seq_cst);

        while (true) {
            // Check if we need to wrap around
            if (tail + aligned_length > self.capacity) {
                // Would overflow; skip to next aligned boundary or wrap around
                tail = std.mem.alignForward(usize, tail, 64); // align to cache line
                if (tail >= self.capacity) {
                    tail = 0;
                }
                continue;
            }

            const next_tail = tail + aligned_length;

            // Write record header at current tail
            const offset = tail;
            const header_ptr = @as(*[RecordDescriptor.HEADER_LENGTH]u8, @ptrCast(@alignCast(&self.buffer[offset])));

            var header_bytes: [RecordDescriptor.HEADER_LENGTH]u8 = undefined;
            std.mem.writeInt(i32, header_bytes[0..4], msg_type_id, .little);
            std.mem.writeInt(i32, header_bytes[4..8], record_length, .little);

            @memcpy(header_ptr, &header_bytes);

            // Write payload
            if (data.len > 0) {
                @memcpy(self.buffer[offset + RecordDescriptor.HEADER_LENGTH .. offset + RecordDescriptor.HEADER_LENGTH + data.len], data);
            }

            // Atomically advance tail
            if (self.tail.cmpxchgStrong(tail, next_tail, .seq_cst, .seq_cst) == null) {
                return; // Success
            }

            // CAS failed, retry with updated tail
            tail = self.tail.load(.seq_cst);
        }
    }

    /// Send a generic operation success response back to the client.
    /// Used after commands that succeed but have no typed response (e.g. remove operations).
    pub fn sendOperationSuccess(self: *BroadcastTransmitter, correlation_id: i64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        self.transmit(ON_OPERATION_SUCCESS_MSG_TYPE, &buf);
    }
};

/// BroadcastReceiver: many-reader side
/// Reads records sequentially, tracking own cursor independently.
// LESSON(broadcast): Readers poll receiveNext() without blocking; each reader keeps its own head cursor,
// so readers cannot starve each other. See docs/tutorial/01-foundations/03-broadcast.md
pub const BroadcastReceiver = struct {
    shared_buffer: []u8,
    capacity: usize,
    transmitter_tail: *std.atomic.Value(usize),
    head: usize, // our read position
    record_offset: i32, // offset into buffer of current record
    record_length: i32, // length of current record payload
    record_type_id: i32, // type of current record

    pub fn init(_: std.mem.Allocator, transmitter: *BroadcastTransmitter) !BroadcastReceiver {
        return BroadcastReceiver{
            .shared_buffer = transmitter.buffer,
            .capacity = transmitter.capacity,
            .transmitter_tail = transmitter.tail,
            .head = 0,
            .record_offset = 0,
            .record_length = 0,
            .record_type_id = 0,
        };
    }

    pub fn wrap(shared_buffer_raw: []u8) BroadcastReceiver {
        const capacity = shared_buffer_raw.len - @sizeOf(std.atomic.Value(usize));
        const tail_ptr = @as(*std.atomic.Value(usize), @ptrCast(@alignCast(shared_buffer_raw[capacity..])));

        return BroadcastReceiver{
            .shared_buffer = shared_buffer_raw[0..capacity],
            .capacity = capacity,
            .transmitter_tail = tail_ptr,
            .head = 0,
            .record_offset = 0,
            .record_length = 0,
            .record_type_id = 0,
        };
    }

    /// Advance to next record if available.
    /// Returns true if a new record is available, false if at end.
    pub fn receiveNext(self: *BroadcastReceiver) bool {
        const tx_tail = self.transmitter_tail.load(.seq_cst);

        // Check if we've caught up to transmitter
        if (self.head >= tx_tail) {
            return false;
        }

        // Read record header at current head
        if (self.head + RecordDescriptor.HEADER_LENGTH > self.capacity) {
            // Header would wrap; handle wrap or stop
            return false;
        }

        const header_ptr = @as(*const [RecordDescriptor.HEADER_LENGTH]u8, @ptrCast(@alignCast(&self.shared_buffer[self.head])));
        const msg_type_id = std.mem.readInt(i32, header_ptr[0..4], .little);
        const record_length = std.mem.readInt(i32, header_ptr[4..8], .little);

        self.record_type_id = msg_type_id;
        self.record_length = record_length;
        self.record_offset = @as(i32, @intCast(self.head + RecordDescriptor.HEADER_LENGTH));

        // Advance head to next record
        const aligned_length = RecordDescriptor.aligned(@as(usize, @intCast(record_length)));
        self.head = (self.head + aligned_length) % self.capacity;

        return true;
    }

    pub fn typeId(self: *const BroadcastReceiver) i32 {
        return self.record_type_id;
    }

    pub fn buffer(self: *const BroadcastReceiver) []const u8 {
        const start = @as(usize, @intCast(self.record_offset));
        const end = start + @as(usize, @intCast(self.record_length));
        if (end <= self.capacity) {
            return self.shared_buffer[start..end];
        }
        // For now, return what we can (wrap handling is complex)
        return self.shared_buffer[start..self.capacity];
    }

    pub fn offset(self: *const BroadcastReceiver) i32 {
        return self.record_offset;
    }

    pub fn length(self: *const BroadcastReceiver) i32 {
        return self.record_length;
    }

    /// Check if transmitter has lapped us (overwritten our read position).
    pub fn lapped(self: *const BroadcastReceiver) bool {
        const tx_tail = self.transmitter_tail.load(.seq_cst);
        // Transmitter has lapped if its tail is ahead of our head
        // and wrapping hasn't happened yet, OR if tail is behind head (wrapped around)
        // Simple heuristic: if transmitter is at or past our current position and we're behind
        // In a circular buffer, lapping is complex; check if head is in a "danger zone"
        // relative to tail. For now, detect if our records are being overwritten.
        return tx_tail > self.head; // Simple heuristic: transmitter ahead means potential lapping
    }
};

test "broadcast: header is 8 bytes (type i32 + length i32)" {
    // Verify HEADER_LENGTH constant is exactly 8
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.HEADER_LENGTH);
}

test "broadcast: transmit and receive roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    const msg = "hello aeron";
    tx.transmit(42, msg);

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 42), rx.typeId());
    try std.testing.expectEqualSlices(u8, msg, rx.buffer());
}

test "broadcast transmit and receive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    // Transmit a message
    const msg = "hello world";
    tx.transmit(42, msg);

    // Receive it
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 42), rx.typeId());
    try std.testing.expectEqual(@as(i32, 11), rx.length());
    try std.testing.expectEqualSlices(u8, msg, rx.buffer());
}

test "broadcast multiple messages" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    tx.transmit(1, "first");
    tx.transmit(2, "second");
    tx.transmit(3, "third");

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 1), rx.typeId());

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 2), rx.typeId());

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 3), rx.typeId());

    try std.testing.expect(!rx.receiveNext());
}

test "record alignment" {
    try std.testing.expectEqual(16, RecordDescriptor.aligned(5));
    try std.testing.expectEqual(24, RecordDescriptor.aligned(12));
}

test "broadcast: sendOperationSuccess" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    const correlation_id: i64 = 12345;
    tx.sendOperationSuccess(correlation_id);

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(ON_OPERATION_SUCCESS_MSG_TYPE, rx.typeId());
    try std.testing.expectEqual(@as(i32, 8), rx.length());

    const payload = rx.buffer();
    try std.testing.expectEqual(correlation_id, std.mem.readInt(i64, payload[0..8], .little));
}
