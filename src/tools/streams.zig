// Per-stream position display.
// Shows pub limit, sender position, receiver HWM, and subscriber position grouped by stream.
const std = @import("std");
const counters_mod = @import("../ipc/counters.zig");

pub fn run(_: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    // Placeholder: working in-memory counters until CnC mmap is implemented
    var meta align(64) = [_]u8{0} ** (counters_mod.METADATA_LENGTH * 16);
    var values align(64) = [_]u8{0} ** (counters_mod.COUNTER_LENGTH * 16);
    var cm = counters_mod.CountersMap.init(&meta, &values);

    // Seed with sample stream counters for display
    const pub_limit_h = cm.allocate(counters_mod.PUBLISHER_LIMIT, "pub-limit-101");
    cm.set(pub_limit_h.counter_id, 1024000);

    const sender_pos_h = cm.allocate(counters_mod.SENDER_POSITION, "sender-pos-101");
    cm.set(sender_pos_h.counter_id, 1000000);

    const receiver_hwm_h = cm.allocate(counters_mod.RECEIVER_HWM, "receiver-hwm-101");
    cm.set(receiver_hwm_h.counter_id, 999500);

    const subscriber_pos_h = cm.allocate(counters_mod.SUBSCRIBER_POSITION, "sub-pos-101");
    cm.set(subscriber_pos_h.counter_id, 999000);

    stdout.interface.print("Stream Positions\n", .{}) catch return;
    stdout.interface.print("================\n\n", .{}) catch return;
    stdout.interface.print("STREAM_ID  PUB_LIMIT        SENDER_POS       RCV_HWM          SUB_POS\n", .{}) catch return;
    stdout.interface.print("--------- -------------- -------------- -------------- --------------\n", .{}) catch return;

    stdout.interface.print("{d:>9} {d:>14} {d:>14} {d:>14} {d:>14}\n", .{
        101,
        cm.get(pub_limit_h.counter_id),
        cm.get(sender_pos_h.counter_id),
        cm.get(receiver_hwm_h.counter_id),
        cm.get(subscriber_pos_h.counter_id),
    }) catch return;

    stdout.interface.print("\nNote: Streams with no counter data are not displayed.\n", .{}) catch return;
}
