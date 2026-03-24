const std = @import("std");
const uri_mod = @import("uri.zig");
const AeronUri = uri_mod.AeronUri;

// LESSON(transport/aeron): Channel configuration encodes transport mode (unicast/multicast), endpoints, and MTU. See docs/tutorial/02-data-path/03-udp-transport.md
pub const UdpChannel = struct {
    uri: []const u8,
    endpoint: ?std.net.Address, // remote address (unicast dest or mcast group)
    local_address: ?std.net.Address, // interface bind address (from `interface=` param)
    is_multicast: bool,
    mtu: ?usize,
    ttl: ?u8,
    control: ?std.net.Address,
    control_mode: ?AeronUri.ControlMode,
    session_id: ?i32,
    term_length: ?u32,

    // LESSON(transport/zig): String parsing with error propagation via !T return type. Allocator ownership is caller's responsibility.
    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) !UdpChannel {
        var aeron_uri = try AeronUri.parse(allocator, uri_str);
        defer aeron_uri.deinit();

        const owned_uri = try allocator.dupe(u8, uri_str);
        errdefer allocator.free(owned_uri);

        var channel = UdpChannel{
            .uri = owned_uri,
            .endpoint = null,
            .local_address = null,
            .is_multicast = false,
            .mtu = aeron_uri.mtu(),
            .ttl = aeron_uri.ttl(),
            .control = null,
            .control_mode = aeron_uri.controlMode(),
            .session_id = aeron_uri.sessionId(),
            .term_length = aeron_uri.termLength(),
        };

        if (aeron_uri.media_type == .ipc) {
            return channel;
        }

        // Resolve endpoint address
        if (aeron_uri.endpoint()) |ep| {
            channel.endpoint = try parseAddress(ep, 0);
        }

        // Resolve interface address
        if (aeron_uri.interfaceName()) |iface| {
            channel.local_address = try parseAddress(iface, 0);
        }

        // Resolve control address
        if (aeron_uri.controlEndpoint()) |ctrl| {
            channel.control = try parseAddress(ctrl, 0);
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
        const address_str = stripSubnetMask(host_port);
        if (address_str.len == 0) {
            return error.InvalidAddress;
        }

        if (address_str[0] == '[') {
            const close = std.mem.indexOfScalar(u8, address_str, ']') orelse return error.InvalidAddress;
            const host = address_str[1..close];
            var port = default_port;
            if (close + 1 < address_str.len) {
                if (address_str[close + 1] != ':') return error.InvalidAddress;
                port = try std.fmt.parseInt(u16, address_str[close + 2 ..], 10);
            }
            return resolveHost(host, port);
        }

        if (std.mem.indexOfScalar(u8, address_str, ':')) |colon| {
            if (std.mem.indexOfScalarPos(u8, address_str, colon + 1, ':')) |_| {
                return resolveHost(address_str, default_port);
            }

            const host = address_str[0..colon];
            const port = try std.fmt.parseInt(u16, address_str[colon + 1 ..], 10);
            return resolveHost(host, port);
        }

        return resolveHost(address_str, default_port);
    }

    fn stripSubnetMask(address_str: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, address_str, '/')) |slash| {
            return address_str[0..slash];
        }
        return address_str;
    }

    fn resolveHost(host: []const u8, port: u16) !std.net.Address {
        if (std.mem.eql(u8, host, "localhost")) {
            return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        }
        return std.net.Address.resolveIp(host, port) catch |err| switch (err) {
            error.InvalidIPAddressFormat => error.InvalidAddress,
            else => err,
        };
    }

    // LESSON(transport/aeron): Multicast detection relies on IPv4 class D (224.0.0.0/4) and IPv6 ff00::/8. MDC needs no mcast join.
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

test "UdpChannel: parse with control and session-id" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(allocator, "aeron:udp?endpoint=localhost:40123|control=192.168.1.1:40124|control-mode=dynamic|session-id=42|term-length=131072");
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint != null);
    try std.testing.expect(channel.control != null);
    try std.testing.expectEqual(AeronUri.ControlMode.dynamic, channel.control_mode.?);
    try std.testing.expectEqual(@as(i32, 42), channel.session_id.?);
    try std.testing.expectEqual(@as(u32, 131072), channel.term_length.?);
}

test "UdpChannel: parse endpoint shorthand" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(allocator, "aeron:udp://localhost:40123");
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint != null);
    try std.testing.expectEqual(@as(u16, 40123), channel.endpoint.?.getPort());
}

test "UdpChannel: reject invalid interface address" {
    const allocator = std.testing.allocator;
    const result = UdpChannel.parse(allocator, "aeron:udp?endpoint=localhost:40123|interface=[]");
    try std.testing.expectError(error.InvalidAddress, result);
}

test "UdpChannel: parse IPv6 endpoint and subnet-qualified interface" {
    const allocator = std.testing.allocator;
    var channel = try UdpChannel.parse(
        allocator,
        "aeron:udp?endpoint=[ff02::1]:40456|interface=[fe80::60c:ceff:fee3]/88|ttl=16",
    );
    defer channel.deinit(allocator);

    try std.testing.expect(channel.endpoint != null);
    try std.testing.expect(channel.local_address != null);
    try std.testing.expect(channel.isMulticast());
    try std.testing.expectEqual(std.posix.AF.INET6, channel.endpoint.?.any.family);
    try std.testing.expectEqual(std.posix.AF.INET6, channel.local_address.?.any.family);
    try std.testing.expectEqual(@as(u16, 40456), channel.endpoint.?.getPort());
    try std.testing.expectEqual(@as(u8, 16), channel.ttl.?);
}
