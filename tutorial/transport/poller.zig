const std = @import("std");
const ReceiveChannelEndpoint = @import("endpoint.zig").ReceiveChannelEndpoint;

pub const Poller = struct {
    fds: std.ArrayList(std.posix.pollfd),
    endpoints: std.ArrayList(*ReceiveChannelEndpoint),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Poller {
        _ = allocator;
        @panic("TODO: implement Poller.init (Chapter C-5)");
    }

    pub fn deinit(self: *Poller) void {
        _ = self;
        @panic("TODO: implement Poller.deinit (Chapter C-5)");
    }

    pub fn add(self: *Poller, fd: std.posix.fd_t, endpoint: *ReceiveChannelEndpoint) !void {
        _ = self;
        _ = fd;
        _ = endpoint;
        @panic("TODO: implement Poller.add (Chapter C-5)");
    }

    pub fn remove(self: *Poller, fd: std.posix.fd_t) void {
        _ = self;
        _ = fd;
        @panic("TODO: implement Poller.remove (Chapter C-5)");
    }

    pub fn poll(self: *Poller, timeout_ms: i32) i32 {
        _ = self;
        _ = timeout_ms;
        @panic("TODO: implement Poller.poll (Chapter C-5)");
    }

    pub fn readyFds(self: *const Poller) []const std.posix.pollfd {
        _ = self;
        @panic("TODO: implement Poller.readyFds (Chapter C-5)");
    }
};
