// Basic Publisher Example
// Publishes 100 numbered messages to an IPC channel using the high-level Aeron API
const std = @import("std");
const aeron = @import("aeron");
const Aeron = aeron.Aeron;
const MediaDriver = aeron.driver.MediaDriver;

pub fn main() !void {
    // ZIG: GeneralPurposeAllocator tracks memory allocations and detects leaks on deinit.
    // AERON: Clients need an allocator for CnC.dat mapping and internal Publication/Subscription handles.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Basic Publisher ===\n\n", .{});

    // ZIG: MediaDriver.create spawns the driver agents (Conductor, Sender, Receiver).
    // AERON: The driver is the "server" that manages shared memory and network I/O.
    // Usually it runs as a separate process, but here we run it embedded for simplicity.
    const aeron_dir = "/tmp/aeron-publisher";
    const driver = try MediaDriver.create(allocator, .{ .aeron_dir = aeron_dir });
    try driver.start();
    defer {
        driver.close();
        driver.destroy();
    }
    std.debug.print("MediaDriver started in background threads at {s}\n", .{aeron_dir});

    // ZIG: Aeron.init mmaps CnC.dat and resolves the shared-memory ring buffers.
    // AERON: This is the client "connecting" to the driver. No TCP handshake — just mapping a file.
    var client = try Aeron.init(allocator, .{ .aeron_dir = aeron_dir });
    defer client.deinit();
    client.embedded_driver = driver; // ZIG: Link to embedded driver so doWork can resolve log buffers.

    // ZIG: addPublication writes a CMD_ADD_PUBLICATION message to the to-driver ring buffer.
    // AERON: The Conductor will see this and allocate a session ID and log buffer file.
    const registration_id = try client.addPublication("aeron:ipc", 1001);
    std.debug.print("Publication requested (stream=1001, reg_id={d})\n", .{registration_id});

    // ZIG: Wait for the Conductor to respond via the broadcast buffer.
    // AERON: We must poll doWork() to see the RESPONSE_ON_PUBLICATION_READY event.
    var publication: ?*aeron.ExclusivePublication = null;
    var timer = try std.time.Timer.start();
    while (publication == null and timer.read() < 10 * std.time.ns_per_s) {
        _ = client.doWork();
        publication = client.getPublication(registration_id);
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (publication == null) {
        std.debug.print("Timed out waiting for publication to be ready.\n", .{});
        return;
    }
    std.debug.print("Publication ready!\n\n", .{});

    const pub_instance = publication.?;

    // Publish 100 messages
    var buffer: [256]u8 = undefined;
    var publish_timer = try std.time.Timer.start();
    var i: u32 = 0;
    while (i < 100 and publish_timer.read() < 10 * std.time.ns_per_s) {
        _ = client.doWork(); // Poll for connection updates

        // ZIG: bufPrint formats strings into a fixed-size stack buffer to avoid allocation.
        // AERON: Aeron messages are just byte slices; the protocol doesn't care about content.
        const msg = try std.fmt.bufPrint(&buffer, "Hello Aeron #{d}", .{i});

        // ZIG: offer() checks the volatile tail position and writes to the log buffer.
        // AERON: This is a non-blocking operation. It returns .back_pressure if the log is full.
        const result = pub_instance.offer(msg);
        switch (result) {
            .ok => |pos| {
                std.debug.print("Published #{d}: \"{s}\" at position {d}\n", .{ i, msg, pos });
                i += 1;
            },
            .back_pressure => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            },
            .not_connected => {
                // IPC needs a subscriber to connect
                std.Thread.sleep(10 * std.time.ns_per_ms);
            },
            else => |r| {
                std.debug.print("Error publishing message {d}: {any}\n", .{ i, r });
                return;
            },
        }
    }

    if (i < 100) {
        std.debug.print("\nTimed out waiting for connection or backpressure (i={d}, connected={}).\n", .{ i, pub_instance.isConnected() });
    } else {
        std.debug.print("\n=== Published 100 messages ===\n\n", .{});
    }
}
