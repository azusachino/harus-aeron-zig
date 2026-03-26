// One-writer-many-reader broadcast buffer for driver->client notifications.
// LESSON(broadcast-buffer): lock-free broadcast uses a power-of-two data region plus a 128-byte trailer
// carrying tail-intent, tail, and latest counters so slow readers can detect lapping. See docs/tutorial/01-foundations/03-broadcast.md
// Upstream reference: vendor/aeron/aeron-client/src/main/c/concurrent/aeron_broadcast_descriptor.h
// Upstream reference: vendor/aeron/aeron-client/src/main/c/concurrent/aeron_broadcast_transmitter.c
// Upstream reference: vendor/aeron/aeron-client/src/main/c/concurrent/aeron_broadcast_receiver.h

const std = @import("std");

pub const ON_OPERATION_SUCCESS_MSG_TYPE: i32 = 0x0F04;

pub const CACHE_LINE_LENGTH: usize = 64;
pub const TRAILER_LENGTH: usize = 2 * CACHE_LINE_LENGTH;
pub const MAX_MESSAGE_FACTOR: usize = 8;
pub const PADDING_MSG_TYPE_ID: i32 = -1;

pub const Descriptor = extern struct {
    tail_intent_counter: i64,
    tail_counter: i64,
    latest_counter: i64,
    pad: [TRAILER_LENGTH - (3 * @sizeOf(i64))]u8,
};

pub const RecordDescriptor = extern struct {
    length: i32,
    msg_type_id: i32,

    pub const HEADER_LENGTH = @sizeOf(RecordDescriptor);
    pub const ALIGNMENT = @sizeOf(RecordDescriptor);
};

pub const TAIL_INTENT_COUNTER_OFFSET: usize = @offsetOf(Descriptor, "tail_intent_counter");
pub const TAIL_COUNTER_OFFSET: usize = @offsetOf(Descriptor, "tail_counter");
pub const LATEST_COUNTER_OFFSET: usize = @offsetOf(Descriptor, "latest_counter");

comptime {
    std.debug.assert(@sizeOf(Descriptor) == TRAILER_LENGTH);
    std.debug.assert(@sizeOf(RecordDescriptor) == 8);
    std.debug.assert(@offsetOf(Descriptor, "tail_intent_counter") == 0);
    std.debug.assert(@offsetOf(Descriptor, "tail_counter") == 8);
    std.debug.assert(@offsetOf(Descriptor, "latest_counter") == 16);
    std.debug.assert(@offsetOf(RecordDescriptor, "length") == 0);
    std.debug.assert(@offsetOf(RecordDescriptor, "msg_type_id") == 4);
}

pub const Error = error{
    InvalidCapacity,
    InvalidMessageTypeId,
    MessageTooLong,
};

fn alignedRecordLength(payload_length: usize) usize {
    return std.mem.alignForward(usize, payload_length + RecordDescriptor.HEADER_LENGTH, RecordDescriptor.ALIGNMENT);
}

fn recordLength(payload_length: usize) usize {
    return payload_length + RecordDescriptor.HEADER_LENGTH;
}

fn descriptorPtr(full_buffer: []u8, capacity: usize) *Descriptor {
    return @as(*Descriptor, @ptrCast(@alignCast(&full_buffer[capacity])));
}

fn recordPtr(buffer: []u8, offset: usize) *RecordDescriptor {
    return @as(*RecordDescriptor, @ptrCast(@alignCast(&buffer[offset])));
}

fn loadTailIntent(desc: *const Descriptor) i64 {
    return @atomicLoad(i64, &@constCast(desc).tail_intent_counter, .acquire);
}

fn loadTail(desc: *const Descriptor) i64 {
    return @atomicLoad(i64, &@constCast(desc).tail_counter, .acquire);
}

fn loadLatest(desc: *const Descriptor) i64 {
    return @atomicLoad(i64, &@constCast(desc).latest_counter, .acquire);
}

fn storeTailIntent(desc: *Descriptor, value: i64) void {
    @atomicStore(i64, &desc.tail_intent_counter, value, .release);
}

fn storeTail(desc: *Descriptor, value: i64) void {
    @atomicStore(i64, &desc.tail_counter, value, .release);
}

fn storeLatest(desc: *Descriptor, value: i64) void {
    @atomicStore(i64, &desc.latest_counter, value, .release);
}

fn validateCapacity(capacity: usize) Error!void {
    if (!std.math.isPowerOfTwo(capacity)) {
        return error.InvalidCapacity;
    }
}

pub const BroadcastTransmitter = struct {
    full_buffer: []u8,
    data_buffer: []u8,
    descriptor: *Descriptor,
    capacity: usize,
    max_message_length: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !BroadcastTransmitter {
        try validateCapacity(capacity);

        const full_buffer = try allocator.alloc(u8, capacity + TRAILER_LENGTH);
        @memset(full_buffer, 0);

        return .{
            .full_buffer = full_buffer,
            .data_buffer = full_buffer[0..capacity],
            .descriptor = descriptorPtr(full_buffer, capacity),
            .capacity = capacity,
            .max_message_length = capacity / MAX_MESSAGE_FACTOR,
        };
    }

    pub fn wrap(full_buffer: []u8) BroadcastTransmitter {
        const capacity = full_buffer.len - TRAILER_LENGTH;
        std.debug.assert(std.math.isPowerOfTwo(capacity));

        return .{
            .full_buffer = full_buffer,
            .data_buffer = full_buffer[0..capacity],
            .descriptor = descriptorPtr(full_buffer, capacity),
            .capacity = capacity,
            .max_message_length = capacity / MAX_MESSAGE_FACTOR,
        };
    }

    pub fn deinit(self: *BroadcastTransmitter, allocator: std.mem.Allocator) void {
        allocator.free(self.full_buffer);
    }

    fn signalTailIntent(self: *BroadcastTransmitter, new_tail: i64) void {
        storeTailIntent(self.descriptor, new_tail);
    }

    fn insertPaddingRecord(self: *BroadcastTransmitter, offset: usize, length: i32) void {
        const record = recordPtr(self.data_buffer, offset);
        record.msg_type_id = PADDING_MSG_TYPE_ID;
        record.length = length;
    }

    pub fn transmit(self: *BroadcastTransmitter, msg_type_id: i32, data: []const u8) Error!void {
        if (data.len > self.max_message_length) {
            return error.MessageTooLong;
        }
        if (msg_type_id < 1) {
            return error.InvalidMessageTypeId;
        }

        var current_tail = loadTail(self.descriptor);
        var record_offset = @as(usize, @intCast(current_tail)) & (self.capacity - 1);
        const unaligned_record_length = recordLength(data.len);
        const aligned_length = alignedRecordLength(data.len);
        const new_tail = current_tail + @as(i64, @intCast(aligned_length));
        const to_end_of_buffer = self.capacity - record_offset;

        if (to_end_of_buffer < aligned_length) {
            self.signalTailIntent(new_tail + @as(i64, @intCast(to_end_of_buffer)));
            self.insertPaddingRecord(record_offset, @as(i32, @intCast(to_end_of_buffer)));
            current_tail += @as(i64, @intCast(to_end_of_buffer));
            record_offset = 0;
        } else {
            self.signalTailIntent(new_tail);
        }

        const record = recordPtr(self.data_buffer, record_offset);
        record.length = @as(i32, @intCast(unaligned_record_length));
        record.msg_type_id = msg_type_id;

        @memcpy(self.data_buffer[record_offset + RecordDescriptor.HEADER_LENGTH ..][0..data.len], data);

        storeLatest(self.descriptor, current_tail);
        storeTail(self.descriptor, current_tail + @as(i64, @intCast(aligned_length)));
    }

    pub fn sendOperationSuccess(self: *BroadcastTransmitter, correlation_id: i64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, correlation_id, .little);
        self.transmit(ON_OPERATION_SUCCESS_MSG_TYPE, &buf) catch unreachable;
    }
};

pub const BroadcastReceiver = struct {
    full_buffer: []u8,
    data_buffer: []u8,
    descriptor: *Descriptor,
    capacity: usize,
    mask: usize,
    record_offset_raw: usize,
    cursor: i64,
    next_record: i64,
    lapped_count: usize,
    current_record_length: usize,
    current_record_type_id: i32,

    pub fn init(_: std.mem.Allocator, transmitter: *BroadcastTransmitter) !BroadcastReceiver {
        return wrap(transmitter.full_buffer);
    }

    pub fn wrap(full_buffer: []u8) BroadcastReceiver {
        const capacity = full_buffer.len - TRAILER_LENGTH;
        std.debug.assert(std.math.isPowerOfTwo(capacity));

        const descriptor = descriptorPtr(full_buffer, capacity);
        const latest = loadLatest(descriptor);

        return .{
            .full_buffer = full_buffer,
            .data_buffer = full_buffer[0..capacity],
            .descriptor = descriptor,
            .capacity = capacity,
            .mask = capacity - 1,
            .record_offset_raw = @as(usize, @intCast(latest)) & (capacity - 1),
            .cursor = latest,
            .next_record = latest,
            .lapped_count = 0,
            .current_record_length = 0,
            .current_record_type_id = 0,
        };
    }

    pub fn validateAt(self: *BroadcastReceiver, cursor: i64) bool {
        return (cursor + @as(i64, @intCast(self.capacity))) > loadTailIntent(self.descriptor);
    }

    pub fn validate(self: *BroadcastReceiver) bool {
        return self.validateAt(self.cursor);
    }

    pub fn receiveNext(self: *BroadcastReceiver) bool {
        const tail = loadTail(self.descriptor);
        var cursor = self.next_record;

        if (tail <= cursor) {
            return false;
        }

        var record_offset = @as(usize, @intCast(cursor)) & self.mask;

        if (!self.validateAt(cursor)) {
            self.lapped_count += 1;
            cursor = loadLatest(self.descriptor);
            record_offset = @as(usize, @intCast(cursor)) & self.mask;
        }

        var record = recordPtr(self.data_buffer, record_offset);

        self.cursor = cursor;
        self.next_record = cursor + @as(i64, @intCast(std.mem.alignForward(
            usize,
            @as(usize, @intCast(record.length)),
            RecordDescriptor.ALIGNMENT,
        )));

        if (record.msg_type_id == PADDING_MSG_TYPE_ID) {
            record_offset = 0;
            self.cursor = self.next_record;
            record = recordPtr(self.data_buffer, 0);
            self.next_record += @as(i64, @intCast(std.mem.alignForward(
                usize,
                @as(usize, @intCast(record.length)),
                RecordDescriptor.ALIGNMENT,
            )));
        }

        self.record_offset_raw = record_offset;
        self.current_record_type_id = record.msg_type_id;
        self.current_record_length = @as(usize, @intCast(record.length)) - RecordDescriptor.HEADER_LENGTH;
        return true;
    }

    pub fn typeId(self: *const BroadcastReceiver) i32 {
        return self.current_record_type_id;
    }

    pub fn buffer(self: *const BroadcastReceiver) []const u8 {
        const start = self.record_offset_raw + RecordDescriptor.HEADER_LENGTH;
        return self.data_buffer[start..][0..self.current_record_length];
    }

    pub fn offset(self: *const BroadcastReceiver) i32 {
        return @as(i32, @intCast(self.record_offset_raw + RecordDescriptor.HEADER_LENGTH));
    }

    pub fn length(self: *const BroadcastReceiver) i32 {
        return @as(i32, @intCast(self.current_record_length));
    }

    pub fn lapped(self: *const BroadcastReceiver) bool {
        return self.lapped_count != 0;
    }
};

test "broadcast descriptor layout matches upstream" {
    try std.testing.expectEqual(@as(usize, 128), TRAILER_LENGTH);
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.ALIGNMENT);
    try std.testing.expectEqual(@as(usize, 0), TAIL_INTENT_COUNTER_OFFSET);
    try std.testing.expectEqual(@as(usize, 8), TAIL_COUNTER_OFFSET);
    try std.testing.expectEqual(@as(usize, 16), LATEST_COUNTER_OFFSET);
}

test "broadcast transmitter initializes upstream capacity and max message length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1024), tx.capacity);
    try std.testing.expectEqual(@as(usize, 128), tx.full_buffer.len - tx.capacity);
    try std.testing.expectEqual(@as(usize, 128), tx.max_message_length);
}

test "broadcast transmitter writes upstream trailer counters and record layout" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    try tx.transmit(101, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });

    const record = recordPtr(tx.data_buffer, 0);
    try std.testing.expectEqual(@as(i32, 16), record.length);
    try std.testing.expectEqual(@as(i32, 101), record.msg_type_id);
    try std.testing.expectEqual(@as(i64, 16), loadTailIntent(tx.descriptor));
    try std.testing.expectEqual(@as(i64, 0), loadLatest(tx.descriptor));
    try std.testing.expectEqual(@as(i64, 16), loadTail(tx.descriptor));
}

test "broadcast transmitter inserts padding record before wrapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    storeTail(tx.descriptor, 1016);
    try tx.transmit(101, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });

    const padding = recordPtr(tx.data_buffer, 1016);
    try std.testing.expectEqual(@as(i32, 8), padding.length);
    try std.testing.expectEqual(PADDING_MSG_TYPE_ID, padding.msg_type_id);

    const wrapped = recordPtr(tx.data_buffer, 0);
    try std.testing.expectEqual(@as(i32, 24), wrapped.length);
    try std.testing.expectEqual(@as(i32, 101), wrapped.msg_type_id);
    try std.testing.expectEqual(@as(i64, 1048), loadTailIntent(tx.descriptor));
    try std.testing.expectEqual(@as(i64, 1024), loadLatest(tx.descriptor));
    try std.testing.expectEqual(@as(i64, 1048), loadTail(tx.descriptor));
}

test "broadcast receiver late joins at latest counter and marks lapped" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const total_length: usize = 16;
    const aligned_length = std.mem.alignForward(usize, total_length, RecordDescriptor.ALIGNMENT);
    const tail: i64 = @as(i64, @intCast(1024 * 3 + RecordDescriptor.HEADER_LENGTH + aligned_length));
    const latest: i64 = tail - @as(i64, @intCast(aligned_length));
    const latest_offset = @as(usize, @intCast(latest)) & (tx.capacity - 1);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    storeTail(tx.descriptor, tail);
    storeTailIntent(tx.descriptor, tail);
    storeLatest(tx.descriptor, latest);

    const record = recordPtr(tx.data_buffer, latest_offset);
    record.length = @as(i32, @intCast(total_length));
    record.msg_type_id = 101;

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 101), rx.typeId());
    try std.testing.expectEqual(@as(i32, 8), rx.length());
    try std.testing.expectEqual(@as(usize, latest_offset + RecordDescriptor.HEADER_LENGTH), @as(usize, @intCast(rx.offset())));
    try std.testing.expect(rx.validate());
    try std.testing.expect(rx.lapped());
}

test "broadcast receiver skips padding and reads wrapped record" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const payload_length: usize = 120;
    const total_length: usize = payload_length + RecordDescriptor.HEADER_LENGTH;
    const aligned_length = std.mem.alignForward(usize, total_length, RecordDescriptor.ALIGNMENT);
    const catchup_tail: i64 = @as(i64, @intCast((tx.capacity * 2) - RecordDescriptor.HEADER_LENGTH));
    const post_padding_tail: i64 = catchup_tail + @as(i64, @intCast(RecordDescriptor.HEADER_LENGTH + aligned_length));
    const latest: i64 = catchup_tail - @as(i64, @intCast(aligned_length));
    const latest_offset = @as(usize, @intCast(latest)) & (tx.capacity - 1);
    const padding_offset = @as(usize, @intCast(catchup_tail)) & (tx.capacity - 1);

    storeTail(tx.descriptor, catchup_tail);
    storeTailIntent(tx.descriptor, catchup_tail);
    storeLatest(tx.descriptor, latest);

    const catchup_record = recordPtr(tx.data_buffer, latest_offset);
    catchup_record.length = @as(i32, @intCast(total_length));
    catchup_record.msg_type_id = 101;

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());

    const padding = recordPtr(tx.data_buffer, padding_offset);
    padding.length = 0;
    padding.msg_type_id = PADDING_MSG_TYPE_ID;

    const wrapped_record = recordPtr(tx.data_buffer, 0);
    wrapped_record.length = @as(i32, @intCast(total_length));
    wrapped_record.msg_type_id = 101;

    storeTail(tx.descriptor, post_padding_tail);
    storeTailIntent(tx.descriptor, post_padding_tail);

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 101), rx.typeId());
    try std.testing.expectEqual(@as(i32, @intCast(payload_length)), rx.length());
    try std.testing.expectEqual(@as(usize, RecordDescriptor.HEADER_LENGTH), @as(usize, @intCast(rx.offset())));
    try std.testing.expect(rx.validate());
}

test "broadcast receiver validate fails after overwrite" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const total_length: usize = 16;
    const aligned_length = std.mem.alignForward(usize, total_length, RecordDescriptor.ALIGNMENT);

    storeTail(tx.descriptor, @as(i64, @intCast(aligned_length)));
    storeTailIntent(tx.descriptor, @as(i64, @intCast(aligned_length)));

    const record = recordPtr(tx.data_buffer, 0);
    record.length = @as(i32, @intCast(total_length));
    record.msg_type_id = 101;

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    storeTailIntent(tx.descriptor, @as(i64, @intCast(aligned_length + (tx.capacity - aligned_length))));
    try std.testing.expect(!rx.validate());
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
    try std.testing.expectEqual(correlation_id, std.mem.readInt(i64, rx.buffer()[0..8], .little));
}
