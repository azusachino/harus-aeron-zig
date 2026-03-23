const std = @import("std");
const UdpChannel = @import("udp_channel.zig").UdpChannel;

pub const SendChannelEndpoint = struct {
    socket: std.posix.socket_t,

    pub fn open(channel: *const UdpChannel) !SendChannelEndpoint {
        _ = channel;
        @panic("TODO: implement SendChannelEndpoint.open (Chapter C-5)");
    }

    pub fn send(self: *SendChannelEndpoint, dest: std.net.Address, data: []const u8) !usize {
        _ = self;
        _ = dest;
        _ = data;
        @panic("TODO: implement SendChannelEndpoint.send (Chapter C-5)");
    }

    pub fn close(self: *SendChannelEndpoint) void {
        _ = self;
        @panic("TODO: implement SendChannelEndpoint.close (Chapter C-5)");
    }
};

pub const ReceiveChannelEndpoint = struct {
    socket: std.posix.socket_t,
    bound_address: std.net.Address,

    pub fn open(channel: *const UdpChannel) !ReceiveChannelEndpoint {
        _ = channel;
        @panic("TODO: implement ReceiveChannelEndpoint.open (Chapter C-5)");
    }

    pub fn bind(self: *ReceiveChannelEndpoint) !void {
        _ = self;
        @panic("TODO: implement ReceiveChannelEndpoint.bind (Chapter C-5)");
    }

    pub fn joinMulticast(self: *ReceiveChannelEndpoint, group: std.net.Address, interface_addr: std.net.Address) !void {
        _ = self;
        _ = group;
        _ = interface_addr;
        @panic("TODO: implement ReceiveChannelEndpoint.joinMulticast (Chapter C-5)");
    }

    pub fn recv(self: *ReceiveChannelEndpoint, buf: []u8, src: *std.net.Address) !usize {
        _ = self;
        _ = buf;
        _ = src;
        @panic("TODO: implement ReceiveChannelEndpoint.recv (Chapter C-5)");
    }

    pub fn close(self: *ReceiveChannelEndpoint) void {
        _ = self;
        @panic("TODO: implement ReceiveChannelEndpoint.close (Chapter C-5)");
    }
};
