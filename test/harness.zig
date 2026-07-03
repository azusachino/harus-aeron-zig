const std = @import("std");
const aeron = @import("aeron");
const MediaDriver = aeron.driver.MediaDriver;
const MediaDriverContext = aeron.driver.MediaDriverContext;
const ExclusivePublication = aeron.ExclusivePublication;
const Subscription = aeron.Subscription;
const LogBuffer = aeron.logbuffer.LogBuffer;
const Image = aeron.Image;
const FragmentHandler = aeron.logbuffer.term_reader.FragmentHandler;

pub const TestHarness = struct {
    allocator: std.mem.Allocator,
    driver: *MediaDriver,
    log_buffers: std.ArrayList(*LogBuffer),
    images: std.ArrayList(*Image),

    pub fn init(allocator: std.mem.Allocator) !TestHarness {
        const md = try MediaDriver.create(allocator, .{});
        return .{
            .allocator = allocator,
            .driver = md,
            .log_buffers = std.ArrayList(*LogBuffer).empty,
            .images = std.ArrayList(*Image).empty,
        };
    }

    pub fn deinit(self: *TestHarness) void {
        for (self.images.items) |img| {
            self.allocator.destroy(img);
        }
        self.images.deinit(self.allocator);

        for (self.log_buffers.items) |lb| {
            lb.deinit();
            self.allocator.destroy(lb);
        }
        self.log_buffers.deinit(self.allocator);
        self.driver.destroy();
    }

    // Drive conductor duty cycle n times
    pub fn doConductorWork(self: *TestHarness, n: usize) void {
        for (0..n) |_| {
            _ = self.driver.conductor_agent.doWork();
        }
    }

    // Inject a SETUP frame by parsing through processDatagram (exercises the real parsing path)
    pub fn injectSetupFrame(self: *TestHarness, sig: @import("aeron").driver.receiver.SetupSignal) !void {
        const protocol = @import("aeron").protocol;
        var buf: [40]u8 = undefined;

        // Build a raw SETUP frame from the sig fields
        var header: protocol.SetupHeader = undefined;
        header.frame_length = 40;
        header.version = 0;
        header.flags = 0;
        header.type = @intFromEnum(protocol.FrameType.setup);
        header.term_offset = 0;
        header.session_id = sig.session_id;
        header.stream_id = sig.stream_id;
        header.initial_term_id = sig.initial_term_id;
        header.active_term_id = sig.active_term_id;
        header.term_length = sig.term_length;
        header.mtu = sig.mtu;
        header.ttl = 0;

        @memcpy(&buf, std.mem.asBytes(&header));
        _ = self.driver.receiver_agent.processDatagram(&buf, sig.source_address);
    }

    pub fn createPublication(self: *TestHarness, stream_id: i32, channel: []const u8) !ExclusivePublication {
        // For integration tests, we'll use a fixed term length
        const term_length = 64 * 1024;
        const lb = try self.allocator.create(LogBuffer);
        lb.* = try LogBuffer.init(self.allocator, term_length);
        try self.log_buffers.append(self.allocator, lb);

        // Initialize term ID and tail
        const initial_term_id = 100;
        var meta = lb.metaData();
        meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
        meta.setActiveTermCount(0);

        var pub_instance = ExclusivePublication.init(1, stream_id, initial_term_id, term_length, 1408, lb);
        // Manually set publisher limit for IPC test bypass
        pub_instance.publisher_limit = 1024 * 1024;
        _ = channel;
        return pub_instance;
    }

    pub fn createSubscription(self: *TestHarness, stream_id: i32, channel: []const u8) !Subscription {
        var sub = try Subscription.init(self.allocator, stream_id, channel);

        // If we have a log buffer, wire it up as an Image
        if (self.log_buffers.items.len > 0) {
            const lb = self.log_buffers.items[self.log_buffers.items.len - 1];
            const initial_term_id = 100;
            const img = try self.allocator.create(Image);
            img.* = Image.init(1, stream_id, initial_term_id, lb);
            try self.images.append(self.allocator, img);
            try sub.addImage(img);
        }

        return sub;
    }

    pub fn doWorkLoop(self: *TestHarness, sub: *Subscription, ctx: *anyopaque, handler: FragmentHandler, expected: i32, timeout_ms: u64) !void {
        _ = self;
        const start_ns = aeron.time.nanoTimestamp();
        const timeout_ns: i128 = @intCast(timeout_ms * std.time.ns_per_ms);

        const received_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));

        while (received_ptr.* < expected) {
            if (aeron.time.nanoTimestamp() - start_ns > timeout_ns) {
                return error.Timeout;
            }

            const fragments = sub.poll(handler, ctx, 10);

            if (fragments == 0) {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    }
    pub fn createClusterNode(self: *TestHarness, ctx: aeron.cluster.consensus.ClusterContext, archive: anytype) !aeron.cluster.consensus.ConsensusModule {
        _ = archive;
        return try aeron.cluster.consensus.ConsensusModule.init(self.allocator, ctx);
    }

    pub fn injectDelay(self: *TestHarness, ms: u64) void {
        _ = self;
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
};
