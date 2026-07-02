// Loss report reader.
// Displays per-stream gap statistics from loss-report.dat in the aeron directory.
// If the file does not exist or has no entries, reports that clearly.
const std = @import("std");
const loss_report_mod = @import("../loss_report.zig");
const cnc_mod = @import("../cnc.zig");
const io_mod = @import("../io.zig");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io_mod.io(), &stdout_buf);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const desc = cnc_mod.CncDescriptor.init(aeron_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loss_path = desc.lossReportPath(&path_buf);

    stdout.interface.print("Loss Report — {s}\n", .{loss_path}) catch return;
    stdout.interface.print("===========\n\n", .{}) catch return;

    // Try to read loss-report.dat as a flat binary file (array of LossEntry structs).
    const file = std.Io.Dir.cwd().openFile(io_mod.io(), loss_path, .{}) catch {
        stdout.interface.print("No loss report file found at {s}\n", .{loss_path}) catch return;
        stdout.interface.print("(driver may not be running or no gaps have been observed)\n", .{}) catch return;
        return;
    };
    defer file.close(io_mod.io());

    const stat = file.stat(io_mod.io()) catch {
        stdout.interface.print("Could not stat loss report file.\n", .{}) catch return;
        return;
    };

    if (stat.size == 0 or stat.size < @sizeOf(loss_report_mod.LossEntry)) {
        stdout.interface.print("No packet losses recorded.\n", .{}) catch return;
        return;
    }

    const max_bytes = loss_report_mod.LOSS_REPORT_BUFFER_LENGTH;
    const read_bytes = @min(stat.size, max_bytes);

    // Allocate aligned buffer and read file contents
    const buf = allocator.alignedAlloc(u8, .@"64", read_bytes) catch {
        stdout.interface.print("Could not allocate buffer for loss report.\n", .{}) catch return;
        return;
    };
    defer allocator.free(buf);
    @memset(buf, 0);

    const n = file.readPositionalAll(io_mod.io(), buf, 0) catch {
        stdout.interface.print("Could not read loss report file.\n", .{}) catch return;
        return;
    };
    if (n < @sizeOf(loss_report_mod.LossEntry)) {
        stdout.interface.print("No packet losses recorded.\n", .{}) catch return;
        return;
    }

    const report = loss_report_mod.LossReport.init(buf);

    stdout.interface.print("SES STREAM    OBSERVATIONS   TOTAL_BYTES_LOST  FIRST_NS       LAST_NS        CHANNEL\n", .{}) catch return;
    stdout.interface.print("--- ------ ----------- ----------- ----------- ----------- ----------\n", .{}) catch return;

    var found: usize = 0;
    var i: usize = 0;
    while (i < report.max_entries) : (i += 1) {
        if (report.entry(i)) |e| {
            const channel_str = if (e.channel_len > 0)
                e.channel[0..@as(usize, @intCast(@min(e.channel_len, 20)))]
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
            found += 1;
        }
    }

    if (found == 0) {
        stdout.interface.print("No packet losses recorded.\n", .{}) catch return;
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "loss tool: reads real loss-report.dat fixture" {
    const allocator = std.testing.allocator;

    // Write a loss-report fixture to a temp file
    const dir_path = "/tmp/harus-aeron-loss-tool-test";
    defer std.Io.Dir.cwd().deleteTree(io_mod.io(), dir_path) catch {};
    try std.Io.Dir.createDirAbsolute(io_mod.io(), dir_path, .default_dir);

    const loss_path = try std.fmt.allocPrint(allocator, "{s}/loss-report.dat", .{dir_path});
    defer allocator.free(loss_path);

    // Build a LossReport in memory, then write to the fixture file
    var buf align(64) = [_]u8{0} ** loss_report_mod.LOSS_REPORT_BUFFER_LENGTH;
    var report = loss_report_mod.LossReport.init(&buf);
    report.recordObservation(1024, 100_000_000, 1, 101, "aeron:udp");
    report.recordObservation(512, 200_000_000, 2, 102, "aeron:ipc");

    {
        const f = try std.Io.Dir.cwd().createFile(io_mod.io(), loss_path, .{});
        defer f.close(io_mod.io());
        try f.writeStreamingAll(io_mod.io(), &buf);
    }

    // Verify we can open and parse the fixture
    const f2 = try std.Io.Dir.cwd().openFile(io_mod.io(), loss_path, .{});
    defer f2.close(io_mod.io());

    var read_buf align(64) = [_]u8{0} ** loss_report_mod.LOSS_REPORT_BUFFER_LENGTH;
    const n = try f2.readPositionalAll(io_mod.io(), &read_buf, 0);
    try std.testing.expect(n >= @sizeOf(loss_report_mod.LossEntry));

    const r2 = loss_report_mod.LossReport.init(&read_buf);
    try std.testing.expectEqual(@as(usize, 2), r2.entryCount());
    try std.testing.expectEqual(@as(i32, 1), r2.entry(0).?.session_id);
    try std.testing.expectEqual(@as(i32, 2), r2.entry(1).?.session_id);
}

test "loss tool: no loss-report.dat returns gracefully" {
    // Ensure we handle missing file without panic — just verify the path construction
    const desc = cnc_mod.CncDescriptor.init("/tmp/nonexistent-aeron-dir");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loss_path = desc.lossReportPath(&path_buf);
    try std.testing.expect(std.mem.indexOf(u8, loss_path, "loss-report.dat") != null);
}
