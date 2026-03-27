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
    pub const SendChannelEndpoint = @import("transport/endpoint.zig").SendChannelEndpoint;
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

// LESSON(what-is-aeron): Aeron is a factory and lifecycle container for the client-side API. It holds the cnc.dat file handle, ring buffer and broadcast receiver for driver communication, and hash maps of owned Publication and Subscription instances. The embedded_driver field is optional—clients can spawn their own driver or connect to an existing one via cnc.dat. See docs/tutorial/00-orientation/01-what-is-aeron.md
pub const Aeron = struct {
    ctx: AeronContext,
    allocator: std.mem.Allocator,
    cnc_file: cnc.CncFile,
    to_driver_ring_buffer: ipc.ring_buffer.ManyToOneRingBuffer,
    to_clients_broadcast_receiver: ipc.broadcast.BroadcastReceiver,
    counters_map: ipc.counters.CountersMap,
    client_id: i64,

    // Tracking
    publications: std.AutoHashMapUnmanaged(i64, *ExclusivePublication),
    subscriptions: std.AutoHashMapUnmanaged(i64, *Subscription),
    pending_subscription_streams: std.AutoHashMapUnmanaged(i64, i32),
    embedded_driver: ?*driver.MediaDriver = null,

    const PublicationLogHandle = struct {
        buffer: *logbuffer.LogBuffer,
        owns_buffer: bool,
    };

    // LESSON(what-is-aeron): Aeron.init opens the cnc.dat file, extracts the shared to-driver ring buffer and to-clients broadcast receiver. The client writes commands (add_publication, add_subscription) to the ring buffer; the driver writes responses (session_id, stream_id) to the broadcast. All subsequent publications and subscriptions reference log buffers allocated by the driver and discoverable via the shared broadcast. See docs/tutorial/00-orientation/01-what-is-aeron.md
    pub fn init(allocator: std.mem.Allocator, ctx: AeronContext) !Aeron {
        const cnc_path = try std.fmt.allocPrint(allocator, "{s}/cnc.dat", .{ctx.aeron_dir});
        defer allocator.free(cnc_path);

        var file = try cnc.CncFile.open(allocator, cnc_path);
        const to_driver = file.toDriverBuffer();
        const to_clients = file.toClientsBuffer();
        const counters_meta = file.countersMetadataBuffer();
        const counters_values = file.countersValuesBuffer();
        var to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(to_driver);
        const client_id = to_driver_ring_buffer.nextCorrelationId();

        return Aeron{
            .ctx = ctx,
            .allocator = allocator,
            .cnc_file = file,
            .to_driver_ring_buffer = to_driver_ring_buffer,
            .to_clients_broadcast_receiver = ipc.broadcast.BroadcastReceiver.wrap(to_clients),
            .counters_map = ipc.counters.CountersMap.init(counters_meta, counters_values),
            .client_id = client_id,
            .publications = .{},
            .subscriptions = .{},
            .pending_subscription_streams = .{},
        };
    }

    pub fn deinit(self: *Aeron) void {
        var mutable_cnc = self.cnc_file;
        mutable_cnc.deinit();

        var pub_it = self.publications.iterator();
        while (pub_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
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
        self.pending_subscription_streams.deinit(self.allocator);
    }

    fn openPublicationLogBuffer(self: *Aeron, log_file_name: []const u8, session_id: i32, stream_id: i32) ?PublicationLogHandle {
        const full_path = if (std.fs.path.isAbsolute(log_file_name))
            self.allocator.dupe(u8, log_file_name) catch return null
        else
            std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.ctx.aeron_dir, log_file_name }) catch return null;
        defer self.allocator.free(full_path);

        const mapped = self.allocator.create(logbuffer.LogBuffer) catch return null;
        mapped.* = logbuffer.LogBuffer.openMapped(self.allocator, full_path) catch {
            self.allocator.destroy(mapped);
            if (self.embedded_driver) |md| {
                if (md.getPublicationLogBuffer(session_id, stream_id)) |lb| {
                    return .{ .buffer = lb, .owns_buffer = false };
                }
            }
            return null;
        };

        return .{ .buffer = mapped, .owns_buffer = true };
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
                const stream_id = self.pending_subscription_streams.get(correlation_id) orelse 0;
                const channel_status_indicator_id = std.mem.readInt(i32, buffer[8..12], .little);
                _ = channel_status_indicator_id;

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
                _ = self.pending_subscription_streams.remove(correlation_id);
                work += 1;
            } else if (msg_type_id == driver.conductor.RESPONSE_ON_PUBLICATION_READY) {
                if (buffer.len < 36) continue;

                const correlation_id = std.mem.readInt(i64, buffer[0..8], .little);
                const registration_id = std.mem.readInt(i64, buffer[8..16], .little);
                const session_id = std.mem.readInt(i32, buffer[16..20], .little);
                const stream_id = std.mem.readInt(i32, buffer[20..24], .little);
                const publisher_limit_counter_id = std.mem.readInt(i32, buffer[24..28], .little);
                const channel_status_indicator_id = std.mem.readInt(i32, buffer[28..32], .little);
                const log_file_name_length = std.mem.readInt(i32, buffer[32..36], .little);

                if (log_file_name_length < 0) continue;
                const log_file_name_len: usize = @intCast(log_file_name_length);
                if (buffer.len < 36 + log_file_name_len) continue;

                const log_file_name = buffer[36 .. 36 + log_file_name_len];
                _ = correlation_id;
                _ = channel_status_indicator_id;

                if (self.openPublicationLogBuffer(log_file_name, session_id, stream_id)) |log_handle| {
                    const pub_instance = self.allocator.create(ExclusivePublication) catch {
                        if (log_handle.owns_buffer) {
                            log_handle.buffer.deinit();
                            self.allocator.destroy(log_handle.buffer);
                        }
                        continue;
                    };

                    pub_instance.* = ExclusivePublication.init(
                        session_id,
                        stream_id,
                        0,
                        log_handle.buffer.term_length,
                        1408,
                        log_handle.buffer,
                    );
                    pub_instance.owns_log_buffer = log_handle.owns_buffer;

                    if (publisher_limit_counter_id != ipc.counters.NULL_COUNTER_ID) {
                        pub_instance.attachPublisherLimitCounter(&self.counters_map, publisher_limit_counter_id);
                    }

                    self.publications.put(self.allocator, registration_id, pub_instance) catch {
                        pub_instance.deinit(self.allocator);
                        self.allocator.destroy(pub_instance);
                        continue;
                    };
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

    // LESSON(what-is-aeron): addSubscription encodes the upstream SubscriptionMessageFlyweight layout into the to-driver ring buffer: client_id, correlation_id, registration_correlation_id, stream_id, channel_length, then channel bytes. The driver's Conductor reads that payload and sends RESPONSE_ON_SUBSCRIPTION_READY keyed by correlation_id. See docs/tutorial/00-orientation/01-what-is-aeron.md
    pub fn addSubscription(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.to_driver_ring_buffer.nextCorrelationId();

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], self.client_id, .little);
        std.mem.writeInt(i64, buf[8..16], correlation_id, .little);
        std.mem.writeInt(i64, buf[16..24], -1, .little);
        std.mem.writeInt(i32, buf[24..28], stream_id, .little);
        std.mem.writeInt(i32, buf[28..32], @as(i32, @intCast(channel.len)), .little);
        @memcpy(buf[32 .. 32 + channel.len], channel);

        if (!self.to_driver_ring_buffer.write(driver.conductor.CMD_ADD_SUBSCRIPTION, buf[0 .. 32 + channel.len])) {
            return error.RingBufferFull;
        }
        try self.pending_subscription_streams.put(self.allocator, correlation_id, stream_id);

        return correlation_id;
    }

    // LESSON(what-is-zig): addPublication is the complementary client-to-driver handshake for writers. It uses the upstream PublicationMessageFlyweight layout: client_id, correlation_id, stream_id, channel_length, then channel bytes. The Conductor allocates an ExclusivePublication with a log buffer and responds with RESPONSE_ON_PUBLICATION_READY using the same correlation_id. See docs/tutorial/00-orientation/02-what-is-zig.md
    pub fn addPublication(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.to_driver_ring_buffer.nextCorrelationId();

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], self.client_id, .little);
        std.mem.writeInt(i64, buf[8..16], correlation_id, .little);
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

    // Need a driver to create cnc.dat first
    var md = try driver.MediaDriver.create(allocator, .{ .aeron_dir = ctx.aeron_dir });
    defer md.destroy();

    var aeron = try Aeron.init(allocator, ctx);
    defer aeron.deinit();
    _ = aeron.doWork();
}

test "Aeron addSubscription encodes upstream SubscriptionMessageFlyweight layout" {
    const allocator = std.testing.allocator;

    var ring_storage align(8) = [_]u8{0} ** 512;
    @memset(&ring_storage, 0);

    var aeron = Aeron{
        .ctx = .{},
        .allocator = allocator,
        .cnc_file = undefined,
        .to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(&ring_storage),
        .to_clients_broadcast_receiver = undefined,
        .counters_map = undefined,
        .client_id = 7,
        .publications = .{},
        .subscriptions = .{},
        .pending_subscription_streams = .{},
        .embedded_driver = null,
    };
    defer aeron.publications.deinit(allocator);
    defer aeron.subscriptions.deinit(allocator);
    defer aeron.pending_subscription_streams.deinit(allocator);

    const channel = "aeron:udp?endpoint=localhost:20121";
    const correlation_id = try aeron.addSubscription(channel, 1001);

    const Capture = struct {
        msg_type: i32 = 0,
        payload: []const u8 = "",
    };
    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
            const capture: *Capture = @ptrCast(@alignCast(ctx));
            capture.msg_type = msg_type_id;
            capture.payload = data;
        }
    }.handle;

    var capture = Capture{};
    try std.testing.expectEqual(@as(i32, 1), aeron.to_driver_ring_buffer.read(handler, @ptrCast(&capture), 1));
    try std.testing.expectEqual(driver.conductor.CMD_ADD_SUBSCRIPTION, capture.msg_type);
    try std.testing.expectEqual(@as(i64, 7), std.mem.readInt(i64, capture.payload[0..8], .little));
    try std.testing.expectEqual(correlation_id, std.mem.readInt(i64, capture.payload[8..16], .little));
    try std.testing.expectEqual(@as(i64, -1), std.mem.readInt(i64, capture.payload[16..24], .little));
    try std.testing.expectEqual(@as(i32, 1001), std.mem.readInt(i32, capture.payload[24..28], .little));
    try std.testing.expectEqual(@as(i32, @intCast(channel.len)), std.mem.readInt(i32, capture.payload[28..32], .little));
    try std.testing.expectEqualStrings(channel, capture.payload[32..]);
}

test "Aeron addPublication encodes upstream PublicationMessageFlyweight layout" {
    const allocator = std.testing.allocator;

    var ring_storage align(8) = [_]u8{0} ** 512;
    @memset(&ring_storage, 0);

    var aeron = Aeron{
        .ctx = .{},
        .allocator = allocator,
        .cnc_file = undefined,
        .to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(&ring_storage),
        .to_clients_broadcast_receiver = undefined,
        .counters_map = undefined,
        .client_id = 9,
        .publications = .{},
        .subscriptions = .{},
        .pending_subscription_streams = .{},
        .embedded_driver = null,
    };
    defer aeron.publications.deinit(allocator);
    defer aeron.subscriptions.deinit(allocator);
    defer aeron.pending_subscription_streams.deinit(allocator);

    const channel = "aeron:udp?endpoint=localhost:20121";
    const correlation_id = try aeron.addPublication(channel, 1001);

    const Capture = struct {
        msg_type: i32 = 0,
        payload: []const u8 = "",
    };
    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
            const capture: *Capture = @ptrCast(@alignCast(ctx));
            capture.msg_type = msg_type_id;
            capture.payload = data;
        }
    }.handle;

    var capture = Capture{};
    try std.testing.expectEqual(@as(i32, 1), aeron.to_driver_ring_buffer.read(handler, @ptrCast(&capture), 1));
    try std.testing.expectEqual(driver.conductor.CMD_ADD_PUBLICATION, capture.msg_type);
    try std.testing.expectEqual(@as(i64, 9), std.mem.readInt(i64, capture.payload[0..8], .little));
    try std.testing.expectEqual(correlation_id, std.mem.readInt(i64, capture.payload[8..16], .little));
    try std.testing.expectEqual(@as(i32, 1001), std.mem.readInt(i32, capture.payload[16..20], .little));
    try std.testing.expectEqual(@as(i32, @intCast(channel.len)), std.mem.readInt(i32, capture.payload[20..24], .little));
    try std.testing.expectEqualStrings(channel, capture.payload[24..]);
}

test "Aeron doWork parses full publication-ready payload and maps log buffer" {
    const allocator = std.testing.allocator;
    const aeron_dir = "/tmp/aeron-test-publication-ready";
    defer std.fs.deleteTreeAbsolute(aeron_dir) catch {};
    try std.fs.makeDirAbsolute(aeron_dir);

    const log_file_name = "pub-ready.logbuffer";
    const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aeron_dir, log_file_name });
    defer allocator.free(log_path);

    var created = try logbuffer.LogBuffer.initMapped(allocator, 64 * 1024, log_path);
    created.deinit();

    var ring_storage align(8) = [_]u8{0} ** 512;
    @memset(&ring_storage, 0);

    var bcast = try ipc.broadcast.BroadcastTransmitter.init(allocator, 1024);
    defer bcast.deinit(allocator);

    var meta align(64) = [_]u8{0} ** (ipc.counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (ipc.counters.COUNTER_LENGTH * 4);
    var counters_map = ipc.counters.CountersMap.init(&meta, &values);
    counters_map.set(0, 4096);

    const payload_len = 36 + log_file_name.len;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    std.mem.writeInt(i64, payload[0..8], 55, .little);
    std.mem.writeInt(i64, payload[8..16], 55, .little);
    std.mem.writeInt(i32, payload[16..20], 7, .little);
    std.mem.writeInt(i32, payload[20..24], 1001, .little);
    std.mem.writeInt(i32, payload[24..28], 0, .little);
    std.mem.writeInt(i32, payload[28..32], 1, .little);
    std.mem.writeInt(i32, payload[32..36], @as(i32, @intCast(log_file_name.len)), .little);
    @memcpy(payload[36..], log_file_name);
    try bcast.transmit(driver.conductor.RESPONSE_ON_PUBLICATION_READY, payload);

    var aeron = Aeron{
        .ctx = .{ .aeron_dir = aeron_dir },
        .allocator = allocator,
        .cnc_file = undefined,
        .to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(&ring_storage),
        .to_clients_broadcast_receiver = ipc.broadcast.BroadcastReceiver.wrap(bcast.full_buffer),
        .counters_map = counters_map,
        .client_id = 12,
        .publications = .{},
        .subscriptions = .{},
        .pending_subscription_streams = .{},
        .embedded_driver = null,
    };
    defer {
        var pub_it = aeron.publications.iterator();
        while (pub_it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        aeron.publications.deinit(allocator);
        aeron.subscriptions.deinit(allocator);
        aeron.pending_subscription_streams.deinit(allocator);
    }

    try std.testing.expectEqual(@as(i32, 1), aeron.doWork());
    const pub_instance = aeron.getPublication(55) orelse return error.MissingPublication;
    try std.testing.expectEqual(@as(i32, 7), pub_instance.session_id);
    try std.testing.expectEqual(@as(i32, 1001), pub_instance.stream_id);
    try std.testing.expectEqual(@as(i32, 0), pub_instance.publisher_limit_counter_id);
    try std.testing.expect(pub_instance.owns_log_buffer);
}
