// Event log reader.
// Reads and displays driver event log entries (FRAME_IN/OUT, CMD_IN/OUT traces).
const std = @import("std");
const event_log_mod = @import("../event_log.zig");

pub fn run(_: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    // Placeholder: working in-memory event log until CnC mmap is implemented
    var buffer = [_]u8{0} ** event_log_mod.EVENT_LOG_BUFFER_LENGTH;
    var log = event_log_mod.EventLog.init(&buffer);

    // Seed with sample events for display
    log.log(.frame_in, 1000000000, 1, 101, "rx-frame-123");
    log.log(.frame_out, 2000000000, 1, 101, "tx-frame-456");
    log.log(.cmd_in, 3000000000, 2, 102, "cmd-subscribe");
    log.log(.cmd_out, 4000000000, 2, 102, "resp-ok");

    stdout.interface.print("Event Log\n", .{}) catch return;
    stdout.interface.print("=========\n\n", .{}) catch return;
    stdout.interface.print("TIMESTAMP_NS     EVENT_TYPE  SESSION_ID  STREAM_ID  PAYLOAD\n", .{}) catch return;
    stdout.interface.print("------------- ---------- ----------- ---------- -----\n", .{}) catch return;

    const eventTypeStr = struct {
        fn str(et: event_log_mod.EventType) []const u8 {
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
    }.str;

    const handler = struct {
        pub fn handle(event_type: event_log_mod.EventType, timestamp_ns: i64, session_id: i32, stream_id: i32, payload: []const u8) void {
            var stdout2_buf: [4096]u8 = undefined;
            var stdout2 = std.fs.File.stdout().writer(&stdout2_buf);
            stdout2.interface.print("{d:>13} {s:>10} {d:>11} {d:>10} {s}\n", .{
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
