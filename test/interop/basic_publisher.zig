// Interop Smoke Test: Zig Publisher (with embedded MediaDriver)
const std = @import("std");
const aeron = @import("aeron");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const aeron_dir = std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron";
    std.debug.print("[ZIG] Starting embedded Media Driver at {s}...\n", .{aeron_dir});

    var md = try aeron.driver.MediaDriver.create(allocator, .{ .aeron_dir = aeron_dir });
    try md.start();
    defer {
        md.close();
        md.destroy();
    }
    std.debug.print("[ZIG] Media Driver started.\n", .{});

    var client = try aeron.Aeron.init(allocator, .{ .aeron_dir = aeron_dir });
    client.embedded_driver = md;
    defer client.deinit();
    std.debug.print("[ZIG] Aeron client initialized.\n", .{});

    const stream_id = 1001;
    const channel = "aeron:udp?endpoint=127.0.0.1:40124";

    const registration_id = try client.addPublication(channel, stream_id);
    std.debug.print("[ZIG] Publication requested, registration_id={d}\n", .{registration_id});

    var timer = try std.time.Timer.start();
    const timeout_ns = 60 * std.time.ns_per_s;

    std.debug.print("[ZIG] Waiting for publication to be connected...\n", .{});
    var pub_instance: ?*aeron.ExclusivePublication = null;
    while (timer.read() < timeout_ns) {
        _ = client.doWork();
        if (client.getPublication(registration_id)) |p| {
            pub_instance = p;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (pub_instance) |p| {
        std.debug.print("[ZIG] Publication connected! Sending 100 messages...\n", .{});
        var i: usize = 0;
        while (i < 100) {
            var msg_buf: [32]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "Hello Aeron {d}", .{i});
            const result = p.offer(msg);
            switch (result) {
                .ok => {
                    i += 1;
                    if (i % 10 == 0) std.debug.print("[ZIG] Sent {d} messages...\n", .{i});
                },
                .back_pressure => {
                    _ = client.doWork();
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                },
                else => {
                    std.debug.print("[ZIG] ERROR: offer failed with {any}\n", .{result});
                    std.process.exit(1);
                },
            }
        }
        std.debug.print("[ZIG] SUCCESS: Sent 100 messages.\n", .{});
    } else {
        std.debug.print("[ZIG] ERROR: Timeout waiting for publication.\n", .{});
        std.process.exit(1);
    }
}
