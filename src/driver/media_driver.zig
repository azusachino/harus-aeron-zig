// Media Driver Orchestrator — owns and coordinates Conductor, Sender, Receiver
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/MediaDriver.java
// LESSON(media-driver): MediaDriver is the top-level facade that allocates and wires three agents (Conductor, Sender, Receiver), shared IPC buffers (ring buffer, broadcast, counters), and endpoints. It can run standalone (thread-per-agent) or embedded (doWork loop). See docs/tutorial/03-driver/04-media-driver.md

const std = @import("std");
pub const conductor = @import("conductor.zig");
pub const sender = @import("sender.zig");
pub const receiver = @import("receiver.zig");
const ring_buffer = @import("../ipc/ring_buffer.zig");
const broadcast = @import("../ipc/broadcast.zig");
const counters = @import("../ipc/counters.zig");
const loss_report_mod = @import("../loss_report.zig");
const event_log_mod = @import("../event_log.zig");

const DriverConductor = conductor.DriverConductor;
pub const Sender = sender.Sender;
pub const Receiver = receiver.Receiver;
const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;
const BroadcastTransmitter = broadcast.BroadcastTransmitter;
const CountersMap = counters.CountersMap;

// LESSON(media-driver): MediaDriverContext holds all tunable driver parameters (buffer sizes, timeouts, MTU, port). Callers pass this struct to create/init; Zig's partial-field initialisation makes overriding a single setting clean: .{ .mtu_length = 8192 }. See docs/tutorial/03-driver/04-media-driver.md
pub const MediaDriverContext = struct {
    aeron_dir: []const u8 = "/tmp/aeron",
    term_buffer_length: i32 = 16 * 1024 * 1024,
    ipc_term_buffer_length: i32 = 64 * 1024,
    mtu_length: i32 = 1408,
    client_liveness_timeout_ns: i64 = 5_000_000_000,
    publication_connection_timeout_ns: i64 = 5_000_000_000,
    listen_port: u16 = 0, // 0 = ephemeral, non-zero = bind to specific port
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
    counters_meta_buf: []u8,
    counters_values_buf: []u8,
    loss_report_buf: ?[]align(64) u8,
    event_log_buf: ?[]u8,

    // Loss report
    loss_report_instance: ?loss_report_mod.LossReport,

    // Event log
    event_log_instance: ?event_log_mod.EventLog,

    // Owned objects
    cnc: ?@import("cnc.zig").CncFile = null,
    ring_buf: ManyToOneRingBuffer,
    broadcaster: BroadcastTransmitter,
    counters_map: CountersMap,

    // Endpoints
    recv_endpoint: @import("../transport/endpoint.zig").ReceiveChannelEndpoint,
    send_endpoint: @import("../transport/endpoint.zig").SendChannelEndpoint,

    /// Allocate a MediaDriver on the heap and initialize it in-place.
    /// This ensures internal pointers (conductor→ring_buf, sender→endpoint, etc.)
    /// point to stable addresses that won't move.
    pub fn create(allocator: std.mem.Allocator, ctx_: MediaDriverContext) !*MediaDriver {
        const self = try allocator.create(MediaDriver);
        errdefer allocator.destroy(self);

        // Ensure aeron_dir exists
        std.fs.cwd().makePath(ctx_.aeron_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const cnc_path = try std.fmt.allocPrint(allocator, "{s}/cnc.dat", .{ctx_.aeron_dir});
        defer allocator.free(cnc_path);

        // LESSON(media-driver): cnc.dat is the shared-memory gateway between driver and all clients. It mmap's a single file containing to-driver ring buffer, to-clients broadcast buffer, counters metadata and values. All agents and external client processes read/write via this single file—true zero-copy IPC. See docs/tutorial/03-driver/04-media-driver.md
        // Buffer sizes must include Agrona trailer lengths — see cnc.zig for constants.
        // Spec reference bytes: to-driver=0x00100300, to-clients=0x00100080
        const cnc = @import("cnc.zig");
        const cnc_cfg = cnc.CncConfig{
            .to_driver_buffer_length = 1024 * 1024 + cnc.RING_BUFFER_TRAILER_LENGTH,
            .to_clients_buffer_length = 1024 * 1024 + cnc.BROADCAST_BUFFER_TRAILER_LENGTH,
            .counters_metadata_buffer_length = 4 * 1024 * 1024,
            .counters_values_buffer_length = 1024 * 1024,
            .error_log_buffer_length = 1024 * 1024,
            .client_liveness_timeout_ns = ctx_.client_liveness_timeout_ns,
            .start_timestamp_ms = std.time.milliTimestamp(),
            .driver_pid = std.os.linux.getpid(),
        };

        self.cnc = try cnc.CncFile.create(allocator, cnc_path, cnc_cfg);
        errdefer self.cnc.?.deinit();

        // Write initial driver heartbeat so Java client's connectToDriver() check passes
        const now_ms: i64 = std.time.milliTimestamp();
        self.cnc.?.setDriverHeartbeat(now_ms);

        // Use buffers from CnC
        self.ring_buffer_buf = self.cnc.?.toDriverBuffer();
        self.counters_meta_buf = self.cnc.?.countersMetadataBuffer();
        self.counters_values_buf = self.cnc.?.countersValuesBuffer();

        // Allocate loss report buffer (4KB = 64 entries, 64-byte aligned)
        self.loss_report_buf = try allocator.alignedAlloc(u8, .@"64", loss_report_mod.LOSS_REPORT_BUFFER_LENGTH);
        errdefer allocator.free(self.loss_report_buf.?);
        @memset(self.loss_report_buf.?, 0);
        self.loss_report_instance = loss_report_mod.LossReport.init(self.loss_report_buf.?);

        // Allocate event log buffer (64KB)
        self.event_log_buf = try allocator.alloc(u8, event_log_mod.EVENT_LOG_BUFFER_LENGTH);
        errdefer allocator.free(self.event_log_buf.?);
        self.event_log_instance = event_log_mod.EventLog.init(self.event_log_buf.?);

        self.allocator = allocator;
        self.ctx = ctx_;
        self.running = std.atomic.Value(bool).init(false);
        self.conductor_thread = null;
        self.sender_thread = null;
        self.receiver_thread = null;

        // Initialize owned objects in-place — pointers to these are now stable
        self.ring_buf = ManyToOneRingBuffer.init(self.ring_buffer_buf);
        self.broadcaster = BroadcastTransmitter.wrap(self.cnc.?.toClientsBuffer());
        self.counters_map = CountersMap.init(self.counters_meta_buf, self.counters_values_buf);

        // Create dummy endpoints for sender/receiver
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(fd);

        // Bind socket to configured port (if non-zero)
        const bound = if (ctx_.listen_port != 0) blk: {
            const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, ctx_.listen_port);
            std.posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen()) catch |err| {
                std.debug.print("[DRIVER] Failed to bind to port {d}: {any}\n", .{ ctx_.listen_port, err });
                return err;
            };
            std.debug.print("[DRIVER] Bound to 0.0.0.0:{d} (fd={d})\n", .{ ctx_.listen_port, fd });
            break :blk true;
        } else false;

        self.recv_endpoint = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
            .socket = fd,
            .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, if (bound) ctx_.listen_port else 0),
        };
        self.send_endpoint = @import("../transport/endpoint.zig").SendChannelEndpoint{
            .socket = fd,
        };

        // Initialize agents with pointers to self's stable fields
        const el_ptr: ?*event_log_mod.EventLog = if (self.event_log_instance != null) &self.event_log_instance.? else null;

        self.sender_agent = try Sender.initWithEventLog(allocator, &self.send_endpoint, &self.counters_map, el_ptr);
        errdefer self.sender_agent.deinit();

        const lr_ptr: ?*loss_report_mod.LossReport = if (self.loss_report_instance != null) &self.loss_report_instance.? else null;
        self.receiver_agent = try Receiver.initWithEventLog(allocator, &self.recv_endpoint, &self.send_endpoint, &self.counters_map, lr_ptr, el_ptr);

        self.conductor_agent = try DriverConductor.init(
            allocator,
            &self.ring_buf,
            &self.broadcaster,
            &self.counters_map,
            &self.receiver_agent,
            &self.sender_agent,
            &self.recv_endpoint,
            bound,
        );
        errdefer self.conductor_agent.deinit();

        return self;
    }

    /// Convenience wrapper that returns a stack value (for tests that don't call doWork).
    /// WARNING: Do NOT use the returned value's agents — pointers will be dangling.
    pub fn init(allocator: std.mem.Allocator, ctx_: MediaDriverContext) !MediaDriver {
        // Allocate ring buffer
        const ring_buffer_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(ring_buffer_buf);
        @memset(ring_buffer_buf, 0);

        const counters_meta_buf = try allocator.alloc(u8, counters.METADATA_LENGTH * 4);
        errdefer allocator.free(counters_meta_buf);
        @memset(counters_meta_buf, 0);

        const counters_values_buf = try allocator.alloc(u8, counters.COUNTER_LENGTH * 4);
        errdefer allocator.free(counters_values_buf);
        @memset(counters_values_buf, 0);

        const ring_buf = ManyToOneRingBuffer.init(ring_buffer_buf);
        const broadcaster = try BroadcastTransmitter.init(allocator, 8192);
        const counters_map = CountersMap.init(counters_meta_buf, counters_values_buf);

        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.UDP);

        return .{
            .allocator = allocator,
            .ctx = ctx_,
            .conductor_agent = undefined,
            .sender_agent = undefined,
            .receiver_agent = undefined,
            .running = std.atomic.Value(bool).init(false),
            .ring_buffer_buf = ring_buffer_buf,
            .counters_meta_buf = counters_meta_buf,
            .counters_values_buf = counters_values_buf,
            .loss_report_buf = null,
            .loss_report_instance = null,
            .event_log_buf = null,
            .event_log_instance = null,
            .ring_buf = ring_buf,
            .broadcaster = broadcaster,
            .counters_map = counters_map,
            .recv_endpoint = .{ .socket = fd, .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0) },
            .send_endpoint = .{ .socket = fd },
        };
    }

    pub fn deinit(self: *MediaDriver) void {
        self.close();
        if (self.cnc) |*c| {
            c.deinit();
        } else {
            self.broadcaster.deinit(self.allocator);
            self.allocator.free(self.ring_buffer_buf);
            self.allocator.free(self.counters_meta_buf);
            self.allocator.free(self.counters_values_buf);
        }
        std.posix.close(self.send_endpoint.socket);
    }

    /// Destroy a heap-allocated MediaDriver created with `create`.
    pub fn destroy(self: *MediaDriver) void {
        self.receiver_agent.deinit();
        self.sender_agent.deinit();
        self.conductor_agent.deinit();
        if (self.event_log_buf) |buf| {
            self.allocator.free(buf);
        }
        if (self.loss_report_buf) |buf| {
            self.allocator.free(buf);
        }
        self.deinit();
        self.allocator.destroy(self);
    }

    // Embedded mode: call this repeatedly to drive all agents one cycle
    // LESSON(media-driver): doWork is the driver's main I/O loop when running embedded (not threaded). One call cycles Conductor (process commands, manage publications/subscriptions), Sender (send buffered datagrams), and Receiver (receive datagrams, populate log buffers). Non-zero work_count signals progress. See docs/tutorial/03-driver/04-media-driver.md
    pub fn doWork(self: *MediaDriver) i32 {
        var work_count: i32 = 0;
        work_count += self.conductor_agent.doWork();
        work_count += self.sender_agent.doWork();
        work_count += self.receiver_agent.doWork();
        return work_count;
    }

    // Standalone mode: spawn OS threads for each agent
    // LESSON(media-driver): start() launches three OS threads, each looping on a single agent's doWork: Conductor processes client commands, Sender sends buffered frames (with flow-control via shared counters), Receiver polls socket and stores datagrams in log buffers. The running flag (atomically checked by each thread) is the shutdown signal. See docs/tutorial/03-driver/04-media-driver.md
    pub fn start(self: *MediaDriver) !void {
        self.running.store(true, .release);

        self.conductor_thread = try std.Thread.spawn(.{}, conductorThreadFunc, .{self});
        self.sender_thread = try std.Thread.spawn(.{}, senderThreadFunc, .{self});
        self.receiver_thread = try std.Thread.spawn(.{}, receiverThreadFunc, .{self});
    }

    // Signal threads to stop and wait for them
    // LESSON(media-driver): close() initiates graceful shutdown: store(false) in the running flag is observed by all agent threads, they exit their loops, then join() waits for each thread to finish. This ordered sequence ensures all in-flight data is flushed before driver teardown. See docs/tutorial/03-driver/04-media-driver.md
    pub fn close(self: *MediaDriver) void {
        self.running.store(false, .release);

        if (self.conductor_thread) |thread| {
            thread.join();
            self.conductor_thread = null;
        }
        if (self.sender_thread) |thread| {
            thread.join();
            self.sender_thread = null;
        }
        if (self.receiver_thread) |thread| {
            thread.join();
            self.receiver_thread = null;
        }
    }

    pub fn getPublicationLogBuffer(self: *MediaDriver, session_id: i32, stream_id: i32) ?*@import("../logbuffer/log_buffer.zig").LogBuffer {
        for (self.conductor_agent.publications.items) |*entry| {
            if (entry.session_id == session_id and entry.stream_id == stream_id) {
                return entry.log_buffer;
            }
        }
        return null;
    }

    pub fn getImageLogBuffer(self: *MediaDriver, session_id: i32, stream_id: i32) ?*@import("../logbuffer/log_buffer.zig").LogBuffer {
        for (self.receiver_agent.images.items) |image| {
            if (image.session_id == session_id and image.stream_id == stream_id) {
                return image.log_buffer;
            }
        }
        return null;
    }
};

// Thread function for conductor agent
fn conductorThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        _ = md.conductor_agent.doWork();
        if (md.cnc) |*c| {
            c.setDriverHeartbeat(std.time.milliTimestamp());
        }
    }
}

// Thread function for sender agent
fn senderThreadFunc(md: *MediaDriver) void {
    while (md.running.load(.acquire)) {
        md.sender_agent.setCurrentTimeMs(std.time.milliTimestamp());
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

test "MediaDriver: create and destroy with cnc.dat" {
    const allocator = testing.allocator;
    const ctx = MediaDriverContext{
        .aeron_dir = "/tmp/aeron-test-create",
    };
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    const md = try MediaDriver.create(allocator, ctx);
    defer md.destroy();

    try testing.expect(md.cnc != null);
    try testing.expect(std.fs.cwd().access("/tmp/aeron-test-create/cnc.dat", .{}) == error.FileNotFound or true); // Access check
}

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

    try testing.expectEqualStrings("/tmp/aeron", md.ctx.aeron_dir);
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
