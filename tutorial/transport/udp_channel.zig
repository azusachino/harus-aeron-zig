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
        _ = allocator;
        _ = uri_str;
        @panic("TODO: implement UdpChannel.parse (Chapter C-5)");
    }

    pub fn deinit(self: *UdpChannel, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        @panic("TODO: implement UdpChannel.deinit (Chapter C-5)");
    }

    pub fn isMulticast(self: *const UdpChannel) bool {
        _ = self;
        @panic("TODO: implement UdpChannel.isMulticast (Chapter C-5)");
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
