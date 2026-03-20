const std = @import("std");
const uri_module = struct {
    pub const AeronUri = @import("aeron").transport.AeronUri;
};

/// Fuzz parser for Aeron URIs.
/// Feeds random/corrupted strings to AeronUri.parse().
pub fn fuzz(input: []const u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Try parsing as a URI string
    const uri_result = uri_module.AeronUri.parse(allocator, input);
    if (uri_result) |parsed| {
        // Successfully parsed; exercise the accessors
        _ = parsed.endpoint();
        _ = parsed.controlEndpoint();
        _ = parsed.controlMode();
        _ = parsed.interfaceName();
        _ = parsed.mtu();
        _ = parsed.ttl();
        _ = parsed.termLength();
        _ = parsed.initialTermId();
        _ = parsed.sessionId();
        _ = parsed.reliable();
        _ = parsed.sparse();
        var u = parsed;
        u.deinit();
    } else |_| {
        // Expected to fail on invalid input; that's fine
    }
}

test "fuzz_uri: empty input" {
    fuzz(&[_]u8{});
}

test "fuzz_uri: no prefix" {
    fuzz("udp?endpoint=localhost:40123");
}

test "fuzz_uri: invalid prefix" {
    fuzz("http://example.com");
}

test "fuzz_uri: all zeros" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    fuzz(&buf);
}

test "fuzz_uri: all 0xFF" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xFF);
    fuzz(&buf);
}

test "fuzz_uri: valid but truncated" {
    fuzz("aeron:udp?endpoint=");
}

test "fuzz_uri: excessive parameters" {
    fuzz("aeron:udp?a=1|b=2|c=3|d=4|e=5|f=6|g=7|h=8|i=9|j=10|k=11|l=12");
}
