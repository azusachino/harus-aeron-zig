// EXERCISE: Chapter 2.4 — UDP Endpoints
// Reference: docs/tutorial/02-data-path/04-udp-endpoints.md
//
// Your task: implement `SendChannelEndpoint.open` and `ReceiveChannelEndpoint.open`.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");
const UdpChannel = @import("udp_channel.zig").UdpChannel;

pub const SendChannelEndpoint = struct {
    socket: std.posix.socket_t,

    pub fn open(channel: *const UdpChannel) !SendChannelEndpoint {
        _ = channel;
        @panic("TODO: implement SendChannelEndpoint.open");
    }

    pub fn send(self: *SendChannelEndpoint, dest: std.net.Address, data: []const u8) !usize {
        _ = self;
        _ = dest;
        _ = data;
        @panic("TODO: implement SendChannelEndpoint.send");
    }

    pub fn close(self: *SendChannelEndpoint) void {
        std.posix.close(self.socket);
    }
};

pub const ReceiveChannelEndpoint = struct {
    socket: std.posix.socket_t,
    bound_address: std.net.Address,

    pub fn open(channel: *const UdpChannel) !ReceiveChannelEndpoint {
        _ = channel;
        @panic("TODO: implement ReceiveChannelEndpoint.open");
    }

    pub fn bind(self: *ReceiveChannelEndpoint) !void {
        _ = self;
        @panic("TODO: implement ReceiveChannelEndpoint.bind");
    }

    pub fn joinMulticast(self: *ReceiveChannelEndpoint, group: std.net.Address, interface_addr: std.net.Address) !void {
        _ = self;
        _ = group;
        _ = interface_addr;
        @panic("TODO: implement ReceiveChannelEndpoint.joinMulticast");
    }

    pub fn recv(self: *ReceiveChannelEndpoint, buf: []u8, src: *std.net.Address) !usize {
        _ = self;
        _ = buf;
        _ = src;
        @panic("TODO: implement ReceiveChannelEndpoint.recv");
    }

    pub fn close(self: *ReceiveChannelEndpoint) void {
        std.posix.close(self.socket);
    }
};

test "SendChannelEndpoint.open" {
    // var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=127.0.0.1:0");
    // defer ch.deinit(std.testing.allocator);
}
