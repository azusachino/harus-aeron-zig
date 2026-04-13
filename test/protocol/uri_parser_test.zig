// Upstream reference: aeron-client/src/test/java/io/aeron/ChannelUriTest.java
// Aeron version: 1.50.2
// Coverage: parse aeron:udp URI, reject malformed, extract media, endpoint

const std = @import("std");
const aeron = @import("aeron");

test "ChannelUri: parse aeron:udp scheme" {
    const uri = "aeron:udp?endpoint=localhost:20121";
    var parsed = try aeron.transport.AeronUri.parse(std.testing.allocator, uri);
    defer parsed.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, parsed.media_type);
}

test "ChannelUri: parse endpoint parameter" {
    const uri = "aeron:udp?endpoint=192.168.1.1:40123";
    var parsed = try aeron.transport.AeronUri.parse(std.testing.allocator, uri);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("192.168.1.1:40123", parsed.params.get("endpoint").?);
}

test "ChannelUri: reject missing aeron: prefix" {
    const result = aeron.transport.AeronUri.parse(std.testing.allocator, "udp?endpoint=localhost:20121");
    try std.testing.expectError(error.InvalidUri, result);
}

test "ChannelUri: parse aeron:ipc" {
    const uri = "aeron:ipc";
    var parsed = try aeron.transport.AeronUri.parse(std.testing.allocator, uri);
    defer parsed.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.ipc, parsed.media_type);
}

test "ChannelUri: parse aeron-spy prefix" {
    const uri = "aeron-spy:aeron:ipc";
    var parsed = try aeron.transport.AeronUri.parse(std.testing.allocator, uri);
    defer parsed.deinit();
    try std.testing.expect(parsed.isSpy());
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.ipc, parsed.media_type);
}

test "ChannelUri: create destination uri" {
    const uri = try aeron.transport.AeronUri.createDestinationUri(
        std.testing.allocator,
        "aeron:udp?interface=eth0|term-length=64k|ttl=0|endpoint=some",
        "vm1",
    );
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=vm1|interface=eth0", uri);
}

// ============================================================================
// Valid URI forms with full transport URI coverage
// ============================================================================

test "AeronUri: basic unicast with hostname" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("localhost:40123", uri.endpoint().?);
}

test "AeronUri: unicast with IP address" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=127.0.0.1:40456");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("127.0.0.1:40456", uri.endpoint().?);
}

test "AeronUri: multicast group with interface" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=224.0.1.1:40456|interface=eth0");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("224.0.1.1:40456", uri.endpoint().?);
    try std.testing.expectEqualStrings("eth0", uri.interfaceName().?);
}

test "AeronUri: IPC channel" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:ipc");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.ipc, uri.media_type);
    try std.testing.expect(uri.endpoint() == null);
}

test "AeronUri: ephemeral port (port=0)" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=127.0.0.1:0");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("127.0.0.1:0", uri.endpoint().?);
}

test "AeronUri: dynamic MDC with control endpoint" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?control=localhost:40456|control-mode=dynamic");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("localhost:40456", uri.controlEndpoint().?);
    try std.testing.expectEqual(aeron.transport.AeronUri.ControlMode.dynamic, uri.controlMode().?);
}

test "AeronUri: wildcard address" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=0.0.0.0:40123");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("0.0.0.0:40123", uri.endpoint().?);
}

test "AeronUri: with mtu parameter" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|mtu=4096");
    defer uri.deinit();
    try std.testing.expectEqual(@as(usize, 4096), uri.mtu().?);
}

test "AeronUri: with term-length parameter" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=1048576");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u32, 1048576), uri.termLength().?);
}

test "AeronUri: with TTL parameter" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|ttl=8");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u8, 8), uri.ttl().?);
}

// ============================================================================
// isMulticast() correctness tests
// ============================================================================

test "UdpChannel: isMulticast returns true for 224.0.1.1" {
    const allocator = std.testing.allocator;
    var channel = try aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=224.0.1.1:40456");
    defer channel.deinit(allocator);
    try std.testing.expect(channel.isMulticast());
}

test "UdpChannel: isMulticast returns true for 239.255.0.1" {
    const allocator = std.testing.allocator;
    var channel = try aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=239.255.0.1:40456");
    defer channel.deinit(allocator);
    try std.testing.expect(channel.isMulticast());
}

test "UdpChannel: isMulticast returns false for 127.0.0.1" {
    const allocator = std.testing.allocator;
    var channel = try aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=127.0.0.1:40456");
    defer channel.deinit(allocator);
    try std.testing.expect(!channel.isMulticast());
}

test "UdpChannel: isMulticast returns false for localhost" {
    const allocator = std.testing.allocator;
    var channel = try aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=localhost:40456");
    defer channel.deinit(allocator);
    try std.testing.expect(!channel.isMulticast());
}

// ============================================================================
// Invalid URI forms — error cases
// ============================================================================

test "AeronUri: reject empty string" {
    const allocator = std.testing.allocator;
    const result = aeron.transport.AeronUri.parse(allocator, "");
    try std.testing.expectError(error.InvalidUri, result);
}

test "AeronUri: reject missing aeron: prefix (udp scheme)" {
    const allocator = std.testing.allocator;
    const result = aeron.transport.AeronUri.parse(allocator, "udp:endpoint=x");
    try std.testing.expectError(error.InvalidUri, result);
}

test "AeronUri: reject missing media type" {
    const allocator = std.testing.allocator;
    const result = aeron.transport.AeronUri.parse(allocator, "aeron:");
    try std.testing.expectError(error.InvalidMediaType, result);
}

test "AeronUri: reject aeron:udp without query parameters" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expect(uri.endpoint() == null);
}

test "AeronUri: reject empty endpoint value" {
    const allocator = std.testing.allocator;
    const result = aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=");
    try std.testing.expectError(error.InvalidParam, result);
}

test "UdpChannel: endpoint without port defaults to port 0" {
    const allocator = std.testing.allocator;
    var channel = try aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=localhost");
    defer channel.deinit(allocator);
    try std.testing.expect(channel.endpoint != null);
    try std.testing.expectEqual(@as(u16, 0), channel.endpoint.?.getPort());
}

test "UdpChannel: reject non-numeric port at address parsing" {
    const allocator = std.testing.allocator;
    const result = aeron.transport.UdpChannel.parse(allocator, "aeron:udp?endpoint=localhost:notaport");
    try std.testing.expectError(error.InvalidCharacter, result);
}

// ============================================================================
// Parameter extraction and typed accessors
// ============================================================================

test "AeronUri: mtu parsed as integer 4096" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|mtu=4096");
    defer uri.deinit();
    try std.testing.expectEqual(@as(usize, 4096), uri.mtu().?);
}

test "AeronUri: term-length parsed correctly" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=262144");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u32, 262144), uri.termLength().?);
}

test "AeronUri: ttl parsed as u8" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|ttl=16");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u8, 16), uri.ttl().?);
}

test "AeronUri: session-id parsed as i32" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|session-id=42");
    defer uri.deinit();
    try std.testing.expectEqual(@as(i32, 42), uri.sessionId().?);
}

test "AeronUri: missing optional param returns null" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123");
    defer uri.deinit();
    try std.testing.expect(uri.mtu() == null);
    try std.testing.expect(uri.ttl() == null);
    try std.testing.expect(uri.termLength() == null);
    try std.testing.expect(uri.sessionId() == null);
}

test "AeronUri: control-mode manual" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?control=localhost:40123|control-mode=manual");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.ControlMode.manual, uri.controlMode().?);
}

test "AeronUri: control-mode response" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(allocator, "aeron:udp?control=localhost:40123|control-mode=response");
    defer uri.deinit();
    try std.testing.expectEqual(aeron.transport.AeronUri.ControlMode.response, uri.controlMode().?);
}

// ============================================================================
// Multiple parameters combined
// ============================================================================

test "AeronUri: multiple parameters combined" {
    const allocator = std.testing.allocator;
    var uri = try aeron.transport.AeronUri.parse(
        allocator,
        "aeron:udp?endpoint=224.0.1.1:40456|interface=eth0|ttl=4|mtu=8192|term-length=131072",
    );
    defer uri.deinit();
    try std.testing.expectEqualStrings("224.0.1.1:40456", uri.endpoint().?);
    try std.testing.expectEqualStrings("eth0", uri.interfaceName().?);
    try std.testing.expectEqual(@as(u8, 4), uri.ttl().?);
    try std.testing.expectEqual(@as(usize, 8192), uri.mtu().?);
    try std.testing.expectEqual(@as(u32, 131072), uri.termLength().?);
}
