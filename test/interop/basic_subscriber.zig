// Interop Smoke Test: Zig Subscriber (with embedded MediaDriver)
const std = @import("std");
const aeron = @import("aeron");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const aeron_dir = std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron";
    const listen_port_env = std.posix.getenv("LISTEN_PORT");
    const listen_port = if (listen_port_env) |p| try std.fmt.parseInt(u16, p, 10) else 0;

    std.debug.print("[ZIG] Starting embedded Media Driver at {s} (listen_port={d})...\n", .{ aeron_dir, listen_port });

    var md = try aeron.driver.MediaDriver.create(allocator, .{ .aeron_dir = aeron_dir, .listen_port = listen_port });
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

    const registration_id = try client.addSubscription(channel, stream_id);
    std.debug.print("[ZIG] Subscription requested, registration_id={d}\n", .{registration_id});

    var timer = try std.time.Timer.start();
    const timeout_ns = 30 * std.time.ns_per_s;

    std.debug.print("[ZIG] Waiting for subscription to be connected and receive messages...\n", .{});
    var messages_received: usize = 0;

    const handler = struct {
        fn handle(header: *const aeron.protocol.DataHeader, buffer: []const u8, ctx: *anyopaque) void {
            const count_ptr = @as(*usize, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
            if (count_ptr.* % 10 == 0) std.debug.print("[ZIG] Received {d} messages (latest: {s}, session={d})\n", .{ count_ptr.*, buffer, header.session_id });
        }
    }.handle;

    while (timer.read() < timeout_ns and messages_received < 100) {
        _ = client.doWork();
        const fragments = client.poll(registration_id, handler, &messages_received, 10);
        if (fragments == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    if (messages_received >= 100) {
        std.debug.print("[ZIG] SUCCESS: Received {d} messages.\n", .{messages_received});
    } else {
        std.debug.print("[ZIG] ERROR: Timeout waiting for messages (received {d}/100).\n", .{messages_received});
        std.process.exit(1);
    }
}
