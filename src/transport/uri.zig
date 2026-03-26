const std = @import("std");

pub const INVALID_TAG: i64 = -1;

// LESSON(udp-transport): Aeron URIs define the channel medium and parameters (e.g. aeron:udp?endpoint=...). See docs/tutorial/02-data-path/03-udp-transport.md
pub const AeronUri = struct {
    prefix: ?Prefix,
    media_type: MediaType,
    params: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    /// Owned copy of the original URI string
    raw_uri: []const u8,

    pub const MediaType = enum {
        udp,
        ipc,
    };

    pub const Prefix = enum {
        spy,
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

    fn canonicalKey(key: []const u8) []const u8 {
        if (std.mem.eql(u8, key, "so-sndbuf")) return "socket-sndbuf";
        if (std.mem.eql(u8, key, "so-rcvbuf")) return "socket-rcvbuf";
        if (std.mem.eql(u8, key, "rcv-wnd")) return "receiver-window";
        return key;
    }

    fn parseSize(comptime T: type, value: []const u8) !T {
        if (value.len == 0) return error.InvalidParam;

        var multiplier: u64 = 1;
        var digits = value;
        const suffix = value[value.len - 1];
        switch (suffix) {
            'k', 'K' => {
                multiplier = 1024;
                digits = value[0 .. value.len - 1];
            },
            'm', 'M' => {
                multiplier = 1024 * 1024;
                digits = value[0 .. value.len - 1];
            },
            'g', 'G' => {
                multiplier = 1024 * 1024 * 1024;
                digits = value[0 .. value.len - 1];
            },
            else => {},
        }

        if (digits.len == 0) return error.InvalidParam;
        const base = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidParam;
        const scaled = std.math.mul(u64, base, multiplier) catch return error.InvalidParam;
        return std.math.cast(T, scaled) orelse return error.InvalidParam;
    }

    fn parseDurationNs(value: []const u8) !u64 {
        if (value.len < 2) return error.InvalidParam;

        const suffix2 = if (value.len >= 2) value[value.len - 2 ..] else "";
        if (std.mem.eql(u8, suffix2, "ns")) {
            const base = std.fmt.parseInt(u64, value[0 .. value.len - 2], 10) catch return error.InvalidParam;
            return base;
        }
        if (std.mem.eql(u8, suffix2, "us")) {
            const base = std.fmt.parseInt(u64, value[0 .. value.len - 2], 10) catch return error.InvalidParam;
            return std.math.mul(u64, base, 1_000) catch return error.InvalidParam;
        }
        if (std.mem.eql(u8, suffix2, "ms")) {
            const base = std.fmt.parseInt(u64, value[0 .. value.len - 2], 10) catch return error.InvalidParam;
            return std.math.mul(u64, base, 1_000_000) catch return error.InvalidParam;
        }
        if (value.len >= 1 and value[value.len - 1] == 's') {
            const base = std.fmt.parseInt(u64, value[0 .. value.len - 1], 10) catch return error.InvalidParam;
            return std.math.mul(u64, base, 1_000_000_000) catch return error.InvalidParam;
        }

        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidParam;
    }

    fn validateSessionId(value: []const u8) ParseError!void {
        if (std.mem.startsWith(u8, value, "tag:")) {
            if (value["tag:".len..].len == 0) return ParseError.InvalidParam;
            _ = std.fmt.parseInt(i64, value["tag:".len..], 10) catch return ParseError.InvalidParam;
            return;
        }

        _ = std.fmt.parseInt(i32, value, 10) catch return ParseError.InvalidParam;
    }

    // LESSON(udp-transport): String parsing using std.mem.tokenizeScalar and manual ownership transfer. See docs/tutorial/02-data-path/03-udp-transport.md
    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) (ParseError || std.mem.Allocator.Error)!AeronUri {
        var prefix: ?Prefix = null;
        var trimmed = uri_str;

        if (std.mem.startsWith(u8, trimmed, "aeron-spy:")) {
            prefix = .spy;
            trimmed = trimmed["aeron-spy:".len..];
        }

        if (!std.mem.startsWith(u8, trimmed, "aeron:")) {
            return ParseError.InvalidUri;
        }

        const after_prefix = trimmed["aeron:".len..];

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
                const normalized_key = canonicalKey(key);
                try validateKnownParam(normalized_key, value);

                const owned_key = try allocator.dupe(u8, normalized_key);
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
            .prefix = prefix,
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

    pub fn prefixKind(self: *const AeronUri) ?Prefix {
        return self.prefix;
    }

    pub fn isSpy(self: *const AeronUri) bool {
        return self.prefix == .spy;
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
        return parseSize(usize, val) catch null;
    }

    pub fn ttl(self: *const AeronUri) ?u8 {
        const val = self.params.get("ttl") orelse return null;
        return std.fmt.parseInt(u8, val, 10) catch null;
    }

    pub fn termLength(self: *const AeronUri) ?u32 {
        const val = self.params.get("term-length") orelse return null;
        return parseSize(u32, val) catch null;
    }

    pub fn initialTermId(self: *const AeronUri) ?i32 {
        const val = self.params.get("initial-term-id") orelse return null;
        return std.fmt.parseInt(i32, val, 10) catch null;
    }

    pub fn sessionId(self: *const AeronUri) ?i32 {
        const val = self.params.get("session-id") orelse return null;
        if (std.mem.startsWith(u8, val, "tag:")) return null;
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

    /// Linger time in milliseconds before a publication is fully closed.
    pub fn linger(self: *const AeronUri) ?u32 {
        const val = self.params.get("linger") orelse return null;
        return std.math.cast(u32, parseDurationNs(val) catch return null) orelse null;
    }

    /// Flow-control strategy string (e.g. "min", "max", "tagged", "pref-tagged").
    pub fn flowControl(self: *const AeronUri) ?[]const u8 {
        return self.params.get("flow-control");
    }

    /// SO_SNDBUF hint in bytes for the sending socket.
    pub fn socketSndbuf(self: *const AeronUri) ?usize {
        const val = self.params.get("socket-sndbuf") orelse return null;
        return parseSize(usize, val) catch null;
    }

    /// SO_RCVBUF hint in bytes for the receiving socket.
    pub fn socketRcvbuf(self: *const AeronUri) ?usize {
        const val = self.params.get("socket-rcvbuf") orelse return null;
        return parseSize(usize, val) catch null;
    }

    /// Receiver window size override in bytes.
    pub fn receiverWindow(self: *const AeronUri) ?i64 {
        const val = self.params.get("receiver-window") orelse return null;
        return parseSize(i64, val) catch null;
    }

    /// Informational alias string for the channel (not used for routing).
    pub fn alias(self: *const AeronUri) ?[]const u8 {
        return self.params.get("alias");
    }

    /// Comma-separated tag string for channel grouping/matching.
    pub fn tags(self: *const AeronUri) ?[]const u8 {
        return self.params.get("tags");
    }

    pub fn get(self: *const AeronUri, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn isTagged(param_value: []const u8) bool {
        return std.mem.startsWith(u8, param_value, "tag:");
    }

    pub fn getTag(param_value: []const u8) i64 {
        if (!isTagged(param_value)) return INVALID_TAG;
        return std.fmt.parseInt(i64, param_value["tag:".len..], 10) catch INVALID_TAG;
    }

    pub fn createDestinationUri(
        allocator: std.mem.Allocator,
        channel: []const u8,
        target_endpoint: []const u8,
    ) (ParseError || std.mem.Allocator.Error)![]u8 {
        var channel_uri = try parse(allocator, channel);
        defer channel_uri.deinit();

        var uri = try std.fmt.allocPrint(allocator, "aeron:{s}?endpoint={s}", .{
            switch (channel_uri.media_type) {
                .udp => "udp",
                .ipc => "ipc",
            },
            target_endpoint,
        });

        if (channel_uri.interfaceName()) |network_interface| {
            const with_interface = try std.fmt.allocPrint(allocator, "{s}|interface={s}", .{ uri, network_interface });
            allocator.free(uri);
            uri = with_interface;
        }

        return uri;
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
            _ = parseSize(usize, value) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "ttl")) {
            _ = std.fmt.parseInt(u8, value, 10) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "term-length")) {
            const v = parseSize(u32, value) catch return ParseError.InvalidParam;
            // Must be a power of two in [64KiB, 1GiB] — same rule as upstream driver.
            const TERM_MIN: u32 = 64 * 1024;
            const TERM_MAX: u32 = 1024 * 1024 * 1024;
            if (v < TERM_MIN or v > TERM_MAX or (v & (v - 1)) != 0) return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "initial-term-id")) {
            _ = std.fmt.parseInt(i32, value, 10) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "session-id")) {
            try validateSessionId(value);
            return;
        }

        if (std.mem.eql(u8, key, "linger")) {
            _ = parseDurationNs(value) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "socket-sndbuf") or std.mem.eql(u8, key, "socket-rcvbuf")) {
            _ = parseSize(usize, value) catch return ParseError.InvalidParam;
            return;
        }

        if (std.mem.eql(u8, key, "receiver-window")) {
            _ = parseSize(i64, value) catch return ParseError.InvalidParam;
            return;
        }

        // flow-control, alias, and tags accept any non-empty string value — pass through.
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

test "AeronUri: parse spy prefix" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron-spy:aeron:ipc");
    defer uri.deinit();

    try std.testing.expect(uri.isSpy());
    try std.testing.expectEqual(AeronUri.MediaType.ipc, uri.media_type);
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

test "AeronUri: parse tagged session-id without numeric accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:ipc?session-id=tag:123456");
    defer uri.deinit();

    try std.testing.expectEqualStrings("tag:123456", uri.get("session-id").?);
    try std.testing.expect(uri.sessionId() == null);
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

test "AeronUri: parse size suffixes and aliases" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(
        allocator,
        "aeron:udp?endpoint=localhost:5050|mtu=8k|term-length=4m|so-sndbuf=64k|so-rcvbuf=32k|rcv-wnd=1k",
    );
    defer uri.deinit();

    try std.testing.expectEqual(@as(usize, 8 * 1024), uri.mtu().?);
    try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), uri.termLength().?);
    try std.testing.expectEqual(@as(usize, 64 * 1024), uri.socketSndbuf().?);
    try std.testing.expectEqual(@as(usize, 32 * 1024), uri.socketRcvbuf().?);
    try std.testing.expectEqual(@as(i64, 1024), uri.receiverWindow().?);
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

test "AeronUri: linger accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|linger=5000");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u32, 5000), uri.linger().?);
}

test "AeronUri: linger duration units" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|linger=50ms");
    defer uri.deinit();
    try std.testing.expectEqual(@as(u32, 50_000_000), uri.linger().?);
}

test "AeronUri: flowControl accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|flow-control=min");
    defer uri.deinit();
    try std.testing.expectEqualStrings("min", uri.flowControl().?);
}

test "AeronUri: socketSndbuf and socketRcvbuf accessors" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|socket-sndbuf=2097152|socket-rcvbuf=1048576");
    defer uri.deinit();
    try std.testing.expectEqual(@as(usize, 2097152), uri.socketSndbuf().?);
    try std.testing.expectEqual(@as(usize, 1048576), uri.socketRcvbuf().?);
}

test "AeronUri: receiverWindow accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|receiver-window=524288");
    defer uri.deinit();
    try std.testing.expectEqual(@as(i64, 524288), uri.receiverWindow().?);
}

test "AeronUri: alias accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|alias=my-channel");
    defer uri.deinit();
    try std.testing.expectEqualStrings("my-channel", uri.alias().?);
}

test "AeronUri: tags accessor" {
    const allocator = std.testing.allocator;
    var uri = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|tags=1,2,3");
    defer uri.deinit();
    try std.testing.expectEqualStrings("1,2,3", uri.tags().?);
}

test "AeronUri: term-length must be power of two" {
    const allocator = std.testing.allocator;
    // Valid power-of-2 in range
    var ok = try AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=65536");
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 65536), ok.termLength().?);

    // Not a power of two
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=65537"));

    // Below minimum (32768 < 65536)
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=32768"));

    // Above maximum
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|term-length=2147483648"));
}

test "AeronUri: reject invalid linger value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|linger=notanumber"));
}

test "AeronUri: reject invalid tagged session-id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:ipc?session-id=tag:abc"));
}

test "AeronUri: tagged helpers" {
    try std.testing.expect(AeronUri.isTagged("tag:123"));
    try std.testing.expectEqual(@as(i64, 123), AeronUri.getTag("tag:123"));
    try std.testing.expectEqual(INVALID_TAG, AeronUri.getTag("plain"));
}

test "AeronUri: createDestinationUri keeps only media endpoint and interface" {
    const allocator = std.testing.allocator;

    const uri1 = try AeronUri.createDestinationUri(allocator, "aeron:udp?endpoint=poison|interface=iface|mtu=4444", "dest1");
    defer allocator.free(uri1);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=dest1|interface=iface", uri1);

    const uri2 = try AeronUri.createDestinationUri(allocator, "aeron:ipc", "dest2");
    defer allocator.free(uri2);
    try std.testing.expectEqualStrings("aeron:ipc?endpoint=dest2", uri2);

    const uri3 = try AeronUri.createDestinationUri(allocator, "aeron-spy:aeron:udp?eol=true|interface=none", "abc");
    defer allocator.free(uri3);
    try std.testing.expectEqualStrings("aeron:udp?endpoint=abc|interface=none", uri3);
}

test "AeronUri: reject invalid socket-sndbuf value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|socket-sndbuf=-1"));
}

test "AeronUri: reject invalid receiver-window value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidParam, AeronUri.parse(allocator, "aeron:udp?endpoint=localhost:40123|receiver-window=notanumber"));
}
