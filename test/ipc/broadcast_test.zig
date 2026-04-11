const std = @import("std");
const aeron = @import("aeron");
const broadcast = aeron.ipc.broadcast;

const BroadcastTransmitter = broadcast.BroadcastTransmitter;
const BroadcastReceiver = broadcast.BroadcastReceiver;
const PADDING_MSG_TYPE_ID = broadcast.PADDING_MSG_TYPE_ID;

test "broadcast: transmit and receive single message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const msg = "hello broadcast";
    try tx.transmit(101, msg);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 101), rx.typeId());
    try std.testing.expectEqualSlices(u8, msg, rx.buffer());
}

test "broadcast: transmit 3 messages and receive all in order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    const messages = [_][]const u8{ "msg0", "msg1", "msg2" };
    const types = [_]i32{ 10, 20, 30 };

    for (messages, types) |msg, msg_type| {
        try tx.transmit(msg_type, msg);
    }

    for (messages, types) |expected_msg, expected_type| {
        try std.testing.expect(rx.receiveNext());
        try std.testing.expectEqual(expected_type, rx.typeId());
        try std.testing.expectEqualSlices(u8, expected_msg, rx.buffer());
    }

    try std.testing.expect(!rx.receiveNext());
}

test "broadcast: lapping detection when transmitter overwrites receiver" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 512);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    const msg_data = "x";
    var written: usize = 0;
    while (written < 100) {
        tx.transmit(1, msg_data) catch break;
        written += 1;
    }

    try std.testing.expect(!rx.lapped());

    try std.testing.expect(rx.receiveNext());
    try std.testing.expect(rx.lapped());
}

test "broadcast: receiver recovers after lapping by repositioning to latest" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 512);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    const msg_data = "x";
    var written: usize = 0;
    while (written < 100) {
        tx.transmit(1, msg_data) catch break;
        written += 1;
    }

    try tx.transmit(99, "final");

    try std.testing.expect(rx.receiveNext());
    try std.testing.expect(rx.lapped());

    while (rx.receiveNext()) {
        if (rx.typeId() == 99) {
            try std.testing.expect(rx.validate());
            break;
        }
    }
}

test "broadcast: typeId() returns correct message type after receiveNext()" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const msg_type = 777;
    try tx.transmit(msg_type, "data");

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(msg_type, rx.typeId());
}

test "broadcast: buffer() returns correct payload after receiveNext()" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const payload = "test payload data";
    try tx.transmit(1, payload);

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqualSlices(u8, payload, rx.buffer());
}

test "broadcast: PADDING_MSG_TYPE_ID records are skipped" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const payload = try allocator.alloc(u8, 120);
    defer allocator.free(payload);
    @memset(payload, 'a');

    for (0..20) |_| {
        try tx.transmit(101, payload);
    }

    var rx = try BroadcastReceiver.init(allocator, &tx);

    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 101), rx.typeId());
    try std.testing.expectEqual(@as(i32, 120), rx.length());
}

test "broadcast: transmitter initializes with correct capacity and metadata" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 2048);
    defer tx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2048), tx.capacity);
    try std.testing.expectEqual(@as(usize, 2048 + broadcast.TRAILER_LENGTH), tx.full_buffer.len);
    try std.testing.expectEqual(@as(usize, 256), tx.max_message_length);
}

test "broadcast: receiver late joins and detects lapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 512);
    defer tx.deinit(allocator);

    var rx = try BroadcastReceiver.init(allocator, &tx);

    const msg_data = "x";
    var written: usize = 0;
    while (written < 100) {
        tx.transmit(1, msg_data) catch break;
        written += 1;
    }

    try std.testing.expect(rx.receiveNext());
    try std.testing.expect(rx.lapped());
}

test "broadcast: sendOperationSuccess encodes correlation_id" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 4096);
    defer tx.deinit(allocator);

    const correlation_id: i64 = 12345;
    tx.sendOperationSuccess(correlation_id);

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(broadcast.ON_OPERATION_SUCCESS_MSG_TYPE, rx.typeId());
    try std.testing.expectEqual(@as(i32, 8), rx.length());
    const received_id = std.mem.readInt(i64, rx.buffer()[0..8], .little);
    try std.testing.expectEqual(correlation_id, received_id);
}

test "broadcast: wrap() initializes from existing buffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const full_buffer = try allocator.alloc(u8, 1024 + broadcast.TRAILER_LENGTH);
    @memset(full_buffer, 0);
    defer allocator.free(full_buffer);

    const tx = BroadcastTransmitter.wrap(full_buffer);

    try std.testing.expectEqual(@as(usize, 1024), tx.capacity);
    try std.testing.expectEqual(full_buffer.ptr, tx.full_buffer.ptr);
}

test "broadcast: receiver wrap() initializes from existing buffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    try tx.transmit(42, "test");

    var rx1 = try BroadcastReceiver.init(allocator, &tx);
    var rx2 = BroadcastReceiver.wrap(tx.full_buffer);

    try std.testing.expect(rx1.receiveNext());
    try std.testing.expect(rx2.receiveNext());
    try std.testing.expectEqual(rx1.typeId(), rx2.typeId());
}

test "broadcast: length() returns correct payload length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const payload = "0123456789";
    try tx.transmit(1, payload);

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 10), rx.length());
}

test "broadcast: offset() returns correct data offset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    try tx.transmit(1, "data");

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());

    const offset = rx.offset();
    try std.testing.expect(offset >= 0);
    try std.testing.expect(offset < 1024);
}

test "broadcast: transmit empty message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    try tx.transmit(1, "");

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());
    try std.testing.expectEqual(@as(i32, 0), rx.length());
}

test "broadcast: transmit with invalid message type fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 1024);
    defer tx.deinit(allocator);

    const result = tx.transmit(0, "data");
    try std.testing.expectError(broadcast.Error.InvalidMessageTypeId, result);
}

test "broadcast: transmit with invalid capacity fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = BroadcastTransmitter.init(allocator, 1023);
    try std.testing.expectError(broadcast.Error.InvalidCapacity, result);
}

test "broadcast: transmit message too long fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 512);
    defer tx.deinit(allocator);

    const too_long = try allocator.alloc(u8, 100);
    defer allocator.free(too_long);
    @memset(too_long, 'a');

    const result = tx.transmit(1, too_long);
    try std.testing.expectError(broadcast.Error.MessageTooLong, result);
}

test "broadcast: validate() returns false after significant overwrite" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tx = try BroadcastTransmitter.init(allocator, 512);
    defer tx.deinit(allocator);

    try tx.transmit(1, "initial");

    var rx = try BroadcastReceiver.init(allocator, &tx);
    try std.testing.expect(rx.receiveNext());

    const msg_data = "x";
    var written: usize = 0;
    while (written < 200) {
        tx.transmit(1, msg_data) catch break;
        written += 1;
    }

    try std.testing.expect(!rx.validate());
}
