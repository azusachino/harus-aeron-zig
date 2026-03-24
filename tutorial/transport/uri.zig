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
            _ = s;
            @panic("TODO: implement ControlMode.fromString (Chapter C-5)");
        }
    };

    pub const ParseError = error{
        InvalidUri,
        InvalidMediaType,
    };

    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) (ParseError || std.mem.Allocator.Error)!AeronUri {
        _ = allocator;
        _ = uri_str;
        @panic("TODO: implement AeronUri.parse (Chapter C-5)");
    }

    pub fn deinit(self: *AeronUri) void {
        _ = self;
        @panic("TODO: implement AeronUri.deinit (Chapter C-5)");
    }

    pub fn endpoint(self: *const AeronUri) ?[]const u8 {
        _ = self;
        @panic("TODO");
    }
    pub fn controlEndpoint(self: *const AeronUri) ?[]const u8 {
        _ = self;
        @panic("TODO");
    }
    pub fn controlMode(self: *const AeronUri) ?ControlMode {
        _ = self;
        @panic("TODO");
    }
    pub fn interfaceName(self: *const AeronUri) ?[]const u8 {
        _ = self;
        @panic("TODO");
    }
    pub fn mtu(self: *const AeronUri) ?usize {
        _ = self;
        @panic("TODO");
    }
    pub fn ttl(self: *const AeronUri) ?u8 {
        _ = self;
        @panic("TODO");
    }
    pub fn termLength(self: *const AeronUri) ?u32 {
        _ = self;
        @panic("TODO");
    }
    pub fn initialTermId(self: *const AeronUri) ?i32 {
        _ = self;
        @panic("TODO");
    }
    pub fn sessionId(self: *const AeronUri) ?i32 {
        _ = self;
        @panic("TODO");
    }
    pub fn reliable(self: *const AeronUri) bool {
        _ = self;
        @panic("TODO");
    }
    pub fn sparse(self: *const AeronUri) bool {
        _ = self;
        @panic("TODO");
    }
    pub fn get(self: *const AeronUri, key: []const u8) ?[]const u8 {
        _ = self;
        _ = key;
        @panic("TODO");
    }
};
