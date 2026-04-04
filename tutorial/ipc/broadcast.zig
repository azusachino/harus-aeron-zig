// EXERCISE: Chapter 1.3 — Broadcast Buffer
// Reference: docs/tutorial/01-foundations/03-broadcast.md
//
// Your task: implement `BroadcastTransmitter.transmit` and `BroadcastReceiver.receiveNext`.
// The metadata layout and RecordDescriptor are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const TRAILER_LENGTH: usize = 128;
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

pub const BroadcastTransmitter = struct {
    data_buffer: []u8,
    descriptor: *Descriptor,
    capacity: usize,

    pub fn init(full_buffer: []u8) BroadcastTransmitter {
        const capacity = full_buffer.len - TRAILER_LENGTH;
        return .{
            .data_buffer = full_buffer[0..capacity],
            .descriptor = @ptrCast(@alignCast(&full_buffer[capacity])),
            .capacity = capacity,
        };
    }

    /// Transmit a message to all receivers.
    /// Writes message and advances the tail cursor.
    pub fn transmit(self: *BroadcastTransmitter, msg_type_id: i32, data: []const u8) void {
        _ = self;
        _ = msg_type_id;
        _ = data;
        @panic("TODO: implement BroadcastTransmitter.transmit");
    }
};

pub const BroadcastReceiver = struct {
    data_buffer: []u8,
    descriptor: *Descriptor,
    capacity: usize,
    next_record: i64,

    pub fn init(full_buffer: []u8) BroadcastReceiver {
        const capacity = full_buffer.len - TRAILER_LENGTH;
        return .{
            .data_buffer = full_buffer[0..capacity],
            .descriptor = @ptrCast(@alignCast(&full_buffer[capacity])),
            .capacity = capacity,
            .next_record = 0, // Simplified for exercise
        };
    }

    /// Check if a new message is available.
    /// If yes, advance cursors and return true.
    pub fn receiveNext(self: *BroadcastReceiver) bool {
        _ = self;
        @panic("TODO: implement BroadcastReceiver.receiveNext");
    }
};

test "Broadcast transmit and receive" {
    // const buf = try std.testing.allocator.alloc(u8, 1024 + TRAILER_LENGTH);
    // defer std.testing.allocator.free(buf);
    // @memset(buf, 0);
    // var tx = BroadcastTransmitter.init(buf);
    // var rx = BroadcastReceiver.init(buf);
    // tx.transmit(1, "hello");
    // try std.testing.expect(rx.receiveNext());
}
