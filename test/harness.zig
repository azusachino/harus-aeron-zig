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
    driver: MediaDriver,
    log_buffers: std.ArrayList(*LogBuffer),
    images: std.ArrayList(*Image),

    pub fn init(allocator: std.mem.Allocator) !TestHarness {
        const md = try MediaDriver.init(allocator, .{});
        return .{
            .allocator = allocator,
            .driver = md,
            .log_buffers = std.ArrayList(*LogBuffer){},
            .images = std.ArrayList(*Image){},
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
        self.driver.deinit();
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
        var timer = try std.time.Timer.start();
        const timeout_ns = timeout_ms * std.time.ns_per_ms;

        const received_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));

        while (received_ptr.* < expected) {
            if (timer.read() > timeout_ns) {
                return error.Timeout;
            }

            _ = self.driver.doWork();
            const fragments = sub.poll(handler, ctx, 10);

            if (fragments == 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }
};
