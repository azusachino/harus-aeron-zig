// Lock-free many-to-one ring buffer for client→driver IPC
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java
// LESSON(ring-buffer): Ring buffer avoids syscalls and mutexes by using compare-and-swap on shared metadata. See docs/tutorial/01-foundations/02-ring-buffer.md
const std = @import("std");

pub const INSUFFICIENT_CAPACITY: i32 = -1;
pub const PADDING_MSG_TYPE_ID: i32 = -1;

// Upstream command message types (client → driver)
pub const CLIENT_KEEPALIVE_MSG_TYPE: i32 = 0x05;
pub const TERMINATE_DRIVER_MSG_TYPE: i32 = 0x08;

// Metadata positions (last 128 bytes of buffer)
pub const TAIL_POSITION_OFFSET: usize = 0;
pub const HEAD_CACHE_POSITION_OFFSET: usize = 8;
pub const HEAD_POSITION_OFFSET: usize = 16;
pub const CORRELATION_COUNTER_OFFSET: usize = 24;
pub const METADATA_LENGTH: usize = 128;

// LESSON(ring-buffer): Records are padded to cache-line boundaries so wraparound works without straddling. See docs/tutorial/01-foundations/02-ring-buffer.md
pub const RecordDescriptor = struct {
    pub const ALIGNMENT = 8;
    pub const HEADER_LENGTH = 8; // type(4) + length(4)

    pub fn aligned(length: usize) usize {
        return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
    }
};

pub const MessageHandler = *const fn (msg_type_id: i32, data: []const u8, ctx: *anyopaque) void;

pub const ManyToOneRingBuffer = struct {
    buffer: []u8,
    capacity: usize,

    pub fn init(buf: []u8) ManyToOneRingBuffer {
        return .{
            .buffer = buf,
            .capacity = buf.len - METADATA_LENGTH,
        };
    }

    fn metadataOffset(self: *const ManyToOneRingBuffer, offset: usize) usize {
        return self.capacity + offset;
    }

    fn loadTail(self: *const ManyToOneRingBuffer) i64 {
        const addr = self.buffer.ptr + self.metadataOffset(TAIL_POSITION_OFFSET);
        return @atomicLoad(i64, @as(*i64, @ptrCast(@alignCast(addr))), .acquire);
    }

    fn storeTail(self: *ManyToOneRingBuffer, value: i64) void {
        const addr = self.buffer.ptr + self.metadataOffset(TAIL_POSITION_OFFSET);
        @atomicStore(i64, @as(*i64, @ptrCast(@alignCast(addr))), value, .release);
    }

    // LESSON(ring-buffer): @cmpxchgStrong atomically swaps only if current == expected. Success=null, failure=old value. See docs/tutorial/01-foundations/02-ring-buffer.md
    // LESSON(ring-buffer): .acq_rel memory ordering ensures writes before this CAS are visible to readers that acquire after. See docs/tutorial/01-foundations/02-ring-buffer.md
    fn casTail(self: *ManyToOneRingBuffer, expected: i64, new: i64) bool {
        const addr = self.buffer.ptr + self.metadataOffset(TAIL_POSITION_OFFSET);
        const result = @cmpxchgStrong(i64, @as(*i64, @ptrCast(@alignCast(addr))), expected, new, .acq_rel, .acquire);
        return result == null;
    }

    fn loadHead(self: *const ManyToOneRingBuffer) i64 {
        const addr = self.buffer.ptr + self.metadataOffset(HEAD_POSITION_OFFSET);
        return @atomicLoad(i64, @as(*i64, @ptrCast(@alignCast(addr))), .acquire);
    }

    fn storeHead(self: *ManyToOneRingBuffer, value: i64) void {
        const addr = self.buffer.ptr + self.metadataOffset(HEAD_POSITION_OFFSET);
        @atomicStore(i64, @as(*i64, @ptrCast(@alignCast(addr))), value, .release);
    }

    fn loadHeadCache(self: *const ManyToOneRingBuffer) i64 {
        const addr = self.buffer.ptr + self.metadataOffset(HEAD_CACHE_POSITION_OFFSET);
        return @atomicLoad(i64, @as(*i64, @ptrCast(@alignCast(addr))), .acquire);
    }

    fn storeHeadCache(self: *ManyToOneRingBuffer, value: i64) void {
        const addr = self.buffer.ptr + self.metadataOffset(HEAD_CACHE_POSITION_OFFSET);
        @atomicStore(i64, @as(*i64, @ptrCast(@alignCast(addr))), value, .release);
    }

    pub fn write(self: *ManyToOneRingBuffer, msg_type_id: i32, data: []const u8) bool {
        const aligned_length = RecordDescriptor.aligned(data.len);

        var tail = self.loadTail();
        var head_cache = self.loadHeadCache();

        // Check if we have capacity
        var available = @as(i64, @intCast(self.capacity)) - (tail - head_cache);
        if (available < @as(i64, @intCast(aligned_length))) {
            // Reload head and update cache
            const head = self.loadHead();
            self.storeHeadCache(head);
            head_cache = head;
            available = @as(i64, @intCast(self.capacity)) - (tail - head_cache);
            if (available < @as(i64, @intCast(aligned_length))) {
                return false;
            }
        }

        var record_index = @as(usize, @intCast(tail)) % self.capacity;

        // Check if record would wrap around buffer end
        if (record_index + aligned_length > self.capacity) {
            // Insert padding record — Agrona layout: length@0, type@4
            const padding_length = @as(i32, @intCast(self.capacity - record_index));
            const padding_addr = self.buffer.ptr + record_index;
            const pad_len_ptr: *i32 = @ptrCast(@alignCast(padding_addr));
            pad_len_ptr.* = padding_length; // length at offset 0
            const pad_type_ptr: *i32 = @ptrCast(@alignCast(padding_addr + 4));
            pad_type_ptr.* = PADDING_MSG_TYPE_ID; // type at offset 4

            tail += padding_length;
            record_index = 0;
        }

        // LESSON(ring-buffer): CAS loop retries on contention until one writer claims the tail range. No spinlock. See docs/tutorial/01-foundations/02-ring-buffer.md
        // LESSON(ring-buffer): Only the tail cursor is claimed atomically; data copy happens after, so writers don't block each other. See docs/tutorial/01-foundations/02-ring-buffer.md
        while (!self.casTail(tail, tail + @as(i64, @intCast(aligned_length)))) {
            tail = self.loadTail();
        }

        // Write header — Agrona layout: length@0 (negative sentinel), type@4
        const record_addr = self.buffer.ptr + record_index;
        const record_length = @as(i32, @intCast(RecordDescriptor.HEADER_LENGTH + data.len));
        const length_ptr: *i32 = @ptrCast(@alignCast(record_addr));
        @atomicStore(i32, length_ptr, -record_length, .release); // in-progress sentinel
        const msg_type_ptr: *i32 = @ptrCast(@alignCast(record_addr + 4));
        msg_type_ptr.* = msg_type_id; // type at offset 4

        // Copy payload
        if (data.len > 0) {
            const payload_addr = record_addr + RecordDescriptor.HEADER_LENGTH;
            @memcpy(payload_addr[0..data.len], data);
        }

        // Commit: write positive length (ordered store signals record is ready to read)
        @atomicStore(i32, length_ptr, record_length, .release);
        return true;
    }

    pub fn read(self: *ManyToOneRingBuffer, handler: MessageHandler, ctx: *anyopaque, limit: i32) i32 {
        var head = self.loadHead();
        var fragments_read: i32 = 0;

        var i: i32 = 0;
        while (i < limit) {
            const index = @as(usize, @intCast(head)) % self.capacity;

            const record_addr = self.buffer.ptr + index;

            // Agrona layout: length@0 (negative=in-progress, 0=empty, positive=ready), type@4
            const length_ptr: *i32 = @ptrCast(@alignCast(record_addr));
            const record_length = @atomicLoad(i32, length_ptr, .acquire);

            if (record_length <= 0) {
                // Empty slot or writer in progress — no more records to read
                break;
            }

            const msg_type_ptr: *i32 = @ptrCast(@alignCast(record_addr + 4));
            const msg_type_id = msg_type_ptr.*;

            if (msg_type_id == PADDING_MSG_TYPE_ID) {
                // Skip padding — advance head by the stored record length
                head += record_length;
                i += 1;
                continue;
            }

            const msg_length = record_length - RecordDescriptor.HEADER_LENGTH;

            const payload_addr = record_addr + RecordDescriptor.HEADER_LENGTH;
            const msg_data = payload_addr[0..@as(usize, @intCast(msg_length))];

            handler(msg_type_id, msg_data, ctx);

            // Advance by aligned length to skip padding bytes
            head += @as(i64, @intCast(RecordDescriptor.aligned(@as(usize, @intCast(msg_length)))));
            fragments_read += 1;
            i += 1;
        }

        self.storeHead(head);
        return fragments_read;
    }

    pub fn nextCorrelationId(self: *ManyToOneRingBuffer) i64 {
        const addr = self.buffer.ptr + self.metadataOffset(CORRELATION_COUNTER_OFFSET);
        const current = @atomicRmw(i64, @as(*i64, @ptrCast(@alignCast(addr))), .Add, 1, .acq_rel);
        return current + 1;
    }
};

test "record alignment" {
    try std.testing.expectEqual(16, RecordDescriptor.aligned(5));
    try std.testing.expectEqual(16, RecordDescriptor.aligned(8));
}

test "single write and read roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 256);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const test_msg = "hello";
    try std.testing.expect(rb.write(1, test_msg));

    var received_msg: []const u8 = "";
    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
            _ = msg_type_id;
            const out: *[]const u8 = @ptrCast(@alignCast(ctx));
            out.* = data;
        }
    }.handle;

    const fragments = rb.read(handler, @ptrCast(&received_msg), 10);
    try std.testing.expectEqual(fragments, 1);
    try std.testing.expectEqualSlices(u8, test_msg, received_msg);
}

test "write until full returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 512);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "x";
    var count: i32 = 0;

    while (rb.write(1, msg)) {
        count += 1;
        if (count > 1000) break; // Safety
    }

    try std.testing.expect(count > 0);
    try std.testing.expect(!rb.write(1, msg));
}

test "nextCorrelationId monotonically increases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 256);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const id1 = rb.nextCorrelationId();
    const id2 = rb.nextCorrelationId();
    const id3 = rb.nextCorrelationId();

    try std.testing.expectEqual(id1, 1);
    try std.testing.expectEqual(id2, 2);
    try std.testing.expectEqual(id3, 3);
}

test "wrap-around with padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 512);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    // Fill most of buffer
    const msg = "test";
    var count: i32 = 0;
    while (rb.write(1, msg) and count < 50) {
        count += 1;
    }

    // Read half
    var read_count: i32 = 0;
    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
            _ = msg_type_id;
            _ = data;
            const out: *i32 = @ptrCast(@alignCast(ctx));
            out.* += 1;
        }
    }.handle;

    read_count = rb.read(handler, @ptrCast(&read_count), 25);

    // Write more (should trigger wrap)
    var write_count: i32 = 0;
    while (rb.write(1, msg) and write_count < 10) {
        write_count += 1;
    }

    try std.testing.expect(write_count > 0);
}
