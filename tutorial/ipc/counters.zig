// EXERCISE: Chapter 1.4 — Counters
// Reference: docs/tutorial/01-foundations/04-counters.md
//
// Your task: implement `allocate` and `set`.
// The metadata layout and CounterHandle are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const METADATA_LENGTH: usize = 512;
pub const COUNTER_LENGTH: usize = 128;

pub const RECORD_UNUSED: i32 = 0;
pub const RECORD_ALLOCATED: i32 = 1;
pub const RECORD_RECLAIMED: i32 = -1;

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

    /// Allocate a new counter slot.
    /// Finds the first UNUSED or RECLAIMED slot in metadata.
    /// Returns a handle to the counter.
    pub fn allocate(self: *CountersMap, type_id: i32, label: []const u8) CounterHandle {
        _ = self;
        _ = type_id;
        _ = label;
        @panic("TODO: implement CountersMap.allocate");
    }

    /// Set the value of a counter.
    /// Uses atomic store with release semantics.
    pub fn set(self: *CountersMap, counter_id: i32, value: i64) void {
        _ = self;
        _ = counter_id;
        _ = value;
        @panic("TODO: implement CountersMap.set");
    }

    /// Get the value of a counter.
    /// Uses atomic load with acquire semantics.
    pub fn get(self: *const CountersMap, counter_id: i32) i64 {
        if (counter_id < 0 or counter_id >= @as(i32, @intCast(self.max_counters))) return 0;
        const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
        const ptr: *const i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
        return @atomicLoad(i64, ptr, .acquire);
    }
};

test "CountersMap allocate and set" {
    // var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    // var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    // var counters = CountersMap.init(&meta, &values);
    // const h = counters.allocate(1, "test");
    // counters.set(h.counter_id, 100);
    // try std.testing.expectEqual(@as(i64, 100), counters.get(h.counter_id));
}
