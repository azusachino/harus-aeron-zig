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
