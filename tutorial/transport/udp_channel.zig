const std = @import("std");
const AeronUri = @import("uri.zig").AeronUri;

pub const UdpChannel = struct {
    uri: []const u8,
    endpoint: ?std.net.Address,
    local_address: ?std.net.Address,
    is_multicast: bool,
    mtu: ?usize,
    ttl: ?u8,
    control: ?std.net.Address,
    control_mode: ?AeronUri.ControlMode,
    session_id: ?i32,
    term_length: ?u32,

    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) !UdpChannel {
        // Parse the Aeron URI to extract parameters
        var aeron_uri = try AeronUri.parse(allocator, uri_str);
        defer aeron_uri.deinit();

        // Keep a copy of the raw URI string
        const owned_uri = try allocator.dupe(u8, uri_str);
        errdefer allocator.free(owned_uri);

        // Initialize the channel with parsed parameters
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

        // For IPC, no endpoint addresses are needed
        if (aeron_uri.media_type == .ipc) {
            return channel;
        }

        // Parse endpoint address
        if (aeron_uri.endpoint()) |ep| {
            channel.endpoint = parseAddress(ep) catch return error.InvalidAddress;
        }

        // Parse interface address
        if (aeron_uri.interfaceName()) |iface| {
            channel.local_address = parseAddress(iface) catch return error.InvalidAddress;
        }

        // Parse control address
        if (aeron_uri.controlEndpoint()) |ctrl| {
            channel.control = parseAddress(ctrl) catch return error.InvalidAddress;
        }

        // Detect if endpoint is a multicast address
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

    // Parse an address string (e.g., "127.0.0.1:40123" or "224.0.1.1:40456")
    fn parseAddress(host_port: []const u8) !std.net.Address {
        if (host_port.len == 0) {
            return error.InvalidAddress;
        }

        // IPv6 addresses are in brackets: "[::1]:8080"
        if (host_port[0] == '[') {
            const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidAddress;
            const host = host_port[1..close];
            var port: u16 = 0;
            if (close + 1 < host_port.len) {
                if (host_port[close + 1] != ':') return error.InvalidAddress;
                port = try std.fmt.parseInt(u16, host_port[close + 2 ..], 10);
            }
            return resolveHost(host, port);
        }

        // Check for colon (IPv4 with port or IPv6 without brackets)
        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
            // Check if there's another colon after this (IPv6)
            if (std.mem.indexOfScalarPos(u8, host_port, colon + 1, ':')) |_| {
                return resolveHost(host_port, 0);
            }

            const host = host_port[0..colon];
            const port = try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10);
            return resolveHost(host, port);
        }

        return resolveHost(host_port, 0);
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

    // Detect if address is a multicast address
    // IPv4: class D (224.0.0.0/4)
    // IPv6: ff00::/8
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

test "UdpChannel.parse: unicast address is not multicast" {
    var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=127.0.0.1:40123");
    defer ch.deinit(std.testing.allocator);
    try std.testing.expect(!ch.isMulticast());
}

test "UdpChannel.parse: multicast address detected" {
    var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=224.0.1.1:40123");
    defer ch.deinit(std.testing.allocator);
    try std.testing.expect(ch.isMulticast());
}
