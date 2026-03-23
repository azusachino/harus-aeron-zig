const std = @import("std");
const ReceiveChannelEndpoint = @import("endpoint.zig").ReceiveChannelEndpoint;

// LESSON(transport/aeron): Multiplexing strategy reduces per-datagram syscall overhead by batching multiple sockets into a single poll() call. See docs/tutorial/02-data-path/03-udp-transport.md
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

    /// Calls std.posix.poll and returns the number of ready file descriptors.
    /// Does not call recv — that is the Receiver's job.
    /// Returns 0 if poll times out or encounters an error.
    // LESSON(transport/zig): std.posix.poll blocks until timeout_ms or ≥1 fd has activity. No spinning; let OS scheduler wake us on I/O events.
    pub fn poll(self: *Poller, timeout_ms: i32) i32 {
        if (self.fds.items.len == 0) return 0;

        const ready_count = std.posix.poll(self.fds.items, timeout_ms) catch return 0;
        return @intCast(ready_count);
    }

    /// Returns a slice of the poll file descriptors for inspection.
    pub fn readyFds(self: *const Poller) []const std.posix.pollfd {
        return self.fds.items;
    }
};

test "Poller init and deinit is clean" {
    const allocator = std.testing.allocator;
    var poller = Poller.init(allocator);
    defer poller.deinit();

    try std.testing.expect(poller.fds.items.len == 0);
    try std.testing.expect(poller.endpoints.items.len == 0);
}

test "Poller add and remove by fd works" {
    const allocator = std.testing.allocator;
    var poller = Poller.init(allocator);
    defer poller.deinit();

    // Create a mock endpoint (we won't actually use it for recv)
    var endpoint: ReceiveChannelEndpoint = undefined;

    // Use a fake fd value for testing (we don't actually open a socket in this test)
    const fake_fd: std.posix.fd_t = 42;

    try poller.add(fake_fd, &endpoint);
    try std.testing.expect(poller.fds.items.len == 1);
    try std.testing.expect(poller.endpoints.items.len == 1);
    try std.testing.expect(poller.fds.items[0].fd == fake_fd);

    poller.remove(fake_fd);
    try std.testing.expect(poller.fds.items.len == 0);
    try std.testing.expect(poller.endpoints.items.len == 0);
}

test "Poller with real socket fd add and remove" {
    const allocator = std.testing.allocator;
    var poller = Poller.init(allocator);
    defer poller.deinit();

    // Open an actual UDP socket
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    // Create a mock endpoint
    var endpoint: ReceiveChannelEndpoint = undefined;

    try poller.add(sock, &endpoint);
    try std.testing.expect(poller.fds.items.len == 1);
    try std.testing.expect(poller.fds.items[0].fd == sock);

    poller.remove(sock);
    try std.testing.expect(poller.fds.items.len == 0);
}
