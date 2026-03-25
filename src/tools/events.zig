// Event log reader.
// Reads and displays driver event log entries (FRAME_IN/OUT, CMD_IN/OUT traces).
// The driver keeps the event log in memory; this tool reads from event.log if persisted,
// or reports that no log file is available.
const std = @import("std");
const event_log_mod = @import("../event_log.zig");
const cnc_mod = @import("../cnc.zig");

fn eventTypeStr(et: event_log_mod.EventType) []const u8 {
    return switch (et) {
        .padding => "padding",
        .frame_in => "frame_in",
        .frame_out => "frame_out",
        .cmd_in => "cmd_in",
        .cmd_out => "cmd_out",
        .send_nak => "send_nak",
        .send_status => "send_status",
        .driver_error => "driver_error",
    };
}

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const desc = cnc_mod.CncDescriptor.init(aeron_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const event_path = desc.eventLogPath(&path_buf);

    stdout.interface.print("Event Log — {s}\n", .{event_path}) catch return;
    stdout.interface.print("=========\n\n", .{}) catch return;
    stdout.interface.print("TIMESTAMP_NS     EVENT_TYPE  SESSION_ID  STREAM_ID  PAYLOAD\n", .{}) catch return;
    stdout.interface.print("------------- ---------- ----------- ---------- -----\n", .{}) catch return;

    // Try to read event.log from the aeron directory
    const file = std.fs.cwd().openFile(event_path, .{}) catch {
        stdout.interface.print("No event log file found at {s}\n", .{event_path}) catch return;
        stdout.interface.print("(driver event log is in-memory; no file was persisted)\n", .{}) catch return;
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        stdout.interface.print("Could not stat event log file.\n", .{}) catch return;
        return;
    };

    if (stat.size == 0) {
        stdout.interface.print("No events recorded.\n", .{}) catch return;
        return;
    }

    const max_bytes = event_log_mod.EVENT_LOG_BUFFER_LENGTH;
    const read_bytes = @min(stat.size, max_bytes);

    const buf = allocator.alloc(u8, read_bytes) catch {
        stdout.interface.print("Could not allocate buffer for event log.\n", .{}) catch return;
        return;
    };
    defer allocator.free(buf);
    @memset(buf, 0);

    _ = file.readAll(buf) catch {
        stdout.interface.print("Could not read event log file.\n", .{}) catch return;
        return;
    };

    const log = event_log_mod.EventLog{ .buffer = buf, .capacity = buf.len, .write_pos = 0 };

    const handler = struct {
        pub fn handle(event_type: event_log_mod.EventType, timestamp_ns: i64, session_id: i32, stream_id: i32, payload: []const u8) void {
            var line_buf: [4096]u8 = undefined;
            var line = std.fs.File.stdout().writer(&line_buf);
            line.interface.print("{d:>13} {s:>10} {d:>11} {d:>10} {s}\n", .{
                timestamp_ns,
                eventTypeStr(event_type),
                session_id,
                stream_id,
                payload,
            }) catch return;
        }
    }.handle;

    const count = log.readAll(&handler);

    if (count == 0) {
        stdout.interface.print("No events recorded.\n", .{}) catch return;
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "events tool: reads real event.log fixture" {
    const allocator = std.testing.allocator;

    const dir_path = "/tmp/harus-aeron-events-tool-test";
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};
    try std.fs.makeDirAbsolute(dir_path);

    const event_path = try std.fmt.allocPrint(allocator, "{s}/event.log", .{dir_path});
    defer allocator.free(event_path);

    // Build event log fixture in memory and write to file
    var buf = [_]u8{0} ** event_log_mod.EVENT_LOG_BUFFER_LENGTH;
    var log = event_log_mod.EventLog.init(&buf);
    log.log(.frame_in, 1_000_000_000, 1, 101, "rx-frame");
    log.log(.cmd_in, 2_000_000_000, 2, 102, "cmd-subscribe");

    {
        const f = try std.fs.cwd().createFile(event_path, .{});
        defer f.close();
        try f.writeAll(&buf);
    }

    // Re-read and verify we can parse the fixture
    const f2 = try std.fs.cwd().openFile(event_path, .{});
    defer f2.close();

    var read_buf = [_]u8{0} ** event_log_mod.EVENT_LOG_BUFFER_LENGTH;
    _ = try f2.readAll(&read_buf);

    const log2 = event_log_mod.EventLog{ .buffer = &read_buf, .capacity = read_buf.len, .write_pos = 0 };

    var count: usize = 0;
    const counter = struct {
        pub fn handle(_: event_log_mod.EventType, _: i64, _: i32, _: i32, _: []const u8) void {
            // noop — we just want the count returned
        }
    }.handle;
    count = log2.readAll(&counter);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "events tool: eventLogPath uses event.log filename" {
    const desc = cnc_mod.CncDescriptor.init("/tmp/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.eventLogPath(&buf);
    try std.testing.expectEqualStrings("/tmp/aeron/event.log", path);
}
