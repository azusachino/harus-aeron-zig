const std = @import("std");

pub const UdpChannel = struct {
    uri: []const u8,
    endpoint: ?std.net.Address, // remote address (unicast dest or mcast group)
    local_address: ?std.net.Address, // interface bind address (from `interface=` param)
    is_multicast: bool,
    mtu: ?usize,
    ttl: ?u8,

    pub fn parse(allocator: std.mem.Allocator, uri: []const u8) !UdpChannel {
        const owned_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned_uri);

        var channel = UdpChannel{
            .uri = owned_uri,
            .endpoint = null,
            .local_address = null,
            .is_multicast = false,
            .mtu = null,
            .ttl = null,
        };

        if (std.mem.eql(u8, uri, "aeron:ipc")) {
            return channel;
        }

        if (!std.mem.startsWith(u8, uri, "aeron:udp?")) {
            return channel;
        }

        const query = uri["aeron:udp?".len..];
        var it = std.mem.tokenizeScalar(u8, query, '|');
        while (it.next()) |param| {
            var kv_it = std.mem.splitScalar(u8, param, '=');
            const key = kv_it.next() orelse continue;
            const value = kv_it.next() orelse continue;

            if (std.mem.eql(u8, key, "endpoint")) {
                channel.endpoint = try parseAddress(value, 0);
            } else if (std.mem.eql(u8, key, "interface")) {
                // For interface, we try to parse it. If it fails (like "eth0"),
                // we set it to null which usually means bind to any interface.
                channel.local_address = parseAddress(value, 0) catch null;
            } else if (std.mem.eql(u8, key, "mtu")) {
                channel.mtu = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (std.mem.eql(u8, key, "ttl")) {
                channel.ttl = std.fmt.parseInt(u8, value, 10) catch null;
            }
        }

        if (channel.endpoint) |ep| {
            channel.is_multicast = isMulticastAddress(ep);
        }

        return channel;
    }

    pub fn deinit(self: *UdpChannel, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }

    pub fn isMulticast(self: *const UdpChannel) bool {
        return self.is_multicast;
    }

    fn parseAddress(host_port: []const u8, default_port: u16) !std.net.Address {
        if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |last_colon| {
            const host = host_port[0..last_colon];
            const port_str = host_port[last_colon + 1 ..];
            const port = try std.fmt.parseInt(u16, port_str, 10);

            if (std.mem.eql(u8, host, "localhost")) {
                return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
            }
            return std.net.Address.parseIp(host, port);
        } else {
            if (std.mem.eql(u8, host_port, "localhost")) {
                return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, default_port);
            }
            return std.net.Address.parseIp(host_port, default_port);
        }
    }

    fn isMulticastAddress(address: std.net.Address) bool {
        switch (address.any.family) {
            std.posix.AF.INET => {
                const addr = address.in.sa.addr;
                const ip_u32 = std.mem.bigToNative(u32, addr);
                const first_byte = (ip_u32 >> 24) & 0xFF;
                return first_byte >= 224 and first_byte <= 239;
            },
            std.posix.AF.INET6 => {
                return address.in6.sa.addr[0] == 0xff;
            },
            else => return false,
        }
    }
};

test "UdpChannel: parse unicast URI" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(allocator, "aeron:udp?endpoint=127.0.0.1:40123");
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint != null);
    try std.testing.expectEqual(@as(u16, 40123), channel.endpoint.?.getPort());
    try std.testing.expect(!channel.isMulticast());
}

test "UdpChannel: parse multicast URI" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(allocator, "aeron:udp?endpoint=224.0.1.1:40456|interface=127.0.0.1");
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint != null);
    try std.testing.expect(channel.isMulticast());
    try std.testing.expect(channel.local_address != null);
    try std.testing.expectEqual(@as(u16, 40456), channel.endpoint.?.getPort());
}

test "UdpChannel: parse IPC URI" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(allocator, "aeron:ipc");
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint == null);
    try std.testing.expect(channel.local_address == null);
    try std.testing.expect(!channel.isMulticast());
}
