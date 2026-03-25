const std = @import("std");
const ReceiveChannelEndpoint = @import("endpoint.zig").ReceiveChannelEndpoint;

pub const Poller = struct {
    fds: std.ArrayList(std.posix.pollfd),
    endpoints: std.ArrayList(*ReceiveChannelEndpoint),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Poller {
        return .{
            .fds = .{
                .items = &.{},
                .capacity = 0,
            },
            .endpoints = .{
                .items = &.{},
                .capacity = 0,
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Poller) void {
        self.fds.deinit(self.allocator);
        self.endpoints.deinit(self.allocator);
    }

    pub fn add(self: *Poller, fd: std.posix.fd_t, endpoint: *ReceiveChannelEndpoint) !void {
        try self.fds.append(self.allocator, .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });
        try self.endpoints.append(self.allocator, endpoint);
    }

    pub fn remove(self: *Poller, fd: std.posix.fd_t) void {
        for (self.fds.items, 0..) |pfd, i| {
            if (pfd.fd == fd) {
                _ = self.fds.swapRemove(i);
                _ = self.endpoints.swapRemove(i);
                return;
            }
        }
    }

    pub fn poll(self: *Poller, timeout_ms: i32) i32 {
        if (self.fds.items.len == 0) return 0;
        const ready_count = std.posix.poll(self.fds.items, timeout_ms) catch return 0;
        return @intCast(ready_count);
    }

    pub fn readyFds(self: *const Poller) []const std.posix.pollfd {
        return self.fds.items;
    }
};

test "Poller.init: starts with no ready fds" {
    var p = Poller.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.readyFds().len);
}
