// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/MediaDriverTest.java
// Aeron version: 1.50.2
// Coverage: media driver init, directory creation, CNC file allocation

const std = @import("std");
const aeron = @import("aeron");

test "MediaDriver: create and destroy" {
    const allocator = std.testing.allocator;
    const ctx = aeron.driver.MediaDriverContext{
        .aeron_dir = "/tmp/aeron-test-driver",
    };
    // Ensure clean state
    std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    const md = try aeron.driver.MediaDriver.create(allocator, ctx);
    defer md.destroy();

    try std.testing.expect(md.cnc != null);

    const dir = try std.fs.openDirAbsolute(ctx.aeron_dir, .{});
    var dir_mutable = dir;
    defer dir_mutable.close();
    try dir_mutable.access("cnc.dat", .{});
}

test "MediaDriver: conductor doWork cycle executes" {
    const allocator = std.testing.allocator;
    const ctx = aeron.driver.MediaDriverContext{
        .aeron_dir = "/tmp/aeron-test-driver-conduct",
    };
    // Ensure clean state
    std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    const md = try aeron.driver.MediaDriver.create(allocator, ctx);
    defer md.destroy();

    // Verify conductor exists
    try std.testing.expect(md.conductor_agent != null);

    // Run conductor duty cycle multiple times
    var total_work: i32 = 0;
    for (0..5) |_| {
        total_work += md.conductor_agent.doWork();
    }

    // At least conductor should run (may have 0 work, but should not crash)
    try std.testing.expect(total_work >= 0);
}

test "MediaDriver: sender and receiver accessible" {
    const allocator = std.testing.allocator;
    const ctx = aeron.driver.MediaDriverContext{
        .aeron_dir = "/tmp/aeron-test-driver-agents",
    };
    // Ensure clean state
    std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    const md = try aeron.driver.MediaDriver.create(allocator, ctx);
    defer md.destroy();

    // Verify agents are accessible
    try std.testing.expect(md.conductor_agent != null);
    try std.testing.expect(md.sender_agent != null);
    try std.testing.expect(md.receiver_agent != null);

    // Run one duty cycle for each agent
    _ = md.conductor_agent.doWork();
    _ = md.sender_agent.doWork();
    _ = try md.receiver_agent.doWork();
}
