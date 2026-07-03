// Shared-memory counters for position tracking and metrics.
// Reference: https://github.com/aeron-io/aeron aeron-driver/src/main/java/org/agrona/concurrent/status/CountersMap.java
// LESSON(counters): Counters isolate shared position state (publisher-limit, sender-pos, subscriber-pos) in separate cache-line slots. See docs/tutorial/01-foundations/04-counters.md
const std = @import("std");

pub const PUBLISHER_LIMIT: i32 = 1;
pub const SENDER_POSITION: i32 = 2;
pub const RECEIVER_HWM: i32 = 3;
pub const SUBSCRIBER_POSITION: i32 = 4;
pub const RECEIVER_POSITION: i32 = 5;
pub const SEND_CHANNEL_STATUS: i32 = 6;
pub const RECEIVE_CHANNEL_STATUS: i32 = 7;
pub const CHANNEL_STATUS: i32 = SEND_CHANNEL_STATUS;

pub const RECORD_UNUSED: i32 = 0;
pub const RECORD_ALLOCATED: i32 = 1;
pub const RECORD_RECLAIMED: i32 = -1;

pub const METADATA_LENGTH: usize = 512;
// LESSON(counters): 64-byte slots prevent false sharing: a write to counter N doesn't invalidate counter N+1's cache line. See docs/tutorial/01-foundations/04-counters.md
pub const COUNTER_LENGTH: usize = 128; // Agrona counter value record length

pub const RECORD_STATE_OFFSET: usize = 0;
pub const TYPE_ID_OFFSET: usize = 4;
pub const FREE_TO_REUSE_DEADLINE_OFFSET: usize = 8;
pub const KEY_OFFSET: usize = 16;
pub const MAX_KEY_LENGTH: usize = 112;
pub const LABEL_OFFSET: usize = 128;
pub const FULL_LABEL_LENGTH: usize = 384;
pub const MAX_LABEL_LENGTH: usize = FULL_LABEL_LENGTH - @sizeOf(i32);
pub const LABEL_LENGTH_OFFSET: usize = LABEL_OFFSET;
pub const LABEL_DATA_OFFSET: usize = LABEL_OFFSET + 4;
pub const REGISTRATION_ID_OFFSET: usize = 8;
pub const OWNER_ID_OFFSET: usize = 16;
pub const REFERENCE_ID_OFFSET: usize = 24;

pub const STREAM_COUNTER_REGISTRATION_ID_OFFSET: usize = 0;
pub const STREAM_COUNTER_SESSION_ID_OFFSET: usize = STREAM_COUNTER_REGISTRATION_ID_OFFSET + @sizeOf(i64);
pub const STREAM_COUNTER_STREAM_ID_OFFSET: usize = STREAM_COUNTER_SESSION_ID_OFFSET + @sizeOf(i32);
pub const STREAM_COUNTER_CHANNEL_OFFSET: usize = STREAM_COUNTER_STREAM_ID_OFFSET + @sizeOf(i32);
pub const MAX_CHANNEL_LENGTH: usize = MAX_KEY_LENGTH - (STREAM_COUNTER_CHANNEL_OFFSET + @sizeOf(i32));
pub const CHANNEL_STATUS_CHANNEL_OFFSET: usize = 0;
pub const CHANNEL_STATUS_MAX_CHANNEL_LENGTH: usize = MAX_KEY_LENGTH - (@sizeOf(i32) + CHANNEL_STATUS_CHANNEL_OFFSET);

pub const CounterHandle = struct {
    counter_id: i32,
};

pub const NULL_COUNTER_ID: i32 = -1;

pub const CountersMap = struct {
    meta_buffer: []u8,
    values_buffer: []u8,
    max_counters: usize,

    pub fn init(meta: []u8, values: []u8) CountersMap {
        const max_counters = @min(meta.len / METADATA_LENGTH, values.len / COUNTER_LENGTH);
        return .{
            .meta_buffer = meta,
            .values_buffer = values,
            .max_counters = max_counters,
        };
    }

    pub fn allocate(self: *CountersMap, type_id: i32, label: []const u8) CounterHandle {
        return self.allocateCounter(type_id, &.{}, label, 0, 0, 0);
    }

    pub fn allocateStreamCounter(
        self: *CountersMap,
        type_id: i32,
        name: []const u8,
        owner_id: i64,
        registration_id: i64,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        join_position: ?i64,
    ) CounterHandle {
        var key_buf: [MAX_KEY_LENGTH]u8 = undefined;
        @memset(&key_buf, 0);
        std.mem.writeInt(i64, key_buf[STREAM_COUNTER_REGISTRATION_ID_OFFSET..][0..8], registration_id, .little);
        std.mem.writeInt(i32, key_buf[STREAM_COUNTER_SESSION_ID_OFFSET..][0..4], session_id, .little);
        std.mem.writeInt(i32, key_buf[STREAM_COUNTER_STREAM_ID_OFFSET..][0..4], stream_id, .little);

        const channel_len = @min(channel.len, MAX_CHANNEL_LENGTH);
        std.mem.writeInt(i32, key_buf[STREAM_COUNTER_CHANNEL_OFFSET..][0..4], @as(i32, @intCast(channel_len)), .little);
        if (channel_len > 0) {
            @memcpy(
                key_buf[STREAM_COUNTER_CHANNEL_OFFSET + 4 .. STREAM_COUNTER_CHANNEL_OFFSET + 4 + channel_len],
                channel[0..channel_len],
            );
        }
        const key_length = STREAM_COUNTER_CHANNEL_OFFSET + 4 + channel_len;

        var label_buf: [MAX_LABEL_LENGTH]u8 = undefined;
        const label_len = if (join_position) |pos|
            std.fmt.bufPrint(
                &label_buf,
                "{s}: {d} {d} {d} {s} @{d}",
                .{ name, registration_id, session_id, stream_id, channel[0..channel_len], pos },
            ) catch label_buf[0..0]
        else
            std.fmt.bufPrint(
                &label_buf,
                "{s}: {d} {d} {d} {s}",
                .{ name, registration_id, session_id, stream_id, channel[0..channel_len] },
            ) catch label_buf[0..0];

        return self.allocateCounter(type_id, key_buf[0..key_length], label_len, registration_id, owner_id, registration_id);
    }

    pub fn allocateChannelStatusCounter(
        self: *CountersMap,
        type_id: i32,
        name: []const u8,
        registration_id: i64,
        channel: []const u8,
    ) CounterHandle {
        var key_buf: [MAX_KEY_LENGTH]u8 = undefined;
        @memset(&key_buf, 0);

        const channel_len = @min(channel.len, CHANNEL_STATUS_MAX_CHANNEL_LENGTH);
        std.mem.writeInt(i32, key_buf[CHANNEL_STATUS_CHANNEL_OFFSET..][0..4], @as(i32, @intCast(channel_len)), .little);
        if (channel_len > 0) {
            @memcpy(
                key_buf[CHANNEL_STATUS_CHANNEL_OFFSET + 4 .. CHANNEL_STATUS_CHANNEL_OFFSET + 4 + channel_len],
                channel[0..channel_len],
            );
        }
        const key_length = @sizeOf(i32) + channel_len;

        var label_buf: [MAX_LABEL_LENGTH]u8 = undefined;
        const label_len = std.fmt.bufPrint(
            &label_buf,
            "{s}: {s}",
            .{ name, channel[0..channel_len] },
        ) catch label_buf[0..0];

        return self.allocateCounter(type_id, key_buf[0..key_length], label_len, registration_id, 0, 0);
    }

    fn allocateCounter(
        self: *CountersMap,
        type_id: i32,
        key: []const u8,
        label: []const u8,
        registration_id: i64,
        owner_id: i64,
        reference_id: i64,
    ) CounterHandle {
        var i: usize = 0;
        while (i < self.max_counters) : (i += 1) {
            const counter_id = @as(i32, @intCast(i));
            const meta_offset = i * METADATA_LENGTH;
            const state_ptr: *const i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + RECORD_STATE_OFFSET]));
            const state = @atomicLoad(i32, state_ptr, .acquire);

            if (state == RECORD_UNUSED or state == RECORD_RECLAIMED) {
                // Initialize metadata using writeInt for unaligned buffers
                const type_id_ptr: *[4]u8 = @ptrCast(&self.meta_buffer[meta_offset + TYPE_ID_OFFSET]);
                std.mem.writeInt(i32, type_id_ptr, type_id, .little);

                const actual_key_len = @min(key.len, MAX_KEY_LENGTH);
                if (actual_key_len > 0) {
                    @memcpy(
                        self.meta_buffer[meta_offset + KEY_OFFSET .. meta_offset + KEY_OFFSET + actual_key_len],
                        key[0..actual_key_len],
                    );
                }

                const actual_label_len = @min(label.len, MAX_LABEL_LENGTH);
                const label_len_ptr: *[4]u8 = @ptrCast(&self.meta_buffer[meta_offset + LABEL_LENGTH_OFFSET]);
                std.mem.writeInt(i32, label_len_ptr, @as(i32, @intCast(actual_label_len)), .little);

                if (actual_label_len > 0) {
                    @memcpy(
                        self.meta_buffer[meta_offset + LABEL_DATA_OFFSET .. meta_offset + LABEL_DATA_OFFSET + actual_label_len],
                        label[0..actual_label_len],
                    );
                }

                // Reset value to 0
                self.set(counter_id, 0);
                self.setCounterRegistrationId(counter_id, registration_id);
                self.setCounterOwnerId(counter_id, owner_id);
                self.setCounterReferenceId(counter_id, reference_id);

                // Mark allocated (store-release ensures all metadata writes above are visible)
                const state_atomic_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + RECORD_STATE_OFFSET]));
                @atomicStore(i32, state_atomic_ptr, RECORD_ALLOCATED, .release);

                return CounterHandle{ .counter_id = counter_id };
            }
        }
        return CounterHandle{ .counter_id = NULL_COUNTER_ID };
    }

    pub fn free(self: *CountersMap, counter_id: i32) void {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return;
        const meta_offset = @as(usize, @intCast(counter_id)) * METADATA_LENGTH;
        const state_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + RECORD_STATE_OFFSET]));
        @atomicStore(i32, state_ptr, RECORD_RECLAIMED, .release);
    }

    // LESSON(counters): @atomicLoad with .acquire ensures this thread sees all writes prior to a .release store by another thread. See docs/tutorial/01-foundations/04-counters.md
    // LESSON(counters): Read-acquire pairs with write-release to maintain visibility across CPU cores without a full barrier. See docs/tutorial/01-foundations/04-counters.md
    pub fn get(self: *const CountersMap, counter_id: i32) i64 {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return 0;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        return @atomicLoad(i64, ptr, .acquire);
    }

    // LESSON(counters): @atomicStore with .release ensures all prior writes in this thread are visible to readers that acquire after. See docs/tutorial/01-foundations/04-counters.md
    pub fn set(self: *CountersMap, counter_id: i32, value: i64) void {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        @atomicStore(i64, ptr, value, .release);
    }

    pub fn addOrdered(self: *CountersMap, counter_id: i32, delta: i64) void {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        _ = @atomicRmw(i64, ptr, .Add, delta, .release);
    }

    pub fn compareAndSet(self: *CountersMap, counter_id: i32, expected: i64, update: i64) bool {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return false;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        return @cmpxchgStrong(i64, ptr, expected, update, .acq_rel, .acquire) == null;
    }

    pub fn setCounterRegistrationId(self: *CountersMap, counter_id: i32, registration_id: i64) void {
        self.writeValueRecordField(counter_id, REGISTRATION_ID_OFFSET, registration_id);
    }

    pub fn setCounterOwnerId(self: *CountersMap, counter_id: i32, owner_id: i64) void {
        self.writeValueRecordField(counter_id, OWNER_ID_OFFSET, owner_id);
    }

    pub fn setCounterReferenceId(self: *CountersMap, counter_id: i32, reference_id: i64) void {
        self.writeValueRecordField(counter_id, REFERENCE_ID_OFFSET, reference_id);
    }

    pub fn getCounterRegistrationId(self: *const CountersMap, counter_id: i32) i64 {
        return self.readValueRecordField(counter_id, REGISTRATION_ID_OFFSET);
    }

    pub fn getCounterOwnerId(self: *const CountersMap, counter_id: i32) i64 {
        return self.readValueRecordField(counter_id, OWNER_ID_OFFSET);
    }

    pub fn getCounterReferenceId(self: *const CountersMap, counter_id: i32) i64 {
        return self.readValueRecordField(counter_id, REFERENCE_ID_OFFSET);
    }

    fn writeValueRecordField(self: *CountersMap, counter_id: i32, field_offset: usize, value: i64) void {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH + field_offset;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        @atomicStore(i64, ptr, value, .release);
    }

    fn readValueRecordField(self: *const CountersMap, counter_id: i32, field_offset: usize) i64 {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return 0;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH + field_offset;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        return @atomicLoad(i64, ptr, .acquire);
    }
};

test "CountersMap allocate and free" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var counters = CountersMap.init(&meta, &values);

    const h1 = counters.allocate(PUBLISHER_LIMIT, "pub-limit");
    try std.testing.expect(h1.counter_id == 0);
    try std.testing.expectEqual(@as(i64, 0), counters.get(h1.counter_id));

    const h2 = counters.allocate(SENDER_POSITION, "sender-pos");
    try std.testing.expect(h2.counter_id == 1);

    counters.free(h1.counter_id);
    const h3 = counters.allocate(RECEIVER_HWM, "receiver-hwm");
    try std.testing.expect(h3.counter_id == 0); // Should reuse slot 0
}

test "CountersMap operations" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var counters = CountersMap.init(&meta, &values);

    const h = counters.allocate(CHANNEL_STATUS, "channel-status");

    counters.set(h.counter_id, 123);
    try std.testing.expectEqual(@as(i64, 123), counters.get(h.counter_id));

    counters.addOrdered(h.counter_id, 10);
    try std.testing.expectEqual(@as(i64, 133), counters.get(h.counter_id));

    const success = counters.compareAndSet(h.counter_id, 133, 456);
    try std.testing.expect(success);
    try std.testing.expectEqual(@as(i64, 456), counters.get(h.counter_id));

    const fail = counters.compareAndSet(h.counter_id, 133, 789);
    try std.testing.expect(!fail);
    try std.testing.expectEqual(@as(i64, 456), counters.get(h.counter_id));
}

test "counter constants match agrona and aeron stream counters" {
    try std.testing.expectEqual(@as(usize, 512), METADATA_LENGTH);
    try std.testing.expectEqual(@as(usize, 128), COUNTER_LENGTH);
    try std.testing.expectEqual(@as(usize, 16), KEY_OFFSET);
    try std.testing.expectEqual(@as(usize, 112), MAX_KEY_LENGTH);
    try std.testing.expectEqual(@as(usize, 128), LABEL_OFFSET);
    try std.testing.expectEqual(@as(usize, 384), FULL_LABEL_LENGTH);
    try std.testing.expectEqual(@as(usize, 380), MAX_LABEL_LENGTH);
    try std.testing.expectEqual(@as(i32, 1), PUBLISHER_LIMIT);
    try std.testing.expectEqual(@as(i32, 2), SENDER_POSITION);
    try std.testing.expectEqual(@as(i32, 3), RECEIVER_HWM);
    try std.testing.expectEqual(@as(i32, 4), SUBSCRIBER_POSITION);
    try std.testing.expectEqual(@as(i32, 6), SEND_CHANNEL_STATUS);
    try std.testing.expectEqual(@as(i32, 7), RECEIVE_CHANNEL_STATUS);
}

test "allocateStreamCounter writes upstream-style key and value metadata" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var counters = CountersMap.init(&meta, &values);

    const handle = counters.allocateStreamCounter(
        PUBLISHER_LIMIT,
        "pub-limit",
        42,
        99,
        7,
        1001,
        "aeron:udp?endpoint=localhost:40123",
        null,
    );

    try std.testing.expectEqual(@as(i32, 0), handle.counter_id);
    try std.testing.expectEqual(@as(i64, 99), counters.getCounterRegistrationId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 42), counters.getCounterOwnerId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 99), counters.getCounterReferenceId(handle.counter_id));

    const meta_offset = @as(usize, @intCast(handle.counter_id)) * METADATA_LENGTH;
    try std.testing.expectEqual(@as(i64, 99), std.mem.readInt(i64, meta[meta_offset + KEY_OFFSET + STREAM_COUNTER_REGISTRATION_ID_OFFSET ..][0..8], .little));
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, meta[meta_offset + KEY_OFFSET + STREAM_COUNTER_SESSION_ID_OFFSET ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 1001), std.mem.readInt(i32, meta[meta_offset + KEY_OFFSET + STREAM_COUNTER_STREAM_ID_OFFSET ..][0..4], .little));
}

test "allocateChannelStatusCounter writes upstream-style key and registration metadata" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var counters = CountersMap.init(&meta, &values);

    const channel = "aeron:udp?endpoint=localhost:20121";
    const handle = counters.allocateChannelStatusCounter(
        SEND_CHANNEL_STATUS,
        "snd-channel",
        1234,
        channel,
    );

    try std.testing.expectEqual(@as(i32, 0), handle.counter_id);
    try std.testing.expectEqual(@as(i64, 1234), counters.getCounterRegistrationId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 0), counters.getCounterOwnerId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 0), counters.getCounterReferenceId(handle.counter_id));

    const meta_offset = @as(usize, @intCast(handle.counter_id)) * METADATA_LENGTH;
    try std.testing.expectEqual(
        @as(i32, @intCast(channel.len)),
        std.mem.readInt(i32, meta[meta_offset + KEY_OFFSET + CHANNEL_STATUS_CHANNEL_OFFSET ..][0..4], .little),
    );
    try std.testing.expectEqualStrings(
        channel,
        meta[meta_offset + KEY_OFFSET + 4 .. meta_offset + KEY_OFFSET + 4 + channel.len],
    );
}
