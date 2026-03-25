const std = @import("std");
const UdpChannel = @import("udp_channel.zig").UdpChannel;

// Multicast helper structs
const IpMreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};
const Ipv6Mreq = extern struct {
    ipv6mr_multiaddr: [16]u8,
    ipv6mr_interface: u32,
};

const builtin = @import("builtin");
const IP_ADD_MEMBERSHIP: u32 = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 12,
    .linux => 35,
    else => 12,
};
const IPV6_JOIN_GROUP: u32 = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 20,
    .linux => 20,
    else => 20,
};

pub const SendChannelEndpoint = struct {
    socket: std.posix.socket_t,

    pub fn open(channel: *const UdpChannel) !SendChannelEndpoint {
        // Determine address family from endpoint, default to IPv4
        const family: u32 = if (channel.endpoint) |ep| ep.any.family else std.posix.AF.INET;
        const sock = try std.posix.socket(
            family,
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(sock);

        // Bind to the local interface if specified
        if (channel.local_address) |addr| {
            try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
        }

        return SendChannelEndpoint{ .socket = sock };
    }

    pub fn send(self: *SendChannelEndpoint, dest: std.net.Address, data: []const u8) !usize {
        return std.posix.sendto(self.socket, data, 0, &dest.any, dest.getOsSockLen());
    }

    pub fn close(self: *SendChannelEndpoint) void {
        std.posix.close(self.socket);
    }
};

pub const ReceiveChannelEndpoint = struct {
    socket: std.posix.socket_t,
    bound_address: std.net.Address,

    pub fn open(channel: *const UdpChannel) !ReceiveChannelEndpoint {
        // Determine address family from endpoint, default to IPv4
        const family: u32 = if (channel.endpoint) |ep| ep.any.family else std.posix.AF.INET;
        const sock = try std.posix.socket(
            family,
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(sock);

        // Set SO_REUSEPORT for multicast to allow multiple subscribers
        if (channel.is_multicast) {
            try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(i32, 1)));
        }

        // Determine bind address based on channel configuration
        var bound_address: std.net.Address = undefined;
        if (channel.endpoint) |ep| {
            if (channel.is_multicast) {
                // For multicast, bind to all interfaces on the group's port
                if (family == std.posix.AF.INET) {
                    bound_address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, ep.getPort());
                } else {
                    bound_address = std.net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, ep.getPort(), 0, 0);
                }
            } else {
                // Unicast: bind to the specific endpoint
                bound_address = ep;
            }
        } else {
            // Default bind for non-UDP channels
            bound_address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        }

        return ReceiveChannelEndpoint{
            .socket = sock,
            .bound_address = bound_address,
        };
    }

    pub fn bind(self: *ReceiveChannelEndpoint) !void {
        try std.posix.bind(self.socket, &self.bound_address.any, self.bound_address.getOsSockLen());
    }

    pub fn joinMulticast(self: *ReceiveChannelEndpoint, group: std.net.Address, interface_addr: std.net.Address) !void {
        if (group.any.family == std.posix.AF.INET) {
            const mreq = IpMreq{
                .imr_multiaddr = group.in.sa.addr,
                .imr_interface = interface_addr.in.sa.addr,
            };
            try std.posix.setsockopt(self.socket, std.posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, &std.mem.toBytes(mreq));
        } else if (group.any.family == std.posix.AF.INET6) {
            const mreq = Ipv6Mreq{
                .ipv6mr_multiaddr = group.in6.sa.addr,
                .ipv6mr_interface = 0,
            };
            try std.posix.setsockopt(self.socket, std.posix.IPPROTO.IPV6, IPV6_JOIN_GROUP, &std.mem.toBytes(mreq));
        }
    }

    pub fn recv(self: *ReceiveChannelEndpoint, buf: []u8, src: *std.net.Address) !usize {
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        return std.posix.recvfrom(self.socket, buf, 0, &src.any, &addrlen);
    }

    pub fn close(self: *ReceiveChannelEndpoint) void {
        std.posix.close(self.socket);
    }
};

test "SendChannelEndpoint: open and close" {
    var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=127.0.0.1:0");
    defer ch.deinit(std.testing.allocator);
    var ep = try SendChannelEndpoint.open(&ch);
    ep.close();
}

test "ReceiveChannelEndpoint: open and close" {
    var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=127.0.0.1:0");
    defer ch.deinit(std.testing.allocator);
    var ep = try ReceiveChannelEndpoint.open(&ch);
    ep.close();
}
