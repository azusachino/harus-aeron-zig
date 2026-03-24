const std = @import("std");

// LESSON(transport/aeron): Aeron URIs define the channel medium and parameters (e.g. aeron:udp?endpoint=...).
pub const AeronUri = struct {
    media_type: MediaType,
    params: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    /// Owned copy of the original URI string
    raw_uri: []const u8,

    pub const MediaType = enum {
        udp,
        ipc,
    };

    pub const ControlMode = enum {
        dynamic,
        manual,
        response,

        pub fn fromString(s: []const u8) ?ControlMode {
            if (std.mem.eql(u8, s, "dynamic")) return .dynamic;
            if (std.mem.eql(u8, s, "manual")) return .manual;
            if (std.mem.eql(u8, s, "response")) return .response;
            return null;
        }
    };

    pub const ParseError = error{
        InvalidUri,
        InvalidMediaType,
        InvalidParam,
    };

    // LESSON(transport/zig): String parsing using std.mem.tokenizeScalar and manual ownership transfer.
    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) (ParseError || std.mem.Allocator.Error)!AeronUri {
        if (!std.mem.startsWith(u8, uri_str, "aeron:")) {
            return ParseError.InvalidUri;
        }

        const after_prefix = uri_str["aeron:".len..];

        // Determine media type and extract query part
        var media_type: MediaType = undefined;
        var query: ?[]const u8 = null;

        if (std.mem.startsWith(u8, after_prefix, "udp")) {
            media_type = .udp;
            const rest = after_prefix["udp".len..];
            if (rest.len == 0) {
                query = null;
            } else if (rest[0] == '?') {
                query = rest[1..];
            } else if (std.mem.startsWith(u8, rest, "://")) {
                const endpoint_value = rest[3..];
                if (endpoint_value.len == 0) return ParseError.InvalidParam;
                query = try std.fmt.allocPrint(allocator, "endpoint={s}", .{endpoint_value});
            } else {
                return ParseError.InvalidMediaType;
            }
        } else if (std.mem.startsWith(u8, after_prefix, "ipc")) {
            media_type = .ipc;
            const rest = after_prefix["ipc".len..];
            if (rest.len == 0) {
                query = null;
            } else if (rest[0] == '?') {
                query = rest[1..];
            } else {
                return ParseError.InvalidMediaType;
            }
        } else {
            return ParseError.InvalidMediaType;
        }

        const raw_uri = try allocator.dupe(u8, uri_str);
        errdefer allocator.free(raw_uri);
        defer if (media_type == .udp and std.mem.startsWith(u8, after_prefix["udp".len..], "://")) {
            allocator.free(query.?);
        };

        var params = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var it = params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            params.deinit();
        }

        if (query) |q| {
            var it = std.mem.tokenizeScalar(u8, q, '|');
            while (it.next()) |param| {
                var kv_it = std.mem.splitScalar(u8, param, '=');
                const key = kv_it.next() orelse return ParseError.InvalidParam;
                const value = kv_it.rest();
                if (key.len == 0 or value.len == 0) return ParseError.InvalidParam;
                try validateKnownParam(key, value);

                const owned_key = try allocator.dupe(u8, key);
                errdefer allocator.free(owned_key);
                const owned_value = try allocator.dupe(u8, value);
                errdefer allocator.free(owned_value);

                // If key already exists, free old value
                if (params.fetchRemove(owned_key)) |old| {
                    allocator.free(old.key);
                    allocator.free(old.value);
                }

                try params.put(owned_key, owned_value);
            }
        }

        return AeronUri{
            .media_type = media_type,
            .params = params,
            .allocator = allocator,
            .raw_uri = raw_uri,
        };
    }

    pub fn deinit(self: *AeronUri) void {
        var it = self.params.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
        self.allocator.free(self.raw_uri);
    }

    // -- Typed accessors --

    pub fn endpoint(self: *const AeronUri) ?[]const u8 {
        return self.params.get("endpoint");
    }

    pub fn controlEndpoint(self: *const AeronUri) ?[]const u8 {
        return self.params.get("control");
    }

    pub fn controlMode(self: *const AeronUri) ?ControlMode {
        const val = self.params.get("control-mode") orelse return null;
        return ControlMode.fromString(val);
    }

    pub fn interfaceName(self: *const AeronUri) ?[]const u8 {
        return self.params.get("interface");
    }

    pub fn mtu(self: *const AeronUri) ?usize {
        const val = self.params.get("mtu") orelse return null;
        return std.fmt.parseInt(usize, val, 10) catch null;
    }

    pub fn ttl(self: *const AeronUri) ?u8 {
        const val = self.params.get("ttl") orelse return null;
        return std.fmt.parseInt(u8, val, 10) catch null;
    }

    pub fn termLength(self: *const AeronUri) ?u32 {
        const val = self.params.get("term-length") orelse return null;
        return std.fmt.parseInt(u32, val, 10) catch null;
    }

    pub fn initialTermId(self: *const AeronUri) ?i32 {
        const val = self.params.get("initial-term-id") orelse return null;
        return std.fmt.parseInt(i32, val, 10) catch null;
    }

    pub fn sessionId(self: *const AeronUri) ?i32 {
        const val = self.params.get("session-id") orelse return null;
        return std.fmt.parseInt(i32, val, 10) catch null;
    }

    pub fn reliable(self: *const AeronUri) bool {
        const val = self.params.get("reliable") orelse return true;
        return std.mem.eql(u8, val, "true");
    }

    pub fn sparse(self: *const AeronUri) bool {
        const val = self.params.get("sparse") orelse return false;
        return std.mem.eql(u8, val, "true");
    }

    pub fn get(self: *const AeronUri, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    fn validateKnownParam(key: []const u8, value: []const u8) ParseError!void {
        if (std.mem.eql(u8, key, "control-mode")) {
            if (ControlMode.fromString(value) == null) return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "reliable") or std.mem.eql(u8, key, "sparse")) {
            if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
                return ParseError.InvalidParam;
            }
            return;
        }

        if (std.mem.eql(u8, key, "mtu")) {
            _ = std.fmt.parseInt(usize, value, 10) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "ttl")) {
            _ = std.fmt.parseInt(u8, value, 10) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "term-length")) {
            _ = std.fmt.parseInt(u32, value, 10) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "initial-term-id") or std.mem.eql(u8, key, "session-id")) {
            _ = std.fmt.parseInt(i32, value, 10) catch return ParseError.InvalidParam;
            return;
        }
    }
};

// -- Tests --

test "AeronUri: parse basic UDP endpoint" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123");
    defer uri.deinit();

    try std.testing.expectEqual(AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("localhost:40123", uri.endpoint().?);
}

test "AeronUri: parse IPC" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:ipc");
    defer uri.deinit();

    try std.testing.expectEqual(AeronUri.MediaType.ipc, uri.media_type);
    try std.testing.expect(uri.endpoint() == null);
}

test "AeronUri: parse IPC with params" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:ipc?term-length=65536|session-id=42");
    defer uri.deinit();

    try std.testing.expectEqual(AeronUri.MediaType.ipc, uri.media_type);
    try std.testing.expectEqual(@as(u32, 65536), uri.termLength().?);
    try std.testing.expectEqual(@as(i32, 42), uri.sessionId().?);
}

test "AeronUri: parse multicast with interface and ttl" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=224.0.1.1:40456|interface=127.0.0.1|ttl=4");
    defer uri.deinit();

    try std.testing.expectEqualStrings("224.0.1.1:40456", uri.endpoint().?);
    try std.testing.expectEqualStrings("127.0.0.1", uri.interfaceName().?);
    try std.testing.expectEqual(@as(u8, 4), uri.ttl().?);
}

test "AeronUri: parse control channel with dynamic mode" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?control=192.168.1.1:40124|control-mode=dynamic");
    defer uri.deinit();

    try std.testing.expectEqualStrings("192.168.1.1:40124", uri.controlEndpoint().?);
    try std.testing.expectEqual(AeronUri.ControlMode.dynamic, uri.controlMode().?);
}

test "AeronUri: parse control channel with response mode" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?control=localhost:40456|control-mode=response");
    defer uri.deinit();

    try std.testing.expectEqualStrings("localhost:40456", uri.controlEndpoint().?);
    try std.testing.expectEqual(AeronUri.ControlMode.response, uri.controlMode().?);
}

test "AeronUri: parse term-length and session-id" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=131072|session-id=-7");
    defer uri.deinit();

    try std.testing.expectEqual(@as(u32, 131072), uri.termLength().?);
    try std.testing.expectEqual(@as(i32, -7), uri.sessionId().?);
}

test "AeronUri: parse reliable=false and sparse=true" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|reliable=false|sparse=true");
    defer uri.deinit();

    try std.testing.expect(!uri.reliable());
    try std.testing.expect(uri.sparse());
}

test "AeronUri: defaults for reliable and sparse" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123");
    defer uri.deinit();

    try std.testing.expect(uri.reliable());
    try std.testing.expect(!uri.sparse());
}

test "AeronUri: reject invalid prefix" {
    const allocator = std.testing.allocator;
    const result = AeronUri.parse(allocator, "http://example.com");
    try std.testing.expectError(error.InvalidUri, result);
}

test "AeronUri: reject invalid media type" {
    const allocator = std.testing.allocator;
    const result = AeronUri.parse(allocator, "aeron:tcp?endpoint=localhost:40123");
    try std.testing.expectError(error.InvalidMediaType, result);
}

test "AeronUri: get arbitrary param" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|socket-sndbuf=2097152");
    defer uri.deinit();

    try std.testing.expectEqualStrings("2097152", uri.get("socket-sndbuf").?);
    try std.testing.expect(uri.get("nonexistent") == null);
}

test "AeronUri: parse UDP with no params" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp");
    defer uri.deinit();

    try std.testing.expectEqual(AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expect(uri.endpoint() == null);
}

test "AeronUri: parse UDP endpoint shorthand" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp://localhost:40123");
    defer uri.deinit();

    try std.testing.expectEqual(AeronUri.MediaType.udp, uri.media_type);
    try std.testing.expectEqualStrings("localhost:40123", uri.endpoint().?);
}

test "AeronUri: initial-term-id accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|initial-term-id=100");
    defer uri.deinit();

    try std.testing.expectEqual(@as(i32, 100), uri.initialTermId().?);
}

test "AeronUri: mtu accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|mtu=8192");
    defer uri.deinit();

    try std.testing.expectEqual(@as(usize, 8192), uri.mtu().?);
}

test "AeronUri: reject invalid control-mode" {
    const allocator = std.testing.allocator;
    const result = AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|control-mode=bogus");
    try std.testing.expectError(error.InvalidParam, result);
}

test "AeronUri: reject invalid boolean parameter" {
    const allocator = std.testing.allocator;
    const result = AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|reliable=maybe");
    try std.testing.expectError(error.InvalidParam, result);
}

test "AeronUri: reject empty endpoint value" {
    const allocator = std.testing.allocator;
    const result = AeronUri.parse(allocator, "aeron:udp?endpoint=");
    try std.testing.expectError(error.InvalidParam, result);
}
