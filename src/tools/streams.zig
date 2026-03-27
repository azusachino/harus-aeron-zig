// Per-stream position display.
// Shows pub limit, sender position, receiver HWM, and subscriber position grouped by stream.
const std = @import("std");
const cnc_mod = @import("../cnc.zig");
const counters_mod = @import("../ipc/counters.zig");

const StreamPositions = struct {
    session_id: i32,
    stream_id: i32,
    publisher_limit: ?i64 = null,
    sender_position: ?i64 = null,
    receiver_hwm: ?i64 = null,
    subscriber_position: ?i64 = null,
};

const StreamKey = struct {
    session_id: i32,
    stream_id: i32,
};

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const desc = cnc_mod.CncDescriptor.init(aeron_dir);
    var mapped = desc.openMappedCounters(allocator) catch |err| {
        stdout.interface.print("Error: could not open live CnC counters from {s}: {any}\n", .{ aeron_dir, err }) catch return;
        return;
    };
    defer mapped.deinit();

    var streams = std.ArrayList(StreamPositions){};
    defer streams.deinit(allocator);

    stdout.interface.print("Stream Positions\n", .{}) catch return;
    stdout.interface.print("================\n\n", .{}) catch return;
    stdout.interface.print("SESSION  STREAM_ID      PUB_LIMIT     SENDER_POS        RCV_HWM        SUB_POS\n", .{}) catch return;
    stdout.interface.print("------- ---------- -------------- -------------- -------------- --------------\n", .{}) catch return;

    var counter_id: usize = 0;
    while (counter_id < mapped.counters_map.max_counters) : (counter_id += 1) {
        const meta_offset = counter_id * counters_mod.METADATA_LENGTH;
        const state_ptr: *const i32 = @ptrCast(@alignCast(&mapped.counters_map.meta_buffer[meta_offset + counters_mod.RECORD_STATE_OFFSET]));
        const state = @atomicLoad(i32, state_ptr, .acquire);
        if (state != counters_mod.RECORD_ALLOCATED) continue;

        const type_id_ptr: *const i32 = @ptrCast(@alignCast(&mapped.counters_map.meta_buffer[meta_offset + counters_mod.TYPE_ID_OFFSET]));
        const parsed = parseStreamCounterKey(mapped.counters_map.meta_buffer[meta_offset..]) orelse blk: {
            const label_len_ptr: *const i32 = @ptrCast(@alignCast(&mapped.counters_map.meta_buffer[meta_offset + counters_mod.LABEL_LENGTH_OFFSET]));
            const label_len = @as(usize, @intCast(@max(label_len_ptr.*, 0)));
            const label = mapped.counters_map.meta_buffer[meta_offset + counters_mod.LABEL_DATA_OFFSET .. meta_offset + counters_mod.LABEL_DATA_OFFSET + label_len];
            break :blk parseSessionStreamLabel(label) orelse continue;
        };
        const value = mapped.counters_map.get(@as(i32, @intCast(counter_id)));

        var found_index: ?usize = null;
        for (streams.items, 0..) |entry, i| {
            if (entry.session_id == parsed.session_id and entry.stream_id == parsed.stream_id) {
                found_index = i;
                break;
            }
        }

        if (found_index == null) {
            streams.append(allocator, .{
                .session_id = parsed.session_id,
                .stream_id = parsed.stream_id,
            }) catch return;
            found_index = streams.items.len - 1;
        }

        var entry = &streams.items[found_index.?];
        switch (type_id_ptr.*) {
            counters_mod.PUBLISHER_LIMIT => entry.publisher_limit = value,
            counters_mod.SENDER_POSITION => entry.sender_position = value,
            counters_mod.RECEIVER_HWM => entry.receiver_hwm = value,
            counters_mod.SUBSCRIBER_POSITION => entry.subscriber_position = value,
            else => {},
        }
    }

    if (streams.items.len == 0) {
        stdout.interface.print("No stream-scoped counters found in CnC.dat.\n", .{}) catch return;
        return;
    }

    for (streams.items) |entry| {
        var pub_limit_buf: [32]u8 = undefined;
        var sender_pos_buf: [32]u8 = undefined;
        var receiver_hwm_buf: [32]u8 = undefined;
        var subscriber_pos_buf: [32]u8 = undefined;
        stdout.interface.print("{d:>7} {d:>10} {s:>14} {s:>14} {s:>14} {s:>14}\n", .{
            entry.session_id,
            entry.stream_id,
            formatOptionalI64(&pub_limit_buf, entry.publisher_limit),
            formatOptionalI64(&sender_pos_buf, entry.sender_position),
            formatOptionalI64(&receiver_hwm_buf, entry.receiver_hwm),
            formatOptionalI64(&subscriber_pos_buf, entry.subscriber_position),
        }) catch return;
    }
}

fn parseSessionStreamLabel(label: []const u8) ?StreamKey {
    const colon = std.mem.lastIndexOfScalar(u8, label, ':') orelse return null;
    const prev_colon = std.mem.lastIndexOfScalar(u8, label[0..colon], ':') orelse return null;

    const session_str = std.mem.trim(u8, label[prev_colon + 1 .. colon], " ");
    const stream_str = std.mem.trim(u8, label[colon + 1 ..], " ");

    return .{
        .session_id = std.fmt.parseInt(i32, session_str, 10) catch return null,
        .stream_id = std.fmt.parseInt(i32, stream_str, 10) catch return null,
    };
}

fn parseStreamCounterKey(meta_record: []const u8) ?StreamKey {
    if (meta_record.len < counters_mod.METADATA_LENGTH) return null;
    const session_id = std.mem.readInt(i32, meta_record[counters_mod.KEY_OFFSET + counters_mod.STREAM_COUNTER_SESSION_ID_OFFSET ..][0..4], .little);
    const stream_id = std.mem.readInt(i32, meta_record[counters_mod.KEY_OFFSET + counters_mod.STREAM_COUNTER_STREAM_ID_OFFSET ..][0..4], .little);
    return .{ .session_id = session_id, .stream_id = stream_id };
}

fn formatOptionalI64(buf: []u8, value: ?i64) []const u8 {
    return if (value) |v|
        std.fmt.bufPrint(buf, "{d}", .{v}) catch "?"
    else
        "-";
}

test "parseSessionStreamLabel parses session and stream ids" {
    const parsed = parseSessionStreamLabel("sender-pos: 7:1001").?;
    try std.testing.expectEqual(@as(i32, 7), parsed.session_id);
    try std.testing.expectEqual(@as(i32, 1001), parsed.stream_id);
}

test "parseSessionStreamLabel rejects labels without session and stream suffix" {
    try std.testing.expect(parseSessionStreamLabel("pub-limit") == null);
}

test "parseStreamCounterKey reads session and stream ids from metadata key" {
    var record = [_]u8{0} ** counters_mod.METADATA_LENGTH;
    std.mem.writeInt(i32, record[counters_mod.KEY_OFFSET + counters_mod.STREAM_COUNTER_SESSION_ID_OFFSET ..][0..4], 7, .little);
    std.mem.writeInt(i32, record[counters_mod.KEY_OFFSET + counters_mod.STREAM_COUNTER_STREAM_ID_OFFSET ..][0..4], 1001, .little);

    const parsed = parseStreamCounterKey(&record).?;
    try std.testing.expectEqual(@as(i32, 7), parsed.session_id);
    try std.testing.expectEqual(@as(i32, 1001), parsed.stream_id);
}
