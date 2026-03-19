// Shared-memory counters for position tracking and metrics.
// Reference: https://github.com/aeron-io/aeron aeron-driver/src/main/java/org/agrona/concurrent/status/CountersMap.java
const std = @import("std");

pub const PUBLISHER_LIMIT: i32 = 0;
pub const SENDER_POSITION: i32 = 1;
pub const RECEIVER_HWM: i32 = 2;
pub const SUBSCRIBER_POSITION: i32 = 3;
pub const CHANNEL_STATUS: i32 = 4;

pub const RECORD_UNUSED: i32 = 0;
pub const RECORD_ALLOCATED: i32 = 1;
pub const RECORD_RECLAIMED: i32 = -1;

pub const METADATA_LENGTH: usize = 1024;
pub const COUNTER_LENGTH: usize = 64; // Cache line size

pub const RECORD_STATE_OFFSET: usize = 0;
pub const TYPE_ID_OFFSET: usize = 4;
pub const FREE_TO_REUSE_DEADLINE_OFFSET: usize = 8;
pub const KEY_LENGTH_OFFSET: usize = 16;
pub const KEY_DATA_OFFSET: usize = 20;
pub const LABEL_OFFSET: usize = 512;
pub const LABEL_LENGTH_OFFSET: usize = LABEL_OFFSET;
pub const LABEL_DATA_OFFSET: usize = LABEL_OFFSET + 4;

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
        var i: usize = 0;
        while (i < self.max_counters) : (i += 1) {
            const counter_id = @as(i32, @intCast(i));
            const meta_offset = i * METADATA_LENGTH;
            const state_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + RECORD_STATE_OFFSET]));

            const state = @atomicLoad(i32, state_ptr, .monotonic);
            if (state == RECORD_UNUSED or state == RECORD_RECLAIMED) {
                // Initialize metadata
                const type_id_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + TYPE_ID_OFFSET]));
                type_id_ptr.* = type_id;

                const key_len_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + KEY_LENGTH_OFFSET]));
                key_len_ptr.* = 0;

                const label_len_ptr: *i32 = @ptrCast(@alignCast(&self.meta_buffer[meta_offset + LABEL_LENGTH_OFFSET]));
                const max_label_len = METADATA_LENGTH - LABEL_DATA_OFFSET;
                const actual_label_len = @min(label.len, max_label_len);
                label_len_ptr.* = @as(i32, @intCast(actual_label_len));

                if (actual_label_len > 0) {
                    @memcpy(
                        self.meta_buffer[meta_offset + LABEL_DATA_OFFSET .. meta_offset + LABEL_DATA_OFFSET + actual_label_len],
                        label[0..actual_label_len],
                    );
                }

                // Reset value to 0
                self.set(counter_id, 0);

                // Mark allocated (ordered write)
                @atomicStore(i32, state_ptr, RECORD_ALLOCATED, .release);

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

    pub fn get(self: *const CountersMap, counter_id: i32) i64 {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return 0;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        return @atomicLoad(i64, ptr, .acquire);
    }

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
