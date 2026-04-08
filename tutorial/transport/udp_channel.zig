// EXERCISE: Chapter 2.3 — UDP Channel
// Reference: docs/tutorial/02-data-path/03-udp-transport.md
//
// Your task: implement `UdpChannel.parse` logic.
// Run `make tutorial-check` to verify your solution.

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
        @panic("TODO: implement UdpChannel.parse");
    }

    pub fn deinit(self: *UdpChannel, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }

    pub fn isMulticast(self: *const UdpChannel) bool {
        _ = self;
        @panic("TODO: implement UdpChannel.isMulticast");
    }
};

test "UdpChannel.parse" {
    // var ch = try UdpChannel.parse(std.testing.allocator, "aeron:udp?endpoint=127.0.0.1:40123");
    // defer ch.deinit(std.testing.allocator);
}
