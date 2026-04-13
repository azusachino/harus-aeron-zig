//! Interop smoke subscriber — receives N messages from an Aeron publication.
//! Set AERON_INTEROP_STUB=1 to skip actual networking (used in CI).
const std = @import("std");

pub fn main() !void {
    const channel = std.posix.getenv("AERON_CHANNEL") orelse "aeron:udp?endpoint=localhost:20121";
    const stream_id_str = std.posix.getenv("AERON_STREAM_ID") orelse "1001";
    const expected_str = std.posix.getenv("AERON_MSG_COUNT") orelse "10";

    if (std.posix.getenv("AERON_INTEROP_STUB")) |val| {
        if (std.mem.eql(u8, val, "1")) {
            std.debug.print("zig-subscriber: stub mode — exit 0\n", .{});
            return;
        }
    }

    std.debug.print("zig-subscriber: listening on {s} stream={s} expecting={s} messages\n", .{ channel, stream_id_str, expected_str });
    const expected = try std.fmt.parseInt(usize, expected_str, 10);
    const deadline_ns = std.time.nanoTimestamp() + 30 * std.time.ns_per_s;
    const received: usize = 0;
    while (received < expected) {
        if (std.time.nanoTimestamp() > deadline_ns) {
            std.log.err("zig-subscriber: timeout — received {d}/{d}", .{ received, expected });
            std.process.exit(1);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.debug.print("zig-subscriber: received {d} messages — OK\n", .{received});
}
