const std = @import("std");

pub const HealthServer = struct {
    port: u16,
    is_ready: *std.atomic.Value(bool),
    thread: ?std.Thread = null,

    pub fn init(port: u16, is_ready: *std.atomic.Value(bool)) HealthServer {
        return .{ .port = port, .is_ready = is_ready };
    }

    pub fn start(self: *HealthServer) void {
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch null;
    }

    fn serve(self: *HealthServer) void {
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port) catch return;
        var server = addr.listen(.{
            .reuse_address = true,
        }) catch return;
        defer server.deinit();

        while (true) {
            const conn = server.accept() catch continue;
            defer conn.stream.close();
            handleConnection(conn.stream, self.is_ready);
        }
    }

    fn handleConnection(stream: std.net.Stream, is_ready: *std.atomic.Value(bool)) void {
        var buf: [256]u8 = undefined;
        const n = stream.read(&buf) catch return;
        if (n == 0) return;

        const request = buf[0..n];

        if (std.mem.startsWith(u8, request, "GET /healthz")) {
            _ = stream.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK") catch {};
        } else if (std.mem.startsWith(u8, request, "GET /readyz")) {
            if (is_ready.load(.acquire)) {
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nReady") catch {};
            } else {
                _ = stream.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 9\r\n\r\nNot Ready") catch {};
            }
        } else {
            _ = stream.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
        }
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

const testing = std.testing;

test "HealthServer: init" {
    var ready = std.atomic.Value(bool).init(true);
    const server = HealthServer.init(8080, &ready);
    try testing.expectEqual(@as(u16, 8080), server.port);
    try testing.expect(server.thread == null);
}
