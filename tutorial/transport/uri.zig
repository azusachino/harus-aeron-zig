// EXERCISE: Chapter 2.2 — Aeron URIs
// Reference: docs/tutorial/02-data-path/02-uri-parsing.md
//
// Your task: implement `AeronUri.parse` logic.
// Run `make tutorial-check` to verify your solution.

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
            @panic("TODO: implement ControlMode.fromString");
        }
    };

    pub const ParseError = error{
        InvalidUri,
        InvalidMediaType,
        InvalidParam,
    };

    pub fn parse(allocator: std.mem.Allocator, uri_str: []const u8) (ParseError || std.mem.Allocator.Error)!AeronUri {
        _ = allocator;
        _ = uri_str;
        @panic("TODO: implement AeronUri.parse");
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
};

test "AeronUri.parse" {
    // var uri = try AeronUri.parse(std.testing.allocator, "aeron:udp?endpoint=localhost:20121");
    // defer uri.deinit();
}
