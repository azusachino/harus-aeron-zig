// Aeron client library root
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub const protocol = @import("protocol/frame.zig");
pub const logbuffer = @import("logbuffer/log_buffer.zig");
pub const ipc = @import("ipc.zig");
pub const driver = @import("driver/media_driver.zig");
pub const cnc = @import("driver/cnc.zig");
pub const loss_report = @import("loss_report.zig");
pub const event_log = @import("event_log.zig");
pub const counters_report = @import("counters_report.zig");
pub const archive = struct {
    pub const protocol = @import("archive/protocol.zig");
    pub const catalog = @import("archive/catalog.zig");
    pub const conductor = @import("archive/conductor.zig");
    pub const recorder = @import("archive/recorder.zig");
    pub const replayer = @import("archive/replayer.zig");
};
pub const cluster = struct {
    pub const protocol = @import("cluster/protocol.zig");
    pub const election = @import("cluster/election.zig");
    pub const log = @import("cluster/log.zig");
    pub const conductor = @import("cluster/conductor.zig");
    pub const consensus = @import("cluster/cluster.zig");
};
pub const transport = struct {
    pub const ReceiveChannelEndpoint = @import("transport/endpoint.zig").ReceiveChannelEndpoint;
    pub const Poller = @import("transport/poller.zig").Poller;
    pub const UdpChannel = @import("transport/udp_channel.zig").UdpChannel;
    pub const AeronUri = @import("transport/uri.zig").AeronUri;
};

pub const ExclusivePublication = @import("publication.zig").ExclusivePublication;
pub const Subscription = @import("subscription.zig").Subscription;
pub const Image = @import("image.zig").Image;

pub const AeronContext = struct {
    aeron_dir: []const u8 = "/tmp/aeron",
};

// LESSON(what-is-aeron): Aeron is a factory and lifecycle container for the client-side API. It holds the CnC.dat file handle, ring buffer and broadcast receiver for driver communication, and hash maps of owned Publication and Subscription instances. The embedded_driver field is optional—clients can spawn their own driver or connect to an existing one via CnC.dat. See docs/tutorial/00-orientation/01-what-is-aeron.md
pub const Aeron = struct {
    ctx: AeronContext,
    allocator: std.mem.Allocator,
    cnc_file: cnc.CncFile,
    to_driver_ring_buffer: ipc.ring_buffer.ManyToOneRingBuffer,
    to_clients_broadcast_receiver: ipc.broadcast.BroadcastReceiver,
    counters_map: ipc.counters.CountersMap,
    next_correlation_id: std.atomic.Value(i64),

    // Tracking
    publications: std.AutoHashMapUnmanaged(i64, *ExclusivePublication),
    subscriptions: std.AutoHashMapUnmanaged(i64, *Subscription),
    embedded_driver: ?*driver.MediaDriver = null,

    // LESSON(what-is-aeron): Aeron.init opens the CnC.dat file, extracts the shared to-driver ring buffer and to-clients broadcast receiver. The client writes commands (add_publication, add_subscription) to the ring buffer; the driver writes responses (session_id, stream_id) to the broadcast. All subsequent publications and subscriptions reference log buffers allocated by the driver and discoverable via the shared broadcast. See docs/tutorial/00-orientation/01-what-is-aeron.md
    pub fn init(allocator: std.mem.Allocator, ctx: AeronContext) !Aeron {
        const cnc_path = try std.fmt.allocPrint(allocator, "{s}/CnC.dat", .{ctx.aeron_dir});
        defer allocator.free(cnc_path);

        var file = try cnc.CncFile.open(allocator, cnc_path);
        const to_driver = file.toDriverBuffer();
        const to_clients = file.toClientsBuffer();
        const counters_meta = file.countersMetadataBuffer();
        const counters_values = file.countersValuesBuffer();

        return Aeron{
            .ctx = ctx,
            .allocator = allocator,
            .cnc_file = file,
            .to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(to_driver),
            .to_clients_broadcast_receiver = ipc.broadcast.BroadcastReceiver.wrap(to_clients),
            .counters_map = ipc.counters.CountersMap.init(counters_meta, counters_values),
            .next_correlation_id = std.atomic.Value(i64).init(1),
            .publications = .{},
            .subscriptions = .{},
        };
    }

    pub fn deinit(self: *Aeron) void {
        var mutable_cnc = self.cnc_file;
        mutable_cnc.deinit();

        var pub_it = self.publications.iterator();
        while (pub_it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.publications.deinit(self.allocator);

        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |entry| {
            // Images are heap-allocated here (allocator.create in doWork); free before deinit.
            for (entry.value_ptr.*.images()) |img| {
                self.allocator.destroy(img);
            }
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.subscriptions.deinit(self.allocator);
    }

    // LESSON(what-is-zig): doWork is the client's polling loop. It drains all pending messages from the driver's broadcast buffer: RESPONSE_ON_PUBLICATION_READY (allocates ExclusivePublication with log buffer), RESPONSE_ON_SUBSCRIPTION_READY (allocates Subscription), RESPONSE_ON_IMAGE_READY (adds Image to subscription for a new publisher session). Call this in your application's main loop to discover new publications and subscriptions. See docs/tutorial/00-orientation/02-what-is-zig.md
    pub fn doWork(self: *Aeron) i32 {
        var work: i32 = 0;
        while (self.to_clients_broadcast_receiver.receiveNext()) {
            const msg_type_id = self.to_clients_broadcast_receiver.typeId();
            const buffer = self.to_clients_broadcast_receiver.buffer();

            if (msg_type_id == driver.conductor.RESPONSE_ON_IMAGE_READY) {
                const registration_id = std.mem.readInt(i64, buffer[0..8], .little);
                const session_id = std.mem.readInt(i32, buffer[8..12], .little);
                const stream_id = std.mem.readInt(i32, buffer[12..16], .little);
                const initial_term_id = if (buffer.len >= 20) std.mem.readInt(i32, buffer[16..20], .little) else 0;

                if (self.subscriptions.get(registration_id)) |sub| {
                    if (self.embedded_driver) |md| {
                        if (md.getImageLogBuffer(session_id, stream_id)) |lb| {
                            const img = self.allocator.create(Image) catch continue;
                            img.* = Image.init(session_id, stream_id, initial_term_id, lb);
                            sub.addImage(img) catch self.allocator.destroy(img);
                        }
                    }
                }
                work += 1;
            } else if (msg_type_id == driver.conductor.RESPONSE_ON_SUBSCRIPTION_READY) {
                const correlation_id = std.mem.readInt(i64, buffer[0..8], .little);
                const stream_id = std.mem.readInt(i32, buffer[8..12], .little);

                const sub = self.allocator.create(Subscription) catch continue;
                sub.* = Subscription.init(self.allocator, stream_id, "") catch {
                    self.allocator.destroy(sub);
                    continue;
                };
                self.subscriptions.put(self.allocator, correlation_id, sub) catch {
                    sub.deinit();
                    self.allocator.destroy(sub);
                    continue;
                };
                work += 1;
            } else if (msg_type_id == driver.conductor.RESPONSE_ON_PUBLICATION_READY) {
                const correlation_id = std.mem.readInt(i64, buffer[0..8], .little);
                const session_id = std.mem.readInt(i32, buffer[8..12], .little);
                const stream_id = std.mem.readInt(i32, buffer[12..16], .little);
                const publisher_limit_counter_id = if (buffer.len >= 20) std.mem.readInt(i32, buffer[16..20], .little) else ipc.counters.NULL_COUNTER_ID;

                if (self.embedded_driver) |md| {
                    if (md.getPublicationLogBuffer(session_id, stream_id)) |lb| {
                        const pub_instance = self.allocator.create(ExclusivePublication) catch continue;
                        pub_instance.* = ExclusivePublication.init(session_id, stream_id, 0, lb.term_length, 1408, lb);
                        if (publisher_limit_counter_id != ipc.counters.NULL_COUNTER_ID) {
                            pub_instance.attachPublisherLimitCounter(&self.counters_map, publisher_limit_counter_id);
                        }
                        self.publications.put(self.allocator, correlation_id, pub_instance) catch {
                            self.allocator.destroy(pub_instance);
                            continue;
                        };
                    }
                }
                work += 1;
            }
        }
        return work;
    }

    pub fn getPublication(self: *Aeron, registration_id: i64) ?*ExclusivePublication {
        return self.publications.get(registration_id);
    }

    pub fn getSubscription(self: *Aeron, registration_id: i64) ?*Subscription {
        return self.subscriptions.get(registration_id);
    }

    pub fn offer(self: *Aeron, registration_id: i64, data: []const u8) @import("publication.zig").OfferResult {
        if (self.publications.get(registration_id)) |pub_instance| {
            return pub_instance.offer(data);
        }
        return .not_connected;
    }

    pub fn poll(self: *Aeron, registration_id: i64, handler: @import("logbuffer/term_reader.zig").FragmentHandler, ctx: *anyopaque, fragment_limit: i32) i32 {
        if (self.subscriptions.get(registration_id)) |sub| {
            return sub.poll(handler, ctx, fragment_limit);
        }
        return 0;
    }

    // LESSON(what-is-aeron): addSubscription encodes a CMD_ADD_SUBSCRIPTION message (correlation_id, stream_id, channel) into the to-driver ring buffer. The driver's Conductor reads this message, allocates a log buffer for this (channel, stream_id) pair, and sends RESPONSE_ON_SUBSCRIPTION_READY back on the broadcast. The correlation_id lets the client match request to response. See docs/tutorial/00-orientation/01-what-is-aeron.md
    pub fn addSubscription(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.next_correlation_id.fetchAdd(1, .monotonic);

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i64, buf[8..16], -1, .little); // registration_id (-1 for new)
        std.mem.writeInt(i32, buf[16..20], stream_id, .little);
        std.mem.writeInt(i32, buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(buf[24 .. 24 + channel.len], channel);

        if (!self.to_driver_ring_buffer.write(driver.conductor.CMD_ADD_SUBSCRIPTION, buf[0 .. 24 + channel.len])) {
            return error.RingBufferFull;
        }

        return correlation_id;
    }

    // LESSON(what-is-zig): addPublication is the complementary client-to-driver handshake for writers. It packs CMD_ADD_PUBLICATION (correlation_id, stream_id, channel) and sends it to the driver. The Conductor allocates an ExclusivePublication with a log buffer, and responds with RESPONSE_ON_PUBLICATION_READY. The client polls doWork() to see the response and creates a local ExclusivePublication handle. See docs/tutorial/00-orientation/02-what-is-zig.md
    pub fn addPublication(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.next_correlation_id.fetchAdd(1, .monotonic);

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i64, buf[8..16], -1, .little); // registration_id (-1 for new)
        std.mem.writeInt(i32, buf[16..20], stream_id, .little);
        std.mem.writeInt(i32, buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(buf[24 .. 24 + channel.len], channel);

        if (!self.to_driver_ring_buffer.write(driver.conductor.CMD_ADD_PUBLICATION, buf[0 .. 24 + channel.len])) {
            return error.RingBufferFull;
        }

        return correlation_id;
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "Aeron init and deinit" {
    const allocator = std.testing.allocator;
    const ctx = AeronContext{ .aeron_dir = "/tmp/aeron-test-client" };
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    // Need a driver to create CnC.dat first
    var md = try driver.MediaDriver.create(allocator, .{ .aeron_dir = ctx.aeron_dir });
    defer md.destroy();

    var aeron = try Aeron.init(allocator, ctx);
    defer aeron.deinit();
    _ = aeron.doWork();
}
