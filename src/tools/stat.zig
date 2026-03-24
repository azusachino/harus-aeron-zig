// Live counters display with ANSI refresh.
// Displays counters every second until Ctrl+C.
const std = @import("std");
const cnc_mod = @import("../cnc.zig");
const counters_report = @import("../counters_report.zig");

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

    const report = counters_report.CountersReport.init(&mapped.counters_map);

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
