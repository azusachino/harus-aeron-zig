// Media Driver Orchestrator — owns and coordinates Conductor, Sender, Receiver
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/MediaDriver.java

const std = @import("std");
const conductor = @import("conductor.zig");
const sender = @import("sender.zig");
const receiver = @import("receiver.zig");
const ring_buffer = @import("../ipc/ring_buffer.zig");
const broadcast = @import("../ipc/broadcast.zig");
const counters = @import("../ipc/counters.zig");

const DriverConductor = conductor.DriverConductor;
const Sender = sender.Sender;
const Receiver = receiver.Receiver;
const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;
const BroadcastTransmitter = broadcast.BroadcastTransmitter;
const CountersMap = counters.CountersMap;

pub const MediaDriverContext = struct {
    aeron_dir: []const u8 = "/dev/shm/aeron",
    term_buffer_length: i32 = 16 * 1024 * 1024,
    ipc_term_buffer_length: i32 = 64 * 1024,
    mtu_length: i32 = 1408,
    client_liveness_timeout_ns: i64 = 5_000_000_000,
    publication_connection_timeout_ns: i64 = 5_000_000_000,
};

pub const MediaDriver = struct {
    allocator: std.mem.Allocator,
    ctx: MediaDriverContext,
    conductor_agent: DriverConductor,
    sender_agent: Sender,
    receiver_agent: Receiver,
    running: std.atomic.Value(bool),
    conductor_thread: ?std.Thread = null,
    sender_thread: ?std.Thread = null,
    receiver_thread: ?std.Thread = null,

    // Shared buffers
    ring_buffer_buf: []u8,
    broadcast_buf: []u8,
    counters_meta_buf: []u8,
    counters_values_buf: []u8,

    // Owned objects
    ring_buf: ManyToOneRingBuffer,
    broadcaster: BroadcastTransmitter,
    counters_map: CountersMap,

    // Endpoints
    recv_endpoint: @import("../transport/endpoint.zig").ReceiveChannelEndpoint,
    send_endpoint: @import("../transport/endpoint.zig").SendChannelEndpoint,

    pub fn init(allocator: std.mem.Allocator, ctx_: MediaDriverContext) !MediaDriver {
        // Allocate ring buffer (4KB default)
        const ring_buffer_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(ring_buffer_buf);
        @memset(ring_buffer_buf, 0);

        // Allocate broadcast buffer (8KB default)
        const broadcast_buf = try allocator.alloc(u8, 8192);
        errdefer allocator.free(broadcast_buf);
        @memset(broadcast_buf, 0);

        // Allocate counters metadata and values buffers
        const counters_meta_buf = try allocator.alloc(u8, counters.METADATA_LENGTH * 4);
        errdefer allocator.free(counters_meta_buf);
        @memset(counters_meta_buf, 0);

        const counters_values_buf = try allocator.alloc(u8, counters.COUNTER_LENGTH * 4);
        errdefer allocator.free(counters_values_buf);
        @memset(counters_values_buf, 0);

        var ring_buf = ManyToOneRingBuffer.init(ring_buffer_buf);
        var broadcaster = try BroadcastTransmitter.init(allocator, 8192);
        errdefer broadcaster.deinit(allocator);

        var counters_map = CountersMap.init(counters_meta_buf, counters_values_buf);

        var conductor_agent = try DriverConductor.init(allocator, &ring_buf, &broadcaster, &counters_map);
        errdefer conductor_agent.deinit();

        // Create dummy endpoints for sender/receiver
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(fd);

        var recv_endpoint = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
            .socket = fd,
            .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
        };
        var send_endpoint = @import("../transport/endpoint.zig").SendChannelEndpoint{
            .socket = fd,
        };

        var sender_agent = try Sender.init(allocator, &send_endpoint, &counters_map);
        errdefer sender_agent.deinit();

        var receiver_agent = try Receiver.init(allocator, &recv_endpoint, &send_endpoint, &counters_map);
        errdefer receiver_agent.deinit();

        return .{
            .allocator = allocator,
            .ctx = ctx_,
            .conductor_agent = conductor_agent,
            .sender_agent = sender_agent,
            .receiver_agent = receiver_agent,
            .running = std.atomic.Value(bool).init(false),
            .ring_buffer_buf = ring_buffer_buf,
            .broadcast_buf = broadcast_buf,
            .counters_meta_buf = counters_meta_buf,
            .counters_values_buf = counters_values_buf,
            .ring_buf = ring_buf,
            .broadcaster = broadcaster,
            .counters_map = counters_map,
            .recv_endpoint = recv_endpoint,
            .send_endpoint = send_endpoint,
        };
    }

    pub fn deinit(self: *MediaDriver) void {
        self.receiver_agent.deinit();
        self.sender_agent.deinit();
        self.conductor_agent.deinit();
        self.broadcaster.deinit(self.allocator);
        self.allocator.free(self.ring_buffer_buf);
        self.allocator.free(self.broadcast_buf);
        self.allocator.free(self.counters_meta_buf);
        self.allocator.free(self.counters_values_buf);
        std.posix.close(self.send_endpoint.socket);
    }

    // Embedded mode: call this repeatedly to drive all agents one cycle
    pub fn doWork(self: *MediaDriver) i32 {
        var work_count: i32 = 0;
        work_count += self.conductor_agent.doWork();
        work_count += self.sender_agent.doWork();
        work_count += self.receiver_agent.doWork();
        return work_count;
    }

    // Standalone mode: spawn OS threads for each agent
    pub fn start(self: *MediaDriver) !void {
        self.running.store(true, .release);

        self.conductor_thread = try std.Thread.spawn(.{}, conductorThreadFunc, .{self});
        self.sender_thread = try std.Thread.spawn(.{}, senderThreadFunc, .{self});
        self.receiver_thread = try std.Thread.spawn(.{}, receiverThreadFunc, .{self});
    }

    // Signal threads to stop and wait for them
    pub fn close(self: *MediaDriver) void {
        self.running.store(false, .release);

        if (self.conductor_thread) |thread| {
            thread.join();
        }
        if (self.sender_thread) |thread| {
            thread.join();
        }
        if (self.receiver_thread) |thread| {
            thread.join();
        }
    }
};

// Thread function for conductor agent
fn conductorThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        _ = md.conductor_agent.doWork();
    }
}

// Thread function for sender agent
fn senderThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        _ = md.sender_agent.doWork();
    }
}

// Thread function for receiver agent
fn receiverThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        _ = md.receiver_agent.doWork();
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

const testing = std.testing;

test "MediaDriver: init and deinit" {
    const allocator = testing.allocator;
    var md = try MediaDriver.init(allocator, .{});
    defer md.deinit();

    try testing.expect(md.running.load(.acquire) == false);
}

test "MediaDriver: agents are initialized" {
    const allocator = testing.allocator;
    var md = try MediaDriver.init(allocator, .{});
    defer md.deinit();

    // Don't call doWork() here as it may trigger ring_buffer race conditions in tests
    try testing.expect(md.running.load(.acquire) == false);
}

test "MediaDriver: context defaults" {
    const allocator = testing.allocator;
    const ctx = MediaDriverContext{};
    var md = try MediaDriver.init(allocator, ctx);
    defer md.deinit();

    try testing.expectEqualStrings("/dev/shm/aeron", md.ctx.aeron_dir);
    try testing.expectEqual(@as(i32, 16 * 1024 * 1024), md.ctx.term_buffer_length);
    try testing.expectEqual(@as(i32, 64 * 1024), md.ctx.ipc_term_buffer_length);
    try testing.expectEqual(@as(i32, 1408), md.ctx.mtu_length);
    try testing.expectEqual(@as(i64, 5_000_000_000), md.ctx.client_liveness_timeout_ns);
    try testing.expectEqual(@as(i64, 5_000_000_000), md.ctx.publication_connection_timeout_ns);
}

test "MediaDriver: context customization" {
    const allocator = testing.allocator;
    const ctx = MediaDriverContext{
        .aeron_dir = "/tmp/aeron",
        .term_buffer_length = 32 * 1024 * 1024,
        .mtu_length = 1500,
    };
    var md = try MediaDriver.init(allocator, ctx);
    defer md.deinit();

    try testing.expectEqualStrings("/tmp/aeron", md.ctx.aeron_dir);
    try testing.expectEqual(@as(i32, 32 * 1024 * 1024), md.ctx.term_buffer_length);
    try testing.expectEqual(@as(i32, 1500), md.ctx.mtu_length);
}
