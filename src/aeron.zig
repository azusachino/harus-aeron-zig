// Aeron client library root
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub const protocol = @import("protocol/frame.zig");
pub const logbuffer = @import("logbuffer/log_buffer.zig");
pub const ipc = @import("ipc.zig");
pub const driver = @import("driver/media_driver.zig");
pub const archive = struct {
    pub const protocol = @import("archive/protocol.zig");
    pub const catalog = @import("archive/catalog.zig");
    pub const conductor = @import("archive/conductor.zig");
    pub const recorder = @import("archive/recorder.zig");
    pub const replayer = @import("archive/replayer.zig");
};
pub const transport = struct {
    pub const ReceiveChannelEndpoint = @import("transport/endpoint.zig").ReceiveChannelEndpoint;
    pub const Poller = @import("transport/poller.zig").Poller;
    pub const UdpChannel = @import("transport/udp_channel.zig").UdpChannel;
};

pub const ExclusivePublication = @import("publication.zig").ExclusivePublication;
pub const Subscription = @import("subscription.zig").Subscription;
pub const Image = @import("image.zig").Image;

pub const AeronContext = struct {
    aeron_dir: []const u8 = "/dev/shm/aeron",
};

pub const Aeron = struct {
    ctx: AeronContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: AeronContext) !Aeron {
        return .{ .ctx = ctx, .allocator = allocator };
    }
    pub fn deinit(_: *Aeron) void {}
    pub fn doWork(_: *Aeron) i32 {
        return 0;
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "Aeron init and deinit" {
    const allocator = std.testing.allocator;
    var aeron = try Aeron.init(allocator, .{});
    defer aeron.deinit();
    try std.testing.expectEqual(@as(i32, 0), aeron.doWork());
}
