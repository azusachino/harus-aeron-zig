// Loss report reader.
// Displays per-stream gap statistics from the loss report.
const std = @import("std");
const loss_report_mod = @import("../loss_report.zig");

pub fn run(_: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    // Placeholder: working in-memory loss report until CnC mmap is implemented
    var buffer align(64) = [_]u8{0} ** loss_report_mod.LOSS_REPORT_BUFFER_LENGTH;
    var report = loss_report_mod.LossReport.init(&buffer);

    // Seed with sample loss entries for display
    report.recordObservation(1024, 100_000_000, 1, 101, "aeron:udp");
    report.recordObservation(512, 200_000_000, 1, 101, "aeron:udp");
    report.recordObservation(2048, 300_000_000, 2, 102, "aeron:ipc");

    stdout.interface.print("Loss Report\n", .{}) catch return;
    stdout.interface.print("===========\n\n", .{}) catch return;
    stdout.interface.print("SES STREAM    OBSERVATIONS   TOTAL_BYTES_LOST  FIRST_NS       LAST_NS\n", .{}) catch return;
    stdout.interface.print("--- ------ ----------- ----------- ----------- -----------\n", .{}) catch return;

    var i: usize = 0;
    while (i < report.max_entries) : (i += 1) {
        if (report.entry(i)) |e| {
            const channel_str = if (e.channel_len > 0)
                e.channel[0..@as(usize, @intCast(e.channel_len))]
            else
                "";
            stdout.interface.print("{d:>3} {d:>6} {d:>11} {d:>16} {d:>12} {d:>12} {s}\n", .{
                e.session_id,
                e.stream_id,
                e.observation_count,
                e.total_bytes_lost,
                e.first_observation_ns,
                e.last_observation_ns,
                channel_str,
            }) catch return;
        }
    }

    if (report.entryCount() == 0) {
        stdout.interface.print("No packet losses recorded.\n", .{}) catch return;
    }
}
