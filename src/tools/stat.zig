// Live counters display with ANSI refresh.
// Displays counters every second until Ctrl+C.
const std = @import("std");
const time = @import("../time.zig");
const cnc_mod = @import("../cnc.zig");
const counters_report = @import("../counters_report.zig");
const io_mod = @import("../io.zig");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io_mod.io(), &stdout_buf);
    var gpa = std.heap.DebugAllocator(.{}){};
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
        stdout.interface.print("Refreshed at {:0>8}\n\n", .{time.nanoTimestamp()}) catch return;
        report.formatTable(&stdout.interface) catch return;
        stdout.interface.print("\nRefreshing every 1s... (Ctrl+C to stop)\n", .{}) catch return;

        var ts: std.c.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.c.nanosleep(&ts, null);
    }
}
