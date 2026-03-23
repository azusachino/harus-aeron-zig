// Interop Smoke Test: Zig Publisher
const std = @import("std");
const aeron = @import("aeron");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const aeron_dir = std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron";
    std.debug.print("[ZIG] Connecting to Aeron at {s}...\n", .{aeron_dir});

    var client: aeron.Aeron = while (true) {
        if (aeron.Aeron.init(allocator, .{ .aeron_dir = aeron_dir })) |c| {
            break c;
        } else |err| {
            if (err == error.FileNotFound) {
                std.debug.print("[ZIG] CnC.dat not found, retrying...\n", .{});
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            }
            std.debug.print("[ZIG] Failed to init Aeron: {}\n", .{err});
            return err;
        }
    };
    defer client.deinit();
    std.debug.print("[ZIG] Aeron client initialized.\n", .{});

    const stream_id = 1001;
    const channel = "aeron:udp?endpoint=localhost:40124";
    
    const registration_id = try client.addPublication(channel, stream_id);
    std.debug.print("[ZIG] Publication requested, registration_id={d}\n", .{registration_id});

    var timer = try std.time.Timer.start();
    const timeout_ns = 60 * std.time.ns_per_s;

    std.debug.print("[ZIG] Polling for ready response (60s timeout)...\n", .{});
    while (timer.read() < timeout_ns) {
        const work = client.doWork();
        if (work > 0) {
            std.debug.print("[ZIG] Received {d} responses from conductor!\n", .{work});
            std.debug.print("[ZIG] SUCCESS: Interop handshake complete.\n", .{});
            return;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    std.debug.print("[ZIG] ERROR: Timeout waiting for conductor response.\n", .{});
    std.process.exit(1);
}
