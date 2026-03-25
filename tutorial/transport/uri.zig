const std = @import("std");

pub const AeronUri = struct {
    media_type: MediaType,
    params: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    raw_uri: []const u8,

    pub const MediaType = enum {
        udp,
        ipc,
    };

    pub const ControlMode = enum {
        dynamic,
        manual,

        pub fn fromString(s: []const u8) ?ControlMode {
            if (std.mem.eql(u8, s, "dynamic")) return .dynamic;
            if (std.mem.eql(u8, s, "manual")) return .manual;
            return null;
        }
    };

    pub const ParseError = error{
        InvalidUri,
        InvalidMediaType,
    };

    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) (ParseError || std.mem.Allocator.Error)!AeronUri {
        // Parse "aeron:udp?..." or "aeron:ipc?..."
        if (!std.mem.startsWith(u8, uri_str, "aeron:")) {
            return ParseError.InvalidUri;
        }

        const after_prefix = uri_str["aeron:".len..];
        var media_type: MediaType = undefined;
        var query: ?[]const u8 = null;

        // Determine media type and extract query part
        if (std.mem.startsWith(u8, after_prefix, "udp")) {
            media_type = .udp;
            const rest = after_prefix["udp".len..];
            if (rest.len == 0) {
                query = null;
            } else if (rest[0] == '?') {
                query = rest[1..];
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

        // Save a copy of the raw URI
        const raw_uri = try allocator.dupe(u8, uri_str);
        errdefer allocator.free(raw_uri);

        // Parse query parameters separated by '|'
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

                const owned_key = try allocator.dupe(u8, key);
                errdefer allocator.free(owned_key);
                const owned_value = try allocator.dupe(u8, value);
                errdefer allocator.free(owned_value);

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
};

test "AeronUri.parse: basic udp endpoint" {
    var uri = try AeronUri.parse(std.testing.allocator, "aeron:udp?endpoint=localhost:20121");
    defer uri.deinit();
    const ep = uri.endpoint() orelse return error.NoEndpoint;
    try std.testing.expectEqualStrings("localhost:20121", ep);
}

test "AeronUri.parse: ipc channel has no endpoint" {
    var uri = try AeronUri.parse(std.testing.allocator, "aeron:ipc");
    defer uri.deinit();
    try std.testing.expect(uri.endpoint() == null);
}

test "ControlMode.fromString: known values" {
    try std.testing.expectEqual(ControlMode.dynamic, ControlMode.fromString("dynamic"));
    try std.testing.expectEqual(ControlMode.manual, ControlMode.fromString("manual"));
}

test "ControlMode.fromString: unknown value returns null" {
    try std.testing.expect(ControlMode.fromString("bogus") == null);
}
