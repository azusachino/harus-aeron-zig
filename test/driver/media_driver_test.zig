// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/MediaDriverTest.java
// Aeron version: 1.46.7
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
    try dir_mutable.access("CnC.dat", .{});
}
