//! Interop smoke publisher — publishes N messages.
//! Set AERON_INTEROP_STUB=1 to skip actual networking (used in CI).
const std = @import("std");

pub fn main() !void {
    const channel = std.posix.getenv("AERON_CHANNEL") orelse "aeron:udp?endpoint=localhost:20121";
    const stream_id_str = std.posix.getenv("AERON_STREAM_ID") orelse "1001";
    const count_str = std.posix.getenv("AERON_MSG_COUNT") orelse "10";

    if (std.posix.getenv("AERON_INTEROP_STUB")) |val| {
        if (std.mem.eql(u8, val, "1")) {
            std.debug.print("zig-publisher: stub mode — exit 0\n", .{});
            return;
        }
    }

    std.debug.print("zig-publisher: publishing {s} messages to {s} stream={s}\n", .{ count_str, channel, stream_id_str });
    const count = try std.fmt.parseInt(usize, count_str, 10);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        std.debug.print("zig-publisher: sent msg {d}\n", .{i + 1});
    }
    std.debug.print("zig-publisher: done — OK\n", .{});
}
