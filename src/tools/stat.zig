// Live counters display with ANSI refresh.
// Displays counters every second until Ctrl+C.
const std = @import("std");
const counters_mod = @import("../ipc/counters.zig");
const counters_report = @import("../counters_report.zig");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    // Placeholder: working in-memory counters until CnC mmap is implemented
    var meta align(64) = [_]u8{0} ** (counters_mod.METADATA_LENGTH * 8);
    var values align(64) = [_]u8{0} ** (counters_mod.COUNTER_LENGTH * 8);
    var cm = counters_mod.CountersMap.init(&meta, &values);

    // Seed with sample counters for display
    const h1 = cm.allocate(counters_mod.PUBLISHER_LIMIT, "pub-limit");
    cm.set(h1.counter_id, 0);
    const h2 = cm.allocate(counters_mod.SENDER_POSITION, "sender-pos");
    cm.set(h2.counter_id, 0);
    const h3 = cm.allocate(counters_mod.RECEIVER_HWM, "receiver-hwm");
    cm.set(h3.counter_id, 0);

    const report = counters_report.CountersReport.init(&cm);

    while (true) {
        // ANSI: clear screen, move cursor to top-left
        stdout.interface.print("\x1b[2J\x1b[H", .{}) catch return;
        stdout.interface.print("Aeron Stat — {s}\n", .{aeron_dir}) catch return;
        stdout.interface.print("Refreshed at {:0>8}\n\n", .{std.time.nanoTimestamp()}) catch return;
        report.formatTable(&stdout.interface) catch return;
        stdout.interface.print("\nRefreshing every 1s... (Ctrl+C to stop)\n", .{}) catch return;

        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
