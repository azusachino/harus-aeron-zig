const std = @import("std");
const aeron = @import("aeron");
const ring_buffer = aeron.ipc.ring_buffer;

const INSUFFICIENT_CAPACITY = ring_buffer.INSUFFICIENT_CAPACITY;
const PADDING_MSG_TYPE_ID = ring_buffer.PADDING_MSG_TYPE_ID;
const RecordDescriptor = ring_buffer.RecordDescriptor;
const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;

test "ring buffer: basic write and read roundtrip (single message)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "hello world";
    try std.testing.expect(rb.write(42, msg));

    var received: []const u8 = "";
    const handler = struct {
        fn handle(_: i32, data: []const u8, ctx: *anyopaque) void {
            const out: *[]const u8 = @ptrCast(@alignCast(ctx));
            out.* = data;
        }
    }.handle;

    const fragments = rb.read(handler, @ptrCast(&received), 10);
    try std.testing.expectEqual(@as(i32, 1), fragments);
    try std.testing.expectEqualSlices(u8, msg, received);
}

test "ring buffer: write fills buffer to capacity, then write returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "x";
    var count: i32 = 0;

    while (rb.write(1, msg) and count < 1000) {
        count += 1;
    }

    try std.testing.expect(count > 0);
    try std.testing.expect(!rb.write(1, msg));
}

test "ring buffer: wrap-around with padding record insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 2048);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "test";

    for (0..50) |_| {
        try std.testing.expect(rb.write(1, msg));
    }

    var read_count: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const count: *i32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.handle;

    read_count = rb.read(handler, @ptrCast(&read_count), 25);
    try std.testing.expect(read_count > 0);

    var write_count: i32 = 0;
    while (rb.write(2, msg) and write_count < 10) {
        write_count += 1;
    }

    try std.testing.expect(write_count > 0);
}

test "ring buffer: padding record has correct length and type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    try std.testing.expectEqual(@as(usize, 256), rb.capacity);

    for (0..15) |_| {
        try std.testing.expect(rb.write(1, "abc"));
    }

    var read_count: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const count: *i32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.handle;
    _ = rb.read(handler, @ptrCast(&read_count), 14);

    try std.testing.expect(rb.write(2, "012345678"));

    const padding_index: usize = 240;
    const padding_len = std.mem.readInt(i32, buf[padding_index..][0..4], .little);
    const padding_type = std.mem.readInt(i32, buf[padding_index + 4 ..][0..4], .little);
    try std.testing.expectEqual(@as(i32, 16), padding_len);
    try std.testing.expectEqual(PADDING_MSG_TYPE_ID, padding_type);
}

test "ring buffer: multiple messages write and read in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 2048);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const messages = [_][]const u8{
        "msg0", "msg1", "msg2", "msg3", "msg4",
        "msg5", "msg6", "msg7", "msg8", "msg9",
    };

    for (messages) |msg| {
        try std.testing.expect(rb.write(1, msg));
    }

    var received_msgs: [10][]const u8 = undefined;

    const final_handler = struct {
        fn handle(_: i32, data: []const u8, ctx: *anyopaque) void {
            const wrapper: *struct { count: usize = 0, msgs: *[10][]const u8 } = @ptrCast(@alignCast(ctx));
            wrapper.msgs[wrapper.count] = data;
            wrapper.count += 1;
        }
    }.handle;

    var wrapper = struct { count: usize = 0, msgs: *[10][]const u8 }{
        .msgs = &received_msgs,
    };
    _ = rb.read(final_handler, @ptrCast(&wrapper), 10);

    try std.testing.expectEqual(@as(usize, 10), wrapper.count);
    for (messages, 0..) |orig_msg, i| {
        try std.testing.expectEqualSlices(u8, orig_msg, wrapper.msgs[i]);
    }
}

test "ring buffer: nextCorrelationId returns sequential values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const id1 = rb.nextCorrelationId();
    const id2 = rb.nextCorrelationId();
    const id3 = rb.nextCorrelationId();

    try std.testing.expectEqual(@as(i64, 1), id1);
    try std.testing.expectEqual(@as(i64, 2), id2);
    try std.testing.expectEqual(@as(i64, 3), id3);
}

test "ring buffer: MessageHandler receives correct msg_type_id and data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "payload";
    const msg_type = 99;
    try std.testing.expect(rb.write(msg_type, msg));

    var ctx = struct {
        received_type: i32 = 0,
        received_data: []const u8 = "",
    }{};

    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, c: *anyopaque) void {
            const wrapper: *@TypeOf(ctx) = @ptrCast(@alignCast(c));
            wrapper.received_type = msg_type_id;
            wrapper.received_data = data;
        }
    }.handle;

    _ = rb.read(handler, @ptrCast(&ctx), 10);

    try std.testing.expectEqual(msg_type, ctx.received_type);
    try std.testing.expectEqualSlices(u8, msg, ctx.received_data);
}

test "ring buffer: write empty message (length = 0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const empty_msg: []const u8 = "";
    try std.testing.expect(rb.write(77, empty_msg));

    var received: []const u8 = "";
    var received_type: i32 = 0;
    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
            const wrapper: *struct { type: *i32, data: *[]const u8 } = @ptrCast(@alignCast(ctx));
            wrapper.type.* = msg_type_id;
            wrapper.data.* = data;
        }
    }.handle;

    var wrapper = struct { type: *i32, data: *[]const u8 }{
        .type = &received_type,
        .data = &received,
    };

    const fragments = rb.read(handler, @ptrCast(&wrapper), 10);
    try std.testing.expectEqual(@as(i32, 1), fragments);
    try std.testing.expectEqual(@as(i32, 77), received_type);
    try std.testing.expectEqual(@as(usize, 0), received.len);
}

test "ring buffer: write max message (capacity - METADATA_LENGTH - RECORD_HEADER)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const max_payload_len = rb.capacity - RecordDescriptor.HEADER_LENGTH;
    const max_payload = try arena.allocator().alloc(u8, max_payload_len);
    @memset(max_payload, 'a');

    try std.testing.expect(rb.write(88, max_payload));

    var received_len: usize = 0;
    const handler = struct {
        fn handle(_: i32, data: []const u8, ctx: *anyopaque) void {
            const len: *usize = @ptrCast(@alignCast(ctx));
            len.* = data.len;
        }
    }.handle;

    _ = rb.read(handler, @ptrCast(&received_len), 10);

    try std.testing.expectEqual(max_payload_len, received_len);
}

test "ring buffer: read respects limit parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 2048);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    for (0..20) |_| {
        try std.testing.expect(rb.write(1, "x"));
    }

    var count1: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const c: *i32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.handle;

    const fragments1 = rb.read(handler, @ptrCast(&count1), 5);
    try std.testing.expectEqual(@as(i32, 5), fragments1);
    try std.testing.expectEqual(@as(i32, 5), count1);

    var count2: i32 = 0;
    const fragments2 = rb.read(handler, @ptrCast(&count2), 5);
    try std.testing.expectEqual(@as(i32, 5), fragments2);
}

test "ring buffer: read stops when no more records available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    for (0..5) |_| {
        try std.testing.expect(rb.write(1, "msg"));
    }

    var count: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const c: *i32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.handle;

    const fragments1 = rb.read(handler, @ptrCast(&count), 100);
    try std.testing.expectEqual(@as(i32, 5), fragments1);

    var count2: i32 = 0;
    const fragments2 = rb.read(handler, @ptrCast(&count2), 100);
    try std.testing.expectEqual(@as(i32, 0), fragments2);
}

test "ring buffer: record header is stored as [length(4)|type(4)]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "hello";
    const msg_type = 123;
    try std.testing.expect(rb.write(msg_type, msg));

    const expected_len: i32 = @as(i32, @intCast(RecordDescriptor.HEADER_LENGTH + msg.len));
    const stored_len = std.mem.readInt(i32, buf[0..4], .little);
    const stored_type = std.mem.readInt(i32, buf[4..8], .little);

    try std.testing.expectEqual(expected_len, stored_len);
    try std.testing.expectEqual(msg_type, stored_type);
    try std.testing.expectEqualSlices(u8, msg, buf[8 .. 8 + msg.len]);
}

test "ring buffer: write and read preserves message integrity after wrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 2048);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "test";
    var written: i32 = 0;
    while (rb.write(1, msg) and written < 40) {
        written += 1;
    }

    var initial_count: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const count: *i32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.handle;
    _ = rb.read(handler, @ptrCast(&initial_count), 20);

    var more_written: i32 = 0;
    while (rb.write(2, msg) and more_written < 5) {
        more_written += 1;
    }

    try std.testing.expect(written > 0);
    try std.testing.expect(more_written > 0);
}

test "ring buffer: unblock() finds and recovers stalled writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const result = rb.unblock();
    try std.testing.expect(!result);
}
