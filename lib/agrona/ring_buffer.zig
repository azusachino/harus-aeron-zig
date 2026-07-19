// Lock-free many-to-one ring buffer for client→driver IPC
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java
// LESSON(ring-buffer): Ring buffer avoids syscalls and mutexes by using compare-and-swap on shared metadata. See docs/tutorial/01-foundations/02-ring-buffer.md
const std = @import("std");

pub const INSUFFICIENT_CAPACITY: i32 = -1;
pub const PADDING_MSG_TYPE_ID: i32 = -1;

// Upstream command message types (client → driver)
pub const CLIENT_KEEPALIVE_MSG_TYPE: i32 = 0x06;
pub const TERMINATE_DRIVER_MSG_TYPE: i32 = 0x0E;

// Metadata positions (last 768 bytes of buffer — 6 cache lines of 128 bytes)
pub const TAIL_POSITION_OFFSET: usize = 0;
pub const HEAD_CACHE_POSITION_OFFSET: usize = 128;
pub const HEAD_POSITION_OFFSET: usize = 256;
pub const CORRELATION_COUNTER_OFFSET: usize = 384;
pub const CONSUMER_HEARTBEAT_OFFSET: usize = 640;
pub const METADATA_LENGTH: usize = 768;

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
    buffer: []align(8) u8,
    capacity: usize,

    pub fn init(buf: []align(8) u8) ManyToOneRingBuffer {
        return .{
            .buffer = buf,
            .capacity = buf.len - METADATA_LENGTH,
        };
    }

    fn metadataOffset(self: *const ManyToOneRingBuffer, offset: usize) usize {
        return self.capacity + offset;
    }

    pub fn loadTail(self: *const ManyToOneRingBuffer) i64 {
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

    pub fn loadHead(self: *const ManyToOneRingBuffer) i64 {
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

        // Positions are monotonic and non-negative by construction; a negative
        // value means the backing metadata is corrupt or uninitialized (e.g. an
        // untrusted mapped buffer). Refuse the write rather than @intCast-panic below.
        if (tail < 0 or head_cache < 0) return false;

        // Check if we have capacity
        var available = @as(i64, @intCast(self.capacity)) - (tail - head_cache);
        if (available < @as(i64, @intCast(aligned_length))) {
            // Reload head and update cache
            const head = self.loadHead();
            if (head < 0) return false;
            self.storeHeadCache(head);
            head_cache = head;
            available = @as(i64, @intCast(self.capacity)) - (tail - head_cache);
            if (available < @as(i64, @intCast(aligned_length))) {
                return false;
            }
        }

        // CAS loop: compute padding before attempting CAS
        // LESSON(ring-buffer): CAS loop retries on contention until one writer claims the tail range. No spinlock. See docs/tutorial/01-foundations/02-ring-buffer.md
        // LESSON(ring-buffer): Only the tail cursor is claimed atomically; data copy happens after, so writers don't block each other. See docs/tutorial/01-foundations/02-ring-buffer.md
        var record_index = @as(usize, @intCast(tail)) % self.capacity;
        var padding: usize = 0;

        // Compute padding if record would wrap
        if (record_index + aligned_length > self.capacity) {
            padding = self.capacity - record_index;
        }

        // CAS to claim tail + aligned_length + padding atomically
        const total_claim = @as(i64, @intCast(aligned_length + padding));
        while (!self.casTail(tail, tail + total_claim)) {
            // CAS failed; reload tail and recompute record_index and padding
            tail = self.loadTail();
            record_index = @as(usize, @intCast(tail)) % self.capacity;
            padding = 0;
            if (record_index + aligned_length > self.capacity) {
                padding = self.capacity - record_index;
            }
        }

        // AFTER CAS succeeds: write padding record if needed
        if (padding > 0) {
            const padding_addr = self.buffer.ptr + record_index;
            const pad_len_ptr: *i32 = @ptrCast(@alignCast(padding_addr));
            pad_len_ptr.* = @as(i32, @intCast(padding)); // length at offset 0
            const pad_type_ptr: *i32 = @ptrCast(@alignCast(padding_addr + 4));
            pad_type_ptr.* = PADDING_MSG_TYPE_ID; // type at offset 4
            record_index = 0; // actual record goes at buffer start
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
        const tail = self.loadTail();
        var fragments_read: i32 = 0;

        var i: i32 = 0;
        while (i < limit and head < tail) {
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

    /// Rewrite the record at `index` as a padding record of `length` bytes so the
    /// reader can skip it. Type is written first, then length with release ordering
    /// (the reader acquires length; once it observes a positive value, type@4 is visible).
    fn writePadding(self: *ManyToOneRingBuffer, index: usize, length: i32) void {
        const msg_type_ptr: *i32 = @ptrCast(@alignCast(&self.buffer[index + 4]));
        msg_type_ptr.* = PADDING_MSG_TYPE_ID;
        const length_ptr: *i32 = @ptrCast(@alignCast(&self.buffer[index]));
        @atomicStore(i32, length_ptr, length, .release);
    }

    /// Confirm every slot in [limit, from) is still zeroed. Guards against a slow
    /// writer that filled the gap while we scanned forward — if so, leave it alone.
    fn scanBackConfirmZeroed(self: *const ManyToOneRingBuffer, from: usize, limit: usize) bool {
        var i = from;
        while (i > limit) {
            i -= RecordDescriptor.ALIGNMENT;
            const p: *const i32 = @ptrCast(@alignCast(&self.buffer[i]));
            if (@atomicLoad(i32, p, .acquire) != 0) return false;
        }
        return true;
    }

    /// Recover a ring buffer stalled by a writer that claimed the head slot but never
    /// committed it. Returns true if a record was unblocked. Two cases, matching
    /// Agrona's ManyToOneRingBuffer.unblock():
    ///   1. length < 0 — writer wrote the in-progress sentinel, then stalled. Convert
    ///      the claimed slot straight to padding.
    ///   2. length == 0 — writer CAS-claimed the tail but died before writing the
    ///      sentinel, leaving a zeroed gap. Scan forward to the next written record and
    ///      bridge the gap with a padding record (only if the gap is confirmed zeroed).
    /// Callers must gate this on confirmed writer death (e.g. client-liveness timeout);
    /// unblocking a live in-flight write would corrupt it.
    pub fn unblock(self: *ManyToOneRingBuffer) bool {
        const head = self.loadHead();
        const tail = self.loadTail();

        // Positions are monotonic and non-negative by construction; a negative value
        // means corrupt/uninitialized metadata (untrusted mapped buffer) — never
        // @intCast-panic below.
        if (head < 0 or tail < 0) return false;
        if (head == tail) return false;

        const consumer_index = @as(usize, @intCast(head)) % self.capacity;
        const producer_index = @as(usize, @intCast(tail)) % self.capacity;
        // Equal indices with head != tail means the buffer is exactly full — the head
        // record is a committed record, nothing to unblock.
        if (consumer_index == producer_index) return false;

        const length_ptr: *i32 = @ptrCast(@alignCast(&self.buffer[consumer_index]));
        const record_length = @atomicLoad(i32, length_ptr, .acquire);

        if (record_length < 0) {
            self.writePadding(consumer_index, -record_length);
            return true;
        }

        if (record_length == 0 and producer_index > consumer_index) {
            var i = consumer_index + RecordDescriptor.ALIGNMENT;
            while (i < producer_index) : (i += RecordDescriptor.ALIGNMENT) {
                const scan_ptr: *const i32 = @ptrCast(@alignCast(&self.buffer[i]));
                if (@atomicLoad(i32, scan_ptr, .acquire) != 0) {
                    if (self.scanBackConfirmZeroed(i, consumer_index)) {
                        self.writePadding(consumer_index, @intCast(i - consumer_index));
                        return true;
                    }
                    break;
                }
            }
        }
        return false;
    }
};

test "unblock recovers from stalled writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    // Set head and tail to simulate a record at index 0
    rb.storeHead(0);
    rb.storeTail(32);

    // Simulate stalled writer: write negative length sentinel at index 0
    const record_index: usize = 0;
    const record_length: i32 = 32;
    const length_ptr: *i32 = @ptrCast(@alignCast(&buf[record_index]));
    @atomicStore(i32, length_ptr, -record_length, .release);

    // Verify unblock() recovers it
    try std.testing.expect(rb.unblock());

    // Verify record is now padding
    const new_record_length = @atomicLoad(i32, length_ptr, .acquire);
    try std.testing.expectEqual(record_length, new_record_length);
    const msg_type_ptr: *i32 = @ptrCast(@alignCast(&buf[record_index + 4]));
    try std.testing.expectEqual(PADDING_MSG_TYPE_ID, msg_type_ptr.*);
}

test "unblock bridges a zeroed gap left by a writer that died before the sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    // Writer CAS-claimed [0, 32) (tail advanced) but died before writing the sentinel
    // at index 0, so the head slot is left zeroed. A completed record sits at index 16.
    rb.storeHead(0);
    rb.storeTail(32);
    const rec_len_ptr: *i32 = @ptrCast(@alignCast(&buf[16]));
    @atomicStore(i32, rec_len_ptr, 16, .release);
    const rec_type_ptr: *i32 = @ptrCast(@alignCast(&buf[20]));
    rec_type_ptr.* = 5;

    try std.testing.expect(rb.unblock());

    // The gap [0, 16) is now a padding record so the reader can skip to index 16.
    try std.testing.expectEqual(@as(i32, 16), @atomicLoad(i32, @as(*i32, @ptrCast(@alignCast(&buf[0]))), .acquire));
    try std.testing.expectEqual(PADDING_MSG_TYPE_ID, @as(*i32, @ptrCast(@alignCast(&buf[4]))).*);
}

test "unblock is a no-op when the head slot is a committed record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    try std.testing.expect(rb.write(0x04, "abc"));

    // Head slot holds a valid positive-length record — nothing is blocked.
    try std.testing.expect(!rb.unblock());
}

test "unblock refuses corrupt (negative) head/tail metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    rb.storeHead(-1);
    rb.storeTail(32);
    try std.testing.expect(!rb.unblock());
}

test "record alignment" {
    try std.testing.expectEqual(16, RecordDescriptor.aligned(5));
    try std.testing.expectEqual(16, RecordDescriptor.aligned(8));
}

test "ring buffer constants match agrona protocol values" {
    try std.testing.expectEqual(@as(i32, 0x06), CLIENT_KEEPALIVE_MSG_TYPE);
    try std.testing.expectEqual(@as(i32, 0x0E), TERMINATE_DRIVER_MSG_TYPE);
    try std.testing.expectEqual(@as(usize, 768), METADATA_LENGTH);
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 8), RecordDescriptor.ALIGNMENT);
    try std.testing.expectEqual(@as(usize, 0), TAIL_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 128), HEAD_CACHE_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 256), HEAD_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 384), CORRELATION_COUNTER_OFFSET);
}

test "single write and read roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
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

test "write stores agrona record header as length then type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    const msg = "abc";
    try std.testing.expect(rb.write(0x04, msg));

    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, buf[0..4], .little));
    try std.testing.expectEqual(@as(i32, 0x04), std.mem.readInt(i32, buf[4..8], .little));
    try std.testing.expectEqualSlices(u8, msg, buf[8 .. 8 + msg.len]);
    try std.testing.expectEqual(@as(i64, 16), std.mem.readInt(i64, buf[rb.capacity + TAIL_POSITION_OFFSET ..][0..8], .little));
}

test "write until full returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
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

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
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

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
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

test "wrap-around encodes padding record with length then padding type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    try std.testing.expectEqual(@as(usize, 256), rb.capacity);

    // 15 x 16-byte aligned records => head/tail at 240, leaving 16 bytes at the end.
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
    try std.testing.expectEqual(@as(i32, 14), read_count);

    try std.testing.expect(rb.write(2, "012345678"));

    const padding_index: usize = 240;
    try std.testing.expectEqual(@as(i32, 16), std.mem.readInt(i32, buf[padding_index..][0..4], .little));
    try std.testing.expectEqual(@as(i32, PADDING_MSG_TYPE_ID), std.mem.readInt(i32, buf[padding_index + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 17), std.mem.readInt(i32, buf[0..4], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, buf[4..8], .little));
    try std.testing.expectEqualSlices(u8, "012345678", buf[8..17]);
}

test "java-compat: ADD_SUBSCRIPTION record byte layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    const payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    try std.testing.expect(rb.write(0x04, &payload));

    const expected_len: i32 = @intCast(RecordDescriptor.HEADER_LENGTH + payload.len);
    const actual_len = std.mem.readInt(i32, buf[0..4], .little);
    try std.testing.expectEqual(expected_len, actual_len);

    const actual_type = std.mem.readInt(i32, buf[4..8], .little);
    try std.testing.expectEqual(@as(i32, 0x04), actual_type);

    try std.testing.expectEqualSlices(u8, &payload, buf[8..12]);
}

test "java-compat: metadata offsets match Agrona trailer layout" {
    try std.testing.expectEqual(@as(usize, 0), TAIL_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 128), HEAD_CACHE_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 256), HEAD_POSITION_OFFSET);
    try std.testing.expectEqual(@as(usize, 384), CORRELATION_COUNTER_OFFSET);
    try std.testing.expectEqual(@as(usize, 640), CONSUMER_HEARTBEAT_OFFSET);
    try std.testing.expectEqual(@as(usize, 768), METADATA_LENGTH);
}

test "java-compat: tail advances by aligned record length after write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alignedAlloc(u8, .@"8", 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);
    try std.testing.expect(rb.write(1, "abcd"));
    const tail = std.mem.readInt(i64, buf[rb.capacity + TAIL_POSITION_OFFSET ..][0..8], .little);
    try std.testing.expectEqual(@as(i64, 16), tail);
}
