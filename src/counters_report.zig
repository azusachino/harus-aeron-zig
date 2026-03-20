// Counters reporting — reads CountersMap and formats as human-readable text table.
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const counters = @import("ipc/counters.zig");
const CountersMap = counters.CountersMap;

pub const CounterInfo = struct {
    id: i32,
    type_id: i32,
    value: i64,
    label: []const u8,
};

pub const CountersReport = struct {
    counters_map: *const CountersMap,

    pub fn init(counters_map: *const CountersMap) CountersReport {
        return .{ .counters_map = counters_map };
    }

    /// Iterate all ALLOCATED counters, calling handler_fn for each.
    /// Returns the number of allocated counters found.
    pub fn forEach(self: CountersReport, handler_fn: anytype) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.counters_map.max_counters) : (i += 1) {
            const meta_offset = i * counters.METADATA_LENGTH;
            const state_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.RECORD_STATE_OFFSET]));
            const state = @atomicLoad(i32, state_ptr, .acquire);

            if (state == counters.RECORD_ALLOCATED) {
                const type_id_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.TYPE_ID_OFFSET]));
                const label_len_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.LABEL_LENGTH_OFFSET]));
                const label_len = @as(usize, @intCast(@max(label_len_ptr.*, 0)));
                const label = self.counters_map.meta_buffer[meta_offset + counters.LABEL_DATA_OFFSET .. meta_offset + counters.LABEL_DATA_OFFSET + label_len];

                const counter_id = @as(i32, @intCast(i));
                const info = CounterInfo{
                    .id = counter_id,
                    .type_id = type_id_ptr.*,
                    .value = self.counters_map.get(counter_id),
                    .label = label,
                };

                handler_fn(info);
                count += 1;
            }
        }
        return count;
    }

    /// Format all allocated counters as a text table.
    pub fn formatTable(self: CountersReport, writer: anytype) !void {
        try writer.print("  ID   TYPE            VALUE LABEL\n", .{});
        try writer.print("---- ------ ---------------- --------------------\n", .{});

        var i: usize = 0;
        while (i < self.counters_map.max_counters) : (i += 1) {
            const meta_offset = i * counters.METADATA_LENGTH;
            const state_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.RECORD_STATE_OFFSET]));
            const state = @atomicLoad(i32, state_ptr, .acquire);

            if (state == counters.RECORD_ALLOCATED) {
                const type_id_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.TYPE_ID_OFFSET]));
                const label_len_ptr: *const i32 = @ptrCast(@alignCast(&self.counters_map.meta_buffer[meta_offset + counters.LABEL_LENGTH_OFFSET]));
                const label_len = @as(usize, @intCast(@max(label_len_ptr.*, 0)));
                const label = self.counters_map.meta_buffer[meta_offset + counters.LABEL_DATA_OFFSET .. meta_offset + counters.LABEL_DATA_OFFSET + label_len];

                const counter_id = @as(i32, @intCast(i));
                const value = self.counters_map.get(counter_id);

                try writer.print("{d:>4} {d:>6} {d:>16} {s}\n", .{ counter_id, type_id_ptr.*, value, label });
            }
        }
    }
};

test "forEach lists allocated counters" {
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(counters.PUBLISHER_LIMIT, "pub-limit");
    cm.set(h1.counter_id, 12345);

    const h2 = cm.allocate(counters.SENDER_POSITION, "sender-pos");
    cm.set(h2.counter_id, 100);

    const report = CountersReport.init(&cm);

    const count = report.forEach(struct {
        fn call(_: CounterInfo) void {}
    }.call);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "formatTable produces readable output" {
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(counters.PUBLISHER_LIMIT, "pub-limit");
    cm.set(h1.counter_id, 12345);

    const h2 = cm.allocate(counters.SENDER_POSITION, "sender-pos");
    cm.set(h2.counter_id, 100);

    const report = CountersReport.init(&cm);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report.formatTable(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "pub-limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sender-pos") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100") != null);
}

test "skip freed counters" {
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(counters.PUBLISHER_LIMIT, "pub-limit");
    _ = cm.allocate(counters.SENDER_POSITION, "sender-pos");

    cm.free(h1.counter_id);

    const report = CountersReport.init(&cm);
    const count = report.forEach(struct {
        fn call(_: CounterInfo) void {}
    }.call);

    try std.testing.expectEqual(@as(usize, 1), count);
}
