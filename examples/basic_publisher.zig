// Basic Publisher Example
// Publishes 100 numbered messages to an IPC channel
const std = @import("std");
const aeron = @import("aeron");
const MediaDriver = aeron.driver.MediaDriver;
const MediaDriverContext = aeron.driver.MediaDriverContext;
const LogBuffer = aeron.logbuffer.LogBuffer;
const ExclusivePublication = aeron.ExclusivePublication;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Basic Publisher ===\n\n", .{});

    // Create and start MediaDriver
    const driver = try MediaDriver.create(allocator, .{});
    defer driver.destroy();
    std.debug.print("MediaDriver created\n", .{});

    // Create a log buffer for the publication
    const term_length = 64 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer allocator.destroy(lb);
    lb.* = try LogBuffer.init(allocator, term_length);
    defer lb.deinit();

    // Initialize metadata
    const initial_term_id = 100;
    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    // Create exclusive publication on stream 1001
    var publication = ExclusivePublication.init(1, 1001, initial_term_id, term_length, 1408, lb);
    publication.publisher_limit = 10 * 1024 * 1024; // Allow 10MB of data

    std.debug.print("Publication created (stream=1001)\n\n", .{});

    // Publish 100 messages
    var buffer: [256]u8 = undefined;
    for (0..100) |i| {
        // Format message as "Hello Aeron #N"
        const msg = try std.fmt.bufPrint(&buffer, "Hello Aeron #{d}", .{i});

        // Offer to publication
        const result = publication.offer(msg);
        switch (result) {
            .ok => |pos| {
                std.debug.print("Published #{d}: \"{s}\" at position {d}\n", .{ i, msg, pos });
            },
            .back_pressure => std.debug.print("Back pressure on message {d}\n", .{i}),
            .not_connected => std.debug.print("No subscribers connected for message {d}\n", .{i}),
            .admin_action => std.debug.print("Admin action on message {d}\n", .{i}),
            .closed => return error.PublicationClosed,
            .max_position_exceeded => return error.MaxPositionExceeded,
        }
    }

    std.debug.print("\n=== Published 100 messages ===\n\n", .{});
}
