// EXERCISE: Chapter 2.5 — UDP Poller
// Reference: docs/tutorial/02-data-path/05-poller.md
//
// Your task: implement `Poller.add` and `Poller.poll` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");
const ReceiveChannelEndpoint = @import("endpoint.zig").ReceiveChannelEndpoint;

pub const Poller = struct {
    fds: std.ArrayList(std.posix.pollfd),
    endpoints: std.ArrayList(*ReceiveChannelEndpoint),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Poller {
        return .{
            .fds = std.ArrayList(std.posix.pollfd).init(allocator),
            .endpoints = std.ArrayList(*ReceiveChannelEndpoint).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Poller) void {
        self.fds.deinit();
        self.endpoints.deinit();
    }

    pub fn add(self: *Poller, fd: std.posix.fd_t, endpoint: *ReceiveChannelEndpoint) !void {
        _ = fd;
        _ = endpoint;
        @panic("TODO: implement Poller.add");
    }

    pub fn poll(self: *Poller, timeout_ms: i32) i32 {
        _ = self;
        _ = timeout_ms;
        @panic("TODO: implement Poller.poll");
    }

    pub fn readyFds(self: *const Poller) []const std.posix.pollfd {
        return self.fds.items;
    }
};

test "Poller.init" {
    var p = Poller.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.readyFds().len);
}
