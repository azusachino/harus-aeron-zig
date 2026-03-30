// Driver conductor: processes client IPC commands and manages driver resources
// (publications, subscriptions, counters)
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/DriverConductor.java

const std = @import("std");
const builtin = @import("builtin");
const ring_buffer = @import("../ipc/ring_buffer.zig");
const broadcast = @import("../ipc/broadcast.zig");
const counters = @import("../ipc/counters.zig");
const receiver_mod = @import("receiver.zig");
const sender_mod = @import("sender.zig");
const logbuffer = @import("../logbuffer/log_buffer.zig");
const frame = @import("../protocol/frame.zig");
const transport_uri = @import("../transport/udp_channel.zig");
const endpoint_mod = @import("../transport/endpoint.zig");
const signal = @import("../signal.zig");
const INVALID_SOCKET: std.posix.socket_t = std.math.maxInt(std.posix.socket_t);

const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;
const BroadcastTransmitter = broadcast.BroadcastTransmitter;
const CountersMap = counters.CountersMap;
const Receiver = receiver_mod.Receiver;
const Image = receiver_mod.Image;

// Command type IDs — match io.aeron.command.ControlProtocolEvents.
pub const CMD_ADD_PUBLICATION: i32 = 0x01;
pub const CMD_REMOVE_PUBLICATION: i32 = 0x02;
pub const CMD_ADD_EXCLUSIVE_PUBLICATION: i32 = 0x03;
pub const CMD_ADD_SUBSCRIPTION: i32 = 0x04;
pub const CMD_REMOVE_SUBSCRIPTION: i32 = 0x05;
pub const CMD_CLIENT_KEEPALIVE: i32 = 0x06;
pub const CMD_ADD_COUNTER: i32 = 0x09;
pub const CMD_REMOVE_COUNTER: i32 = 0x0A;
pub const CMD_TERMINATE_DRIVER: i32 = 0x0E;

// Response type IDs — match io.aeron.command.ControlProtocolEvents.
pub const RESPONSE_ON_ERROR: i32 = 0x0F01;
pub const RESPONSE_ON_IMAGE_READY: i32 = 0x0F02;
pub const RESPONSE_ON_PUBLICATION_READY: i32 = 0x0F03;
pub const RESPONSE_ON_IMAGE_CLOSE: i32 = 0x0F05;
pub const RESPONSE_ON_SUBSCRIPTION_READY: i32 = 0x0F07;
pub const RESPONSE_ON_COUNTER_READY: i32 = 0x0F08;
pub const RESPONSE_ON_OPERATION_SUCCESS: i32 = 0x0F04;

const CORRELATED_COMMAND_LENGTH: usize = 16;
const PUBLICATION_COMMAND_STREAM_ID_OFFSET: usize = CORRELATED_COMMAND_LENGTH;
const PUBLICATION_COMMAND_CHANNEL_LENGTH_OFFSET: usize = PUBLICATION_COMMAND_STREAM_ID_OFFSET + 4;
const PUBLICATION_COMMAND_CHANNEL_OFFSET: usize = PUBLICATION_COMMAND_CHANNEL_LENGTH_OFFSET + 4;
const REMOVE_COMMAND_REGISTRATION_ID_OFFSET: usize = CORRELATED_COMMAND_LENGTH;
const REMOVE_COMMAND_LENGTH: usize = REMOVE_COMMAND_REGISTRATION_ID_OFFSET + 8;
const SUBSCRIPTION_COMMAND_REGISTRATION_CORRELATION_ID_OFFSET: usize = CORRELATED_COMMAND_LENGTH;
const SUBSCRIPTION_COMMAND_STREAM_ID_OFFSET: usize = SUBSCRIPTION_COMMAND_REGISTRATION_CORRELATION_ID_OFFSET + 8;
const SUBSCRIPTION_COMMAND_CHANNEL_LENGTH_OFFSET: usize = SUBSCRIPTION_COMMAND_STREAM_ID_OFFSET + 4;
const SUBSCRIPTION_COMMAND_CHANNEL_OFFSET: usize = SUBSCRIPTION_COMMAND_CHANNEL_LENGTH_OFFSET + 4;
const LOG_META_PADDING_SIZE: usize = 64;
const LOG_META_CORRELATION_ID_OFFSET: usize = LOG_META_PADDING_SIZE * 4;
const LOG_META_INITIAL_TERM_ID_OFFSET: usize = LOG_META_CORRELATION_ID_OFFSET + 8;
const LOG_META_DEFAULT_FRAME_HEADER_LENGTH_OFFSET: usize = LOG_META_INITIAL_TERM_ID_OFFSET + 4;
const LOG_META_MTU_LENGTH_OFFSET: usize = LOG_META_DEFAULT_FRAME_HEADER_LENGTH_OFFSET + 4;
const LOG_META_TERM_LENGTH_OFFSET: usize = LOG_META_MTU_LENGTH_OFFSET + 4;
const LOG_META_PAGE_SIZE_OFFSET: usize = LOG_META_TERM_LENGTH_OFFSET + 4;
const LOG_META_DEFAULT_FRAME_HEADER_OFFSET: usize = LOG_META_PADDING_SIZE * 5;

pub const PublicationEntry = struct {
    registration_id: i64,
    session_id: i32,
    stream_id: i32,
    channel: []u8,
    log_file_name: []u8,
    ref_count: i32,
    channel_status_indicator_counter_id: i32,
    log_buffer: ?*logbuffer.LogBuffer = null,
    network_pub: ?*sender_mod.NetworkPublication = null,
};

pub const SubscriptionEntry = struct {
    registration_id: i64,
    stream_id: i32,
    channel: []u8,
    channel_status_indicator_counter_id: i32,
};

/// Tracks per-client liveness for timeout eviction.
pub const ClientEntry = struct {
    client_id: i64,
    last_keepalive_ms: i64,
};

/// Default client liveness timeout: 5 seconds (matches upstream Aeron defaults).
pub const CLIENT_LIVENESS_TIMEOUT_MS: i64 = 5_000;

pub const DriverConductor = struct {
    ring_buffer: *ManyToOneRingBuffer,
    broadcaster: *BroadcastTransmitter,
    counters_map: *CountersMap,
    receiver: *Receiver,
    sender: *sender_mod.Sender,
    allocator: std.mem.Allocator,
    publications: std.ArrayList(PublicationEntry),
    subscriptions: std.ArrayList(SubscriptionEntry),
    clients: std.ArrayList(ClientEntry),
    next_session_id: i32,
    recv_endpoint: *endpoint_mod.ReceiveChannelEndpoint,
    recv_bound: bool,
    current_time_ms: i64,
    aeron_dir: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        ring_buffer_ptr: *ManyToOneRingBuffer,
        broadcaster_ptr: *BroadcastTransmitter,
        counters_map_ptr: *CountersMap,
        receiver_ptr: *Receiver,
        sender_ptr: *sender_mod.Sender,
        recv_ep: *endpoint_mod.ReceiveChannelEndpoint,
        recv_bound: bool,
        aeron_dir: []const u8,
    ) !DriverConductor {
        return DriverConductor{
            .ring_buffer = ring_buffer_ptr,
            .broadcaster = broadcaster_ptr,
            .counters_map = counters_map_ptr,
            .receiver = receiver_ptr,
            .sender = sender_ptr,
            .recv_endpoint = recv_ep,
            .recv_bound = recv_bound,
            .allocator = allocator,
            .publications = .{},
            .subscriptions = .{},
            .clients = .{},
            .next_session_id = 1,
            .current_time_ms = 0,
            .aeron_dir = aeron_dir,
        };
    }

    pub fn deinit(self: *DriverConductor) void {
        for (self.publications.items) |pub_entry| {
            if (pub_entry.network_pub) |np| {
                self.counters_map.free(np.sender_position.counter_id);
                self.counters_map.free(np.publisher_limit.counter_id);
                self.allocator.destroy(np);
            }
            if (pub_entry.channel_status_indicator_counter_id != counters.NULL_COUNTER_ID) {
                self.counters_map.free(pub_entry.channel_status_indicator_counter_id);
            }
            if (pub_entry.log_buffer) |lb| {
                lb.deinit();
                self.allocator.destroy(lb);
            }
            self.allocator.free(pub_entry.channel);
            self.allocator.free(pub_entry.log_file_name);
        }
        self.publications.deinit(self.allocator);

        for (self.subscriptions.items) |sub_entry| {
            if (sub_entry.channel_status_indicator_counter_id != counters.NULL_COUNTER_ID) {
                self.counters_map.free(sub_entry.channel_status_indicator_counter_id);
            }
            self.allocator.free(sub_entry.channel);
        }
        self.subscriptions.deinit(self.allocator);
        self.clients.deinit(self.allocator);
    }

    /// Advance the logical clock used for liveness checks. Call from the driver duty cycle.
    pub fn setCurrentTimeMs(self: *DriverConductor, now_ms: i64) void {
        self.current_time_ms = now_ms;
    }

    /// Evict clients that have not sent a keepalive within CLIENT_LIVENESS_TIMEOUT_MS.
    /// In upstream Aeron this triggers publication/subscription cleanup for the dead client.
    /// Here we remove the client entry; full resource teardown is left to explicit REMOVE commands.
    pub fn checkClientLiveness(self: *DriverConductor) void {
        const deadline = self.current_time_ms - CLIENT_LIVENESS_TIMEOUT_MS;
        var i: usize = 0;
        while (i < self.clients.items.len) {
            if (self.clients.items[i].last_keepalive_ms < deadline) {
                if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] Evicting timed-out client_id={d}\n", .{self.clients.items[i].client_id});
                _ = self.clients.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn doWork(self: *DriverConductor) i32 {
        // LESSON(conductor): Command dispatch via ring buffer polling + SETUP signal processing in one work cycle. See docs/tutorial/03-driver/03-conductor.md
        var work: i32 = 0;
        work += self.ring_buffer.read(handleMessage, @ptrCast(self), 10);

        // Check client liveness and evict timed-out clients
        self.checkClientLiveness();

        // Drain receiver SETUP signals
        const setups = self.receiver.drainPendingSetups();
        defer self.allocator.free(setups);

        if (setups.len > 0) {
            if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] Processing {d} setups\n", .{setups.len});
        }

        for (setups) |sig| {
            // LESSON(conductor): On SETUP signal, create Image with log buffer + counters, attach to Receiver. See docs/tutorial/03-driver/03-conductor.md
            // Find matching subscription
            var found = false;
            for (self.subscriptions.items) |sub| {
                if (sub.stream_id == sig.stream_id) {
                    if (self.receiver.hasImage(sig.session_id, sig.stream_id)) {
                        if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] Image already exists for session {d} stream {d}, skipping duplicate SETUP\n", .{ sig.session_id, sig.stream_id });
                        found = true;
                        break;
                    }
                    if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] Found subscription for stream {d}, creating image...\n", .{sig.stream_id});
                    found = true;
                    const image_log_file_name = if (self.aeron_dir.len != 0)
                        std.fmt.allocPrint(
                            self.allocator,
                            "{s}/image-{d}-{d}-{d}-{d}.logbuffer",
                            .{ self.aeron_dir, sub.registration_id, sig.session_id, sig.stream_id, sig.initial_term_id },
                        ) catch continue
                    else
                        std.fmt.allocPrint(
                            self.allocator,
                            "/tmp/embedded-image-{d}-{d}-{d}.logbuffer",
                            .{ sig.session_id, sig.stream_id, sig.initial_term_id },
                        ) catch continue;
                    defer self.allocator.free(image_log_file_name);

                    // Create Image
                    const lb = self.allocator.create(@import("../logbuffer/log_buffer.zig").LogBuffer) catch continue;
                    lb.* = @import("../logbuffer/log_buffer.zig").LogBuffer.initMapped(self.allocator, sig.term_length, image_log_file_name) catch {
                        self.allocator.destroy(lb);
                        continue;
                    };
                    self.initializePublicationLogMetadata(
                        lb,
                        sub.registration_id,
                        sig.session_id,
                        sig.stream_id,
                        sig.initial_term_id,
                        sig.term_length,
                        sig.mtu,
                    );

                    const hwm_label = std.fmt.allocPrint(self.allocator, "hwm: {d}:{d}", .{ sig.session_id, sig.stream_id }) catch "hwm";
                    defer if (!std.mem.eql(u8, hwm_label, "hwm")) self.allocator.free(hwm_label);
                    const hwm_handle = self.counters_map.allocateStreamCounter(
                        counters.RECEIVER_HWM,
                        "rcv-hwm",
                        0,
                        sub.registration_id,
                        sig.session_id,
                        sig.stream_id,
                        sub.channel,
                        null,
                    );

                    const sub_pos_label = std.fmt.allocPrint(self.allocator, "sub-pos: {d}:{d}", .{ sig.session_id, sig.stream_id }) catch "sub-pos";
                    defer if (!std.mem.eql(u8, sub_pos_label, "sub-pos")) self.allocator.free(sub_pos_label);
                    const sub_pos_handle = self.counters_map.allocateStreamCounter(
                        counters.SUBSCRIBER_POSITION,
                        "sub-pos",
                        0,
                        sub.registration_id,
                        sig.session_id,
                        sig.stream_id,
                        sub.channel,
                        0,
                    );
                    self.counters_map.set(sub_pos_handle.counter_id, 0);

                    const image = self.allocator.create(Image) catch continue;
                    image.* = Image.init(
                        sig.session_id,
                        sig.stream_id,
                        sig.term_length,
                        sig.mtu,
                        sig.initial_term_id,
                        sig.active_term_id,
                        lb,
                        hwm_handle,
                        sub_pos_handle,
                        sig.source_address,
                    );
                    self.receiver.onAddSubscription(image) catch continue;
                    self.sender.onStatusMessage(
                        sig.session_id,
                        sig.stream_id,
                        sig.initial_term_id,
                        0,
                        @as(i32, @divTrunc(sig.term_length, 4)),
                    );
                    self.receiver.sendStatus(image) catch {};

                    // Send ON_IMAGE_READY to clients
                    self.sendImageReady(
                        sub.registration_id,
                        sig.session_id,
                        sig.stream_id,
                        sub.registration_id,
                        sub_pos_handle.counter_id,
                        image_log_file_name,
                    );
                    work += 1;
                    break;
                }
            }
            if (!found) {
                if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] No subscription found for stream {d} (active subs: {d})\n", .{ sig.stream_id, self.subscriptions.items.len });
            }
        }

        const status_messages = self.receiver.drainPendingStatusMessages();
        defer if (status_messages.len > 0) self.allocator.free(status_messages);
        for (status_messages) |status| {
            self.sender.onStatusMessage(
                status.session_id,
                status.stream_id,
                status.consumption_term_id,
                status.consumption_term_offset,
                status.receiver_window,
            );
            work += 1;
        }

        return work;
    }

    fn sendImageClose(self: *DriverConductor, session_id: i32, stream_id: i32, registration_id: i64) void {
        var buf: [20]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], registration_id, .little);
        std.mem.writeInt(i32, buf[8..12], session_id, .little);
        std.mem.writeInt(i32, buf[12..16], stream_id, .little);
        std.mem.writeInt(i32, buf[16..20], 0, .little); // reserved
        self.broadcaster.transmit(RESPONSE_ON_IMAGE_CLOSE, &buf) catch return;
    }

    fn sendImageReady(
        self: *DriverConductor,
        correlation_id: i64,
        session_id: i32,
        stream_id: i32,
        subscription_registration_id: i64,
        subscriber_position_id: i32,
        log_file_name: []const u8,
    ) void {
        const source_identity = "";
        const aligned_log_name_len = std.mem.alignForward(usize, log_file_name.len, @sizeOf(i32));
        const source_identity_offset = 32 + aligned_log_name_len;
        const payload_len = source_identity_offset + 4 + source_identity.len;
        const payload = self.allocator.alloc(u8, payload_len) catch return;
        defer self.allocator.free(payload);

        @memset(payload, 0);
        std.mem.writeInt(i64, payload[0..8], correlation_id, .little);
        std.mem.writeInt(i32, payload[8..12], session_id, .little);
        std.mem.writeInt(i32, payload[12..16], stream_id, .little);
        std.mem.writeInt(i64, payload[16..24], subscription_registration_id, .little);
        std.mem.writeInt(i32, payload[24..28], subscriber_position_id, .little);
        std.mem.writeInt(i32, payload[28..32], @as(i32, @intCast(log_file_name.len)), .little);
        @memcpy(payload[32 .. 32 + log_file_name.len], log_file_name);
        std.mem.writeInt(i32, payload[source_identity_offset..][0..4], @as(i32, @intCast(source_identity.len)), .little);

        self.broadcaster.transmit(RESPONSE_ON_IMAGE_READY, payload) catch return;
    }

    fn initializePublicationLogMetadata(
        self: *DriverConductor,
        lb: *logbuffer.LogBuffer,
        registration_id: i64,
        session_id: i32,
        stream_id: i32,
        initial_term_id: i32,
        term_length: i32,
        mtu: i32,
    ) void {
        _ = self;
        var meta = lb.metaData();
        meta.setActiveTermCount(0);
        meta.setRawTailVolatile(0, (@as(i64, initial_term_id) << 32));
        meta.setIsConnected(false);
        meta.setActiveTransportCount(0);

        std.mem.writeInt(i64, meta.buffer[LOG_META_CORRELATION_ID_OFFSET .. LOG_META_CORRELATION_ID_OFFSET + 8], registration_id, .little);
        std.mem.writeInt(i32, meta.buffer[LOG_META_INITIAL_TERM_ID_OFFSET .. LOG_META_INITIAL_TERM_ID_OFFSET + 4], initial_term_id, .little);
        std.mem.writeInt(i32, meta.buffer[LOG_META_DEFAULT_FRAME_HEADER_LENGTH_OFFSET .. LOG_META_DEFAULT_FRAME_HEADER_LENGTH_OFFSET + 4], frame.DataHeader.LENGTH, .little);
        std.mem.writeInt(i32, meta.buffer[LOG_META_MTU_LENGTH_OFFSET .. LOG_META_MTU_LENGTH_OFFSET + 4], mtu, .little);
        std.mem.writeInt(i32, meta.buffer[LOG_META_TERM_LENGTH_OFFSET .. LOG_META_TERM_LENGTH_OFFSET + 4], term_length, .little);
        std.mem.writeInt(i32, meta.buffer[LOG_META_PAGE_SIZE_OFFSET .. LOG_META_PAGE_SIZE_OFFSET + 4], 4096, .little);

        var default_header: frame.DataHeader = undefined;
        default_header.frame_length = 0;
        default_header.version = frame.VERSION;
        default_header.flags = frame.DataHeader.BEGIN_FLAG | frame.DataHeader.END_FLAG;
        default_header.type = @intFromEnum(frame.FrameType.data);
        default_header.term_offset = 0;
        default_header.session_id = session_id;
        default_header.stream_id = stream_id;
        default_header.term_id = initial_term_id;
        default_header.reserved_value = 0;
        @memcpy(meta.buffer[LOG_META_DEFAULT_FRAME_HEADER_OFFSET .. LOG_META_DEFAULT_FRAME_HEADER_OFFSET + frame.DataHeader.LENGTH], std.mem.asBytes(&default_header));

        if (lb.mapped_buffer) |mapped| {
            std.posix.msync(mapped, std.posix.MSF.SYNC) catch |err| {
                std.log.warn("publication logbuffer msync failed registration_id={} err={}", .{ registration_id, err });
            };
        }
    }

    pub fn handleAddPublication(self: *DriverConductor, data: []const u8) void {
        // LESSON(conductor): Publication lifecycle—allocate session ID, create log buffer + counters, register with Sender. See docs/tutorial/03-driver/03-conductor.md
        if (data.len < PUBLICATION_COMMAND_CHANNEL_OFFSET) return;

        const correlation_id = std.mem.readInt(i64, data[8..16], .little);
        const stream_id = std.mem.readInt(i32, data[PUBLICATION_COMMAND_STREAM_ID_OFFSET .. PUBLICATION_COMMAND_STREAM_ID_OFFSET + 4], .little);
        const channel_len = std.mem.readInt(i32, data[PUBLICATION_COMMAND_CHANNEL_LENGTH_OFFSET .. PUBLICATION_COMMAND_CHANNEL_LENGTH_OFFSET + 4], .little);

        if (channel_len < 0 or data.len < PUBLICATION_COMMAND_CHANNEL_OFFSET + @as(usize, @intCast(channel_len))) {
            self.sendError(correlation_id, 1, "Invalid ADD_PUBLICATION message");
            return;
        }

        const channel_data = data[PUBLICATION_COMMAND_CHANNEL_OFFSET .. PUBLICATION_COMMAND_CHANNEL_OFFSET + @as(usize, @intCast(channel_len))];

        // Check if publication already exists for this channel+stream_id
        for (self.publications.items) |*pub_entry| {
            if (pub_entry.stream_id == stream_id and std.mem.eql(u8, pub_entry.channel, channel_data)) {
                // Duplicate add: increment ref_count and send ON_PUBLICATION_READY with existing entry details
                pub_entry.ref_count += 1;
                if (pub_entry.network_pub) |np| {
                    self.sendPublicationReady(
                        correlation_id,
                        pub_entry.registration_id,
                        pub_entry.session_id,
                        pub_entry.stream_id,
                        np.publisher_limit.counter_id,
                        pub_entry.channel_status_indicator_counter_id,
                        pub_entry.log_file_name,
                    );
                }
                return;
            }
        }

        const session_id = self.next_session_id;
        self.next_session_id +%= 1;

        const channel_copy = self.allocator.dupe(u8, channel_data) catch {
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        // Parse channel URI to get dest address
        var udp_ch = transport_uri.UdpChannel.parse(self.allocator, channel_data) catch null;
        defer if (udp_ch) |*ch| ch.deinit(self.allocator);

        const dest_address = if (udp_ch) |ch| ch.endpoint orelse std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40124) else std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40124);

        const log_file_name = if (self.aeron_dir.len != 0)
            std.fmt.allocPrint(
                self.allocator,
                "{s}/publication-{d}-{d}-{d}.logbuffer",
                .{ self.aeron_dir, correlation_id, session_id, stream_id },
            ) catch {
                self.allocator.free(channel_copy);
                self.sendError(correlation_id, 2, "Out of memory");
                return;
            }
        else
            std.fmt.allocPrint(self.allocator, "/tmp/embedded-publication-{d}.logbuffer", .{correlation_id}) catch {
                self.allocator.free(channel_copy);
                self.sendError(correlation_id, 2, "Out of memory");
                return;
            };

        // Create log buffer (64KB term for interop test)
        const term_len: i32 = 64 * 1024;
        const lb = self.allocator.create(logbuffer.LogBuffer) catch {
            self.allocator.free(channel_copy);
            self.allocator.free(log_file_name);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };
        lb.* = logbuffer.LogBuffer.initMapped(self.allocator, term_len, log_file_name) catch {
            self.allocator.destroy(lb);
            self.allocator.free(channel_copy);
            self.allocator.free(log_file_name);
            self.sendError(correlation_id, 2, "LogBuffer init failed");
            return;
        };
        self.initializePublicationLogMetadata(lb, correlation_id, session_id, stream_id, 0, term_len, 1408);

        // Allocate counters
        const sp_label = std.fmt.allocPrint(self.allocator, "sender-pos: {d}:{d}", .{ session_id, stream_id }) catch "sender-pos";
        defer if (!std.mem.eql(u8, sp_label, "sender-pos")) self.allocator.free(sp_label);
        const pl_label = std.fmt.allocPrint(self.allocator, "pub-limit: {d}:{d}", .{ session_id, stream_id }) catch "pub-limit";
        defer if (!std.mem.eql(u8, pl_label, "pub-limit")) self.allocator.free(pl_label);
        const sender_pos_handle = self.counters_map.allocateStreamCounter(
            counters.SENDER_POSITION,
            "snd-pos",
            0,
            correlation_id,
            session_id,
            stream_id,
            channel_data,
            null,
        );
        const pub_limit_handle = self.counters_map.allocateStreamCounter(
            counters.PUBLISHER_LIMIT,
            "pub-lmt",
            0,
            correlation_id,
            session_id,
            stream_id,
            channel_data,
            null,
        );
        const channel_status_handle = self.counters_map.allocateChannelStatusCounter(
            counters.SEND_CHANNEL_STATUS,
            "snd-channel",
            correlation_id,
            channel_data,
        );
        self.counters_map.set(pub_limit_handle.counter_id, 0);
        self.counters_map.set(channel_status_handle.counter_id, 1);

        // Create NetworkPublication
        const net_pub = self.allocator.create(sender_mod.NetworkPublication) catch {
            lb.deinit();
            self.allocator.destroy(lb);
            self.allocator.free(channel_copy);
            self.allocator.free(log_file_name);
            self.counters_map.free(sender_pos_handle.counter_id);
            self.counters_map.free(pub_limit_handle.counter_id);
            self.counters_map.free(channel_status_handle.counter_id);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };
        net_pub.* = sender_mod.NetworkPublication{
            .session_id = session_id,
            .stream_id = stream_id,
            .initial_term_id = 0,
            .log_buffer = lb,
            .sender_position = sender_pos_handle,
            .publisher_limit = pub_limit_handle,
            .send_channel = self.sender.send_endpoint,
            .dest_address = dest_address,
            .mtu = 1408,
            .last_setup_time_ms = 0,
            .last_heartbeat_time_ms = 0,
        };
        self.sender.onAddPublication(net_pub) catch {
            self.allocator.destroy(net_pub);
            lb.deinit();
            self.allocator.destroy(lb);
            self.allocator.free(channel_copy);
            self.allocator.free(log_file_name);
            self.counters_map.free(sender_pos_handle.counter_id);
            self.counters_map.free(pub_limit_handle.counter_id);
            self.counters_map.free(channel_status_handle.counter_id);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        const entry = PublicationEntry{
            .registration_id = correlation_id,
            .session_id = session_id,
            .stream_id = stream_id,
            .channel = channel_copy,
            .log_file_name = log_file_name,
            .ref_count = 1,
            .channel_status_indicator_counter_id = channel_status_handle.counter_id,
            .log_buffer = lb,
            .network_pub = net_pub,
        };

        self.publications.append(self.allocator, entry) catch {
            self.sender.onRemovePublication(session_id, stream_id);
            self.allocator.destroy(net_pub);
            lb.deinit();
            self.allocator.destroy(lb);
            self.allocator.free(channel_copy);
            self.allocator.free(log_file_name);
            self.counters_map.free(sender_pos_handle.counter_id);
            self.counters_map.free(pub_limit_handle.counter_id);
            self.counters_map.free(channel_status_handle.counter_id);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        self.sendPublicationReady(
            correlation_id,
            correlation_id,
            session_id,
            stream_id,
            pub_limit_handle.counter_id,
            channel_status_handle.counter_id,
            log_file_name,
        );
    }

    pub fn handleAddExclusivePublication(self: *DriverConductor, data: []const u8) void {
        // Exclusive publications use the same command layout as regular publications.
        // The difference is they are never merged with existing publications for the
        // same channel+stream. Since we don't implement publication merging yet,
        // the behavior is identical.
        self.handleAddPublication(data);
    }

    pub fn handleRemovePublication(self: *DriverConductor, data: []const u8) void {
        if (data.len < REMOVE_COMMAND_LENGTH) return;

        const correlation_id = std.mem.readInt(i64, data[8..16], .little);
        const registration_id = std.mem.readInt(i64, data[REMOVE_COMMAND_REGISTRATION_ID_OFFSET .. REMOVE_COMMAND_REGISTRATION_ID_OFFSET + 8], .little);

        var found_index: ?usize = null;
        for (self.publications.items, 0..) |pub_entry, i| {
            if (pub_entry.registration_id == registration_id) {
                found_index = i;
                break;
            }
        }

        if (found_index) |idx| {
            // Decrement ref_count first
            self.publications.items[idx].ref_count -= 1;

            // Only free resources when ref_count reaches 0
            if (self.publications.items[idx].ref_count <= 0) {
                const removed = self.publications.swapRemove(idx);
                if (removed.network_pub) |np| {
                    self.counters_map.free(np.sender_position.counter_id);
                    self.counters_map.free(np.publisher_limit.counter_id);
                    self.sender.onRemovePublication(removed.session_id, removed.stream_id);
                    self.allocator.destroy(np);
                }
                if (removed.channel_status_indicator_counter_id != counters.NULL_COUNTER_ID) {
                    self.counters_map.free(removed.channel_status_indicator_counter_id);
                }
                if (removed.log_buffer) |lb| {
                    lb.deinit();
                    self.allocator.destroy(lb);
                }
                self.allocator.free(removed.channel);
                self.allocator.free(removed.log_file_name);
            }
            self.sendOperationSuccess(correlation_id);
        }
    }

    pub fn handleAddSubscription(self: *DriverConductor, data: []const u8) void {
        // LESSON(conductor): Subscription lifecycle—store channel + stream_id, wait for publisher SETUP to create Image. See docs/tutorial/03-driver/03-conductor.md
        if (data.len < SUBSCRIPTION_COMMAND_CHANNEL_OFFSET) return;

        const correlation_id = std.mem.readInt(i64, data[8..16], .little);
        const registration_id = std.mem.readInt(i64, data[SUBSCRIPTION_COMMAND_REGISTRATION_CORRELATION_ID_OFFSET .. SUBSCRIPTION_COMMAND_REGISTRATION_CORRELATION_ID_OFFSET + 8], .little);
        const stream_id = std.mem.readInt(i32, data[SUBSCRIPTION_COMMAND_STREAM_ID_OFFSET .. SUBSCRIPTION_COMMAND_STREAM_ID_OFFSET + 4], .little);
        const channel_len = std.mem.readInt(i32, data[SUBSCRIPTION_COMMAND_CHANNEL_LENGTH_OFFSET .. SUBSCRIPTION_COMMAND_CHANNEL_LENGTH_OFFSET + 4], .little);

        if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] ADD_SUBSCRIPTION: correlation={d} registration={d} stream={d} channel_len={d}\n", .{ correlation_id, registration_id, stream_id, channel_len });

        if (channel_len < 0 or data.len < SUBSCRIPTION_COMMAND_CHANNEL_OFFSET + @as(usize, @intCast(channel_len))) {
            self.sendError(correlation_id, 1, "Invalid ADD_SUBSCRIPTION message");
            return;
        }

        const channel_data = data[SUBSCRIPTION_COMMAND_CHANNEL_OFFSET .. SUBSCRIPTION_COMMAND_CHANNEL_OFFSET + @as(usize, @intCast(channel_len))];

        // Bind recv endpoint to channel port on first subscription (if not already bound)
        if (!self.recv_bound) {
            var udp_ch = transport_uri.UdpChannel.parse(self.allocator, channel_data) catch null;
            defer if (udp_ch) |*ch| ch.deinit(self.allocator);
            if (udp_ch) |ch| {
                if (ch.endpoint) |ep| {
                    const port = ep.getPort();
                    if (port != 0) {
                        const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
                        std.posix.bind(self.recv_endpoint.socket, &bind_addr.any, bind_addr.getOsSockLen()) catch {};
                        self.recv_bound = true;
                    }
                }
            }
        }

        const channel_copy = self.allocator.dupe(u8, channel_data) catch {
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        const channel_status_handle = self.counters_map.allocateChannelStatusCounter(
            counters.RECEIVE_CHANNEL_STATUS,
            "rcv-channel",
            correlation_id,
            channel_data,
        );
        if (channel_status_handle.counter_id == counters.NULL_COUNTER_ID) {
            self.allocator.free(channel_copy);
            self.sendError(correlation_id, 3, "Failed to allocate receive channel status");
            return;
        }
        self.counters_map.set(channel_status_handle.counter_id, 1);

        const entry = SubscriptionEntry{
            .registration_id = correlation_id,
            .stream_id = stream_id,
            .channel = channel_copy,
            .channel_status_indicator_counter_id = channel_status_handle.counter_id,
        };

        self.subscriptions.append(self.allocator, entry) catch {
            self.counters_map.free(channel_status_handle.counter_id);
            self.allocator.free(channel_copy);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        self.sendSubscriptionReady(correlation_id, channel_status_handle.counter_id);
    }

    pub fn handleRemoveSubscription(self: *DriverConductor, data: []const u8) void {
        if (data.len < REMOVE_COMMAND_LENGTH) return;

        const correlation_id = std.mem.readInt(i64, data[8..16], .little);
        const registration_id = std.mem.readInt(i64, data[REMOVE_COMMAND_REGISTRATION_ID_OFFSET .. REMOVE_COMMAND_REGISTRATION_ID_OFFSET + 8], .little);

        var found_index: ?usize = null;
        for (self.subscriptions.items, 0..) |sub_entry, i| {
            if (sub_entry.registration_id == registration_id) {
                found_index = i;
                break;
            }
        }

        if (found_index) |idx| {
            const removed = self.subscriptions.swapRemove(idx);
            // Also remove any Images on the receiver that were created for this subscription.
            // Images are keyed by stream_id; walk the receiver and remove matching images.
            // This mirrors upstream DriverConductor.removeSubscription -> ReceiverProxy.removeSubscription.
            // We hold no receiver mutex here since this runs on the conductor thread (same thread as
            // the receiver duty cycle when single-threaded). In a multi-threaded driver the receiver
            // would be signalled via an inter-agent command queue instead.
            self.receiver.mutex.lock();
            var j: usize = 0;
            while (j < self.receiver.images.items.len) {
                const image = self.receiver.images.items[j];
                if (image.stream_id == removed.stream_id) {
                    self.receiver.mutex.unlock();
                    // Notify clients that the image has closed
                    self.sendImageClose(image.session_id, image.stream_id, registration_id);
                    self.receiver.mutex.lock();
                    // Free image counters to prevent leaks
                    self.counters_map.free(image.receiver_hwm.counter_id);
                    self.counters_map.free(image.subscriber_position.counter_id);
                    // Free the image resources; log_buffer was allocated by conductor on SETUP
                    image.deinit();
                    image.log_buffer.deinit();
                    self.allocator.destroy(image.log_buffer);
                    self.allocator.destroy(image);
                    _ = self.receiver.images.swapRemove(j);
                    // don't increment j — swapRemove replaces index j with last element
                } else {
                    j += 1;
                }
            }
            self.receiver.mutex.unlock();
            if (removed.channel_status_indicator_counter_id != counters.NULL_COUNTER_ID) {
                self.counters_map.free(removed.channel_status_indicator_counter_id);
            }
            self.allocator.free(removed.channel);
            self.sendOperationSuccess(correlation_id);
        }
    }

    pub fn handleClientKeepalive(self: *DriverConductor, data: []const u8) void {
        if (data.len < 8) return;
        const client_id = std.mem.readInt(i64, data[0..8], .little);
        // Update or register client liveness timestamp
        for (self.clients.items) |*client| {
            if (client.client_id == client_id) {
                client.last_keepalive_ms = self.current_time_ms;
                return;
            }
        }
        // New client: register with current time
        self.clients.append(self.allocator, .{
            .client_id = client_id,
            .last_keepalive_ms = self.current_time_ms,
        }) catch {};
    }

    pub fn handleAddCounter(self: *DriverConductor, data: []const u8) void {
        // LESSON(conductor): Counter allocation—assign shared-memory slots for sender_position, publisher_limit, receiver_hwm, etc. See docs/tutorial/03-driver/03-conductor.md
        if (data.len < 16) return;

        const correlation_id = std.mem.readInt(i64, data[0..8], .little);
        const type_id = std.mem.readInt(i32, data[8..12], .little);
        const label_len = std.mem.readInt(i32, data[12..16], .little);

        if (label_len < 0 or data.len < 16 + @as(usize, @intCast(label_len))) {
            self.sendError(correlation_id, 1, "Invalid ADD_COUNTER message");
            return;
        }

        const label_data = data[16 .. 16 + @as(usize, @intCast(label_len))];
        const handle = self.counters_map.allocate(type_id, label_data);

        if (handle.counter_id == counters.NULL_COUNTER_ID) {
            self.sendError(correlation_id, 3, "Failed to allocate counter");
            return;
        }

        self.sendCounterReady(correlation_id, handle.counter_id);
    }

    pub fn handleRemoveCounter(self: *DriverConductor, data: []const u8) void {
        if (data.len < 12) return;

        const correlation_id = std.mem.readInt(i64, data[0..8], .little);
        const counter_id = std.mem.readInt(i32, data[8..12], .little);

        self.counters_map.free(counter_id);
        self.sendOperationSuccess(correlation_id);
    }

    pub fn handleTerminateDriver(self: *DriverConductor) void {
        signal.running.store(false, .release);
        if (builtin.mode == .Debug) std.debug.print("[CONDUCTOR] TERMINATE_DRIVER received — initiating graceful shutdown\n", .{});
        _ = self;
    }

    fn sendPublicationReady(
        self: *DriverConductor,
        correlation_id: i64,
        registration_id: i64,
        session_id: i32,
        stream_id: i32,
        pub_limit_counter_id: i32,
        channel_status_indicator_id: i32,
        log_file_name: []const u8,
    ) void {
        // LESSON(conductor): Broadcast response to clients via shared-memory broadcast buffer—clients poll for readiness. See docs/tutorial/03-driver/03-conductor.md
        const payload_len = 36 + log_file_name.len;
        const payload = self.allocator.alloc(u8, payload_len) catch return;
        defer self.allocator.free(payload);

        std.mem.writeInt(i64, payload[0..8], correlation_id, .little);
        std.mem.writeInt(i64, payload[8..16], registration_id, .little);
        std.mem.writeInt(i32, payload[16..20], session_id, .little);
        std.mem.writeInt(i32, payload[20..24], stream_id, .little);
        std.mem.writeInt(i32, payload[24..28], pub_limit_counter_id, .little);
        std.mem.writeInt(i32, payload[28..32], channel_status_indicator_id, .little);
        std.mem.writeInt(i32, payload[32..36], @as(i32, @intCast(log_file_name.len)), .little);
        @memcpy(payload[36..], log_file_name);
        self.broadcaster.transmit(RESPONSE_ON_PUBLICATION_READY, payload) catch return;
    }

    fn sendSubscriptionReady(self: *DriverConductor, correlation_id: i64, channel_status_indicator_id: i32) void {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], channel_status_indicator_id, .little);
        self.broadcaster.transmit(RESPONSE_ON_SUBSCRIPTION_READY, &buf) catch return;
    }

    fn sendError(self: *DriverConductor, correlation_id: i64, error_code: i32, msg: []const u8) void {
        const total_len = 16 + msg.len;
        const buf = self.allocator.alloc(u8, total_len) catch return;
        defer self.allocator.free(buf);
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], error_code, .little);
        std.mem.writeInt(i32, buf[12..16], @as(i32, @intCast(msg.len)), .little);
        if (msg.len > 0) {
            @memcpy(buf[16..], msg);
        }
        self.broadcaster.transmit(RESPONSE_ON_ERROR, buf) catch return;
    }

    fn sendCounterReady(self: *DriverConductor, correlation_id: i64, counter_id: i32) void {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], counter_id, .little);
        self.broadcaster.transmit(RESPONSE_ON_COUNTER_READY, &buf) catch return;
    }

    fn sendOperationSuccess(self: *DriverConductor, correlation_id: i64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        self.broadcaster.transmit(RESPONSE_ON_OPERATION_SUCCESS, &buf) catch return;
    }
};

fn handleMessage(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
    const self: *DriverConductor = @ptrCast(@alignCast(ctx));
    switch (msg_type_id) {
        CMD_ADD_PUBLICATION => self.handleAddPublication(data),
        CMD_REMOVE_PUBLICATION => self.handleRemovePublication(data),
        CMD_ADD_EXCLUSIVE_PUBLICATION => self.handleAddExclusivePublication(data),
        CMD_ADD_SUBSCRIPTION => self.handleAddSubscription(data),
        CMD_REMOVE_SUBSCRIPTION => self.handleRemoveSubscription(data),
        CMD_CLIENT_KEEPALIVE => self.handleClientKeepalive(data),
        CMD_ADD_COUNTER => self.handleAddCounter(data),
        CMD_REMOVE_COUNTER => self.handleRemoveCounter(data),
        CMD_TERMINATE_DRIVER => self.handleTerminateDriver(),
        else => {},
    }
}

const testing = std.testing;

test "DriverConductor init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    var meta_buf = [_]u8{0} ** 4096;
    var values_buf = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    const dummy_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(dummy_socket);
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{
        .socket = dummy_socket,
    };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();

    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp");
    defer conductor.deinit();

    try testing.expectEqual(@as(i32, 1), conductor.next_session_id);
    try testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
    try testing.expectEqual(@as(usize, 0), conductor.subscriptions.items.len);
}

test "DriverConductor ADD_PUBLICATION creates entry and sends ready response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    const dummy_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(dummy_socket);
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{
        .socket = dummy_socket,
    };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();

    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp");
    defer conductor.deinit();

    // Simulate ADD_PUBLICATION command
    var cmd_buf: [64]u8 = undefined;
    @memset(&cmd_buf, 0);
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 77, .little); // client_id
    std.mem.writeInt(i64, cmd_buf[8..16], 12345, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[16..20], 42, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);

    // Directly call handler
    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try testing.expectEqual(@as(i32, 42), conductor.publications.items[0].stream_id);
    try testing.expectEqual(@as(i64, 12345), conductor.publications.items[0].registration_id);
    try testing.expectEqualStrings(channel, conductor.publications.items[0].channel);
    try testing.expect(conductor.publications.items[0].log_file_name.len > 0);

    var rx = try broadcast.BroadcastReceiver.init(allocator, &bcast);
    try testing.expect(rx.receiveNext());
    try testing.expectEqual(RESPONSE_ON_PUBLICATION_READY, rx.typeId());
    const payload = rx.buffer();
    const log_name_len = std.mem.readInt(i32, payload[32..36], .little);
    try testing.expectEqual(@as(i64, 12345), std.mem.readInt(i64, payload[0..8], .little));
    try testing.expectEqual(@as(i64, 12345), std.mem.readInt(i64, payload[8..16], .little));
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, payload[16..20], .little));
    try testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, payload[20..24], .little));
    try testing.expect(log_name_len > 0);
    try testing.expectEqualStrings(
        conductor.publications.items[0].log_file_name,
        payload[36 .. 36 + @as(usize, @intCast(log_name_len))],
    );
}

test "DriverConductor ADD_SUBSCRIPTION creates entry and sends ready response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{
        .socket = dummy_socket,
    };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();

    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp");
    defer conductor.deinit();

    // Skip socket binding for dummy socket in tests
    conductor.recv_bound = true;

    // Simulate ADD_SUBSCRIPTION command
    var cmd_buf: [80]u8 = undefined;
    @memset(&cmd_buf, 0);
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 88, .little); // client_id
    std.mem.writeInt(i64, cmd_buf[8..16], 54321, .little); // correlation_id
    std.mem.writeInt(i64, cmd_buf[16..24], -1, .little); // registration correlation id
    std.mem.writeInt(i32, cmd_buf[24..28], 99, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[28..32], @as(i32, @intCast(channel.len)), .little); // channel_len
    @memcpy(cmd_buf[32 .. 32 + channel.len], channel);

    // Directly call handler
    conductor.handleAddSubscription(cmd_buf[0 .. 32 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.subscriptions.items.len);
    try testing.expectEqual(@as(i32, 99), conductor.subscriptions.items[0].stream_id);
    try testing.expectEqual(@as(i64, 54321), conductor.subscriptions.items[0].registration_id);
    try testing.expectEqualStrings(channel, conductor.subscriptions.items[0].channel);
    try testing.expect(conductor.subscriptions.items[0].channel_status_indicator_counter_id != counters.NULL_COUNTER_ID);

    var rx = try broadcast.BroadcastReceiver.init(allocator, &bcast);
    try testing.expect(rx.receiveNext());
    try testing.expectEqual(RESPONSE_ON_SUBSCRIPTION_READY, rx.typeId());
    try testing.expectEqual(@as(i32, 12), rx.length());
    const payload = rx.buffer();
    try testing.expectEqual(@as(i64, 54321), std.mem.readInt(i64, payload[0..8], .little));
    try testing.expectEqual(
        conductor.subscriptions.items[0].channel_status_indicator_counter_id,
        std.mem.readInt(i32, payload[8..12], .little),
    );
}

test "DriverConductor REMOVE_PUBLICATION cleans up entry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{
        .socket = dummy_socket,
    };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();

    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep, false, "/tmp");
    defer conductor.deinit();

    // Add a publication first
    var cmd_buf: [64]u8 = undefined;
    @memset(&cmd_buf, 0);
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 77, .little);
    std.mem.writeInt(i64, cmd_buf[8..16], 11111, .little);
    std.mem.writeInt(i32, cmd_buf[16..20], 42, .little);
    std.mem.writeInt(i32, cmd_buf[20..24], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[24 .. 24 + channel.len], channel);
    conductor.handleAddPublication(cmd_buf[0 .. 24 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.publications.items.len);

    // Remove it
    var remove_buf: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_buf[0..8], 77, .little); // client_id
    std.mem.writeInt(i64, remove_buf[8..16], 22222, .little); // correlation_id for remove
    std.mem.writeInt(i64, remove_buf[16..24], 11111, .little); // registration_id to remove
    conductor.handleRemovePublication(&remove_buf);

    try testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
}

// Helper to build a minimal DriverConductor for tests — reduces boilerplate.
fn makeTestConductor(
    allocator: std.mem.Allocator,
    rb: *ManyToOneRingBuffer,
    bcast: *BroadcastTransmitter,
    cm: *CountersMap,
    receiver: *Receiver,
    sender: *sender_mod.Sender,
    recv_ep: *endpoint_mod.ReceiveChannelEndpoint,
) !DriverConductor {
    const conductor = try DriverConductor.init(allocator, rb, bcast, cm, receiver, sender, recv_ep, true, "/tmp");
    return conductor;
}

test "DriverConductor client keepalive registers and updates client" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);
    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);
    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);
    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();
    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();
    var conductor = try makeTestConductor(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep);
    defer conductor.deinit();

    conductor.setCurrentTimeMs(1000);

    // Send keepalive for client 7
    var ka_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &ka_buf, 7, .little);
    conductor.handleClientKeepalive(&ka_buf);

    try testing.expectEqual(@as(usize, 1), conductor.clients.items.len);
    try testing.expectEqual(@as(i64, 7), conductor.clients.items[0].client_id);
    try testing.expectEqual(@as(i64, 1000), conductor.clients.items[0].last_keepalive_ms);

    // Advance time and send another keepalive — timestamp should update
    conductor.setCurrentTimeMs(2000);
    conductor.handleClientKeepalive(&ka_buf);
    try testing.expectEqual(@as(usize, 1), conductor.clients.items.len);
    try testing.expectEqual(@as(i64, 2000), conductor.clients.items[0].last_keepalive_ms);
}

test "DriverConductor checkClientLiveness evicts stale clients" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);
    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);
    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);
    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();
    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();
    var conductor = try makeTestConductor(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep);
    defer conductor.deinit();

    // Register two clients at time 0
    conductor.setCurrentTimeMs(0);
    var ka1: [8]u8 = undefined;
    var ka2: [8]u8 = undefined;
    std.mem.writeInt(i64, &ka1, 1, .little);
    std.mem.writeInt(i64, &ka2, 2, .little);
    conductor.handleClientKeepalive(&ka1);
    conductor.handleClientKeepalive(&ka2);

    // Advance time — client 1 sends a keepalive, client 2 does not
    conductor.setCurrentTimeMs(3000);
    conductor.handleClientKeepalive(&ka1);

    // Move past timeout for client 2 (last keepalive was at t=0, timeout=5000ms)
    conductor.setCurrentTimeMs(6000);
    conductor.checkClientLiveness();

    // client 2 should be evicted, client 1 should remain
    try testing.expectEqual(@as(usize, 1), conductor.clients.items.len);
    try testing.expectEqual(@as(i64, 1), conductor.clients.items[0].client_id);
}

test "DriverConductor REMOVE_SUBSCRIPTION closes associated image" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);
    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);
    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);
    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();
    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();
    var conductor = try makeTestConductor(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep);
    defer conductor.deinit();

    const stream_id: i32 = 77;
    const reg_id: i64 = 9900;

    // Add a subscription
    conductor.subscriptions.append(allocator, .{
        .registration_id = reg_id,
        .stream_id = stream_id,
        .channel = try allocator.dupe(u8, "aeron:udp"),
        .channel_status_indicator_counter_id = counters.NULL_COUNTER_ID,
    }) catch unreachable;

    // Manually add an Image for that subscription to the receiver
    const lb = try allocator.create(@import("../logbuffer/log_buffer.zig").LogBuffer);
    lb.* = try @import("../logbuffer/log_buffer.zig").LogBuffer.init(allocator, 64 * 1024);
    const hwm_handle = cm.allocate(counters.RECEIVER_HWM, "hwm");
    const sub_pos_handle = cm.allocate(counters.SUBSCRIBER_POSITION, "sub-pos");
    const image = try allocator.create(Image);
    image.* = Image.init(42, stream_id, 64 * 1024, 1408, 0, 0, lb, hwm_handle, sub_pos_handle, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    try receiver.images.append(allocator, image);

    try testing.expectEqual(@as(usize, 1), receiver.images.items.len);

    // Remove the subscription — expect image to be cleaned up
    var remove_buf: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_buf[0..8], 5, .little);
    std.mem.writeInt(i64, remove_buf[8..16], 0, .little);
    std.mem.writeInt(i64, remove_buf[16..24], reg_id, .little);
    conductor.handleRemoveSubscription(&remove_buf);

    try testing.expectEqual(@as(usize, 0), conductor.subscriptions.items.len);
    try testing.expectEqual(@as(usize, 0), receiver.images.items.len);
}

test "DriverConductor REMOVE_SUBSCRIPTION sends ON_OPERATION_SUCCESS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);
    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);
    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);
    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();
    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();
    var conductor = try makeTestConductor(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep);
    defer conductor.deinit();

    const stream_id: i32 = 77;
    const reg_id: i64 = 9900;
    const correlation_id: i64 = 55555;

    // Add a subscription
    conductor.subscriptions.append(allocator, .{
        .registration_id = reg_id,
        .stream_id = stream_id,
        .channel = try allocator.dupe(u8, "aeron:udp"),
        .channel_status_indicator_counter_id = counters.NULL_COUNTER_ID,
    }) catch unreachable;

    // Remove the subscription with correlation_id
    var remove_buf: [24]u8 = undefined;
    std.mem.writeInt(i64, remove_buf[0..8], 5, .little);
    std.mem.writeInt(i64, remove_buf[8..16], correlation_id, .little);
    std.mem.writeInt(i64, remove_buf[16..24], reg_id, .little);
    conductor.handleRemoveSubscription(&remove_buf);

    // Verify the broadcast sent ON_OPERATION_SUCCESS
    var rx = try broadcast.BroadcastReceiver.init(allocator, &bcast);
    try testing.expect(rx.receiveNext());
    try testing.expectEqual(RESPONSE_ON_OPERATION_SUCCESS, rx.typeId());
    try testing.expectEqual(@as(i32, 8), rx.length());

    const payload = rx.buffer();
    try testing.expectEqual(correlation_id, std.mem.readInt(i64, payload[0..8], .little));
}

test "DriverConductor IPC event IDs match upstream control protocol" {
    try testing.expectEqual(@as(i32, 0x01), CMD_ADD_PUBLICATION);
    try testing.expectEqual(@as(i32, 0x02), CMD_REMOVE_PUBLICATION);
    try testing.expectEqual(@as(i32, 0x03), CMD_ADD_EXCLUSIVE_PUBLICATION);
    try testing.expectEqual(@as(i32, 0x04), CMD_ADD_SUBSCRIPTION);
    try testing.expectEqual(@as(i32, 0x05), CMD_REMOVE_SUBSCRIPTION);
    try testing.expectEqual(@as(i32, 0x06), CMD_CLIENT_KEEPALIVE);
    try testing.expectEqual(@as(i32, 0x09), CMD_ADD_COUNTER);
    try testing.expectEqual(@as(i32, 0x0A), CMD_REMOVE_COUNTER);
    try testing.expectEqual(@as(i32, 0x0E), CMD_TERMINATE_DRIVER);

    try testing.expectEqual(@as(i32, 0x0F01), RESPONSE_ON_ERROR);
    try testing.expectEqual(@as(i32, 0x0F02), RESPONSE_ON_IMAGE_READY);
    try testing.expectEqual(@as(i32, 0x0F03), RESPONSE_ON_PUBLICATION_READY);
    try testing.expectEqual(@as(i32, 0x0F04), RESPONSE_ON_OPERATION_SUCCESS);
    try testing.expectEqual(@as(i32, 0x0F05), RESPONSE_ON_IMAGE_CLOSE);
    try testing.expectEqual(@as(i32, 0x0F07), RESPONSE_ON_SUBSCRIPTION_READY);
    try testing.expectEqual(@as(i32, 0x0F08), RESPONSE_ON_COUNTER_READY);
}

test "DriverConductor TERMINATE_DRIVER stops signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);
    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 16384);
    defer bcast.deinit(allocator);
    var meta_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var values_buf: [4096]u8 align(64) = [_]u8{0} ** 4096;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);
    const dummy_socket: std.posix.socket_t = INVALID_SOCKET;
    var recv_ep = @import("../transport/endpoint.zig").ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_ep = @import("../transport/endpoint.zig").SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &cm, null);
    defer receiver.deinit();
    var sender = try sender_mod.Sender.init(allocator, &send_ep, &cm);
    defer sender.deinit();
    var conductor = try makeTestConductor(allocator, &rb, &bcast, &cm, &receiver, &sender, &recv_ep);
    defer conductor.deinit();

    // Verify signal is initially running
    signal.running.store(true, .release);
    try testing.expect(signal.isRunning() == true);

    // Send TERMINATE_DRIVER command
    conductor.handleTerminateDriver();

    // Verify signal is now stopped
    try testing.expect(signal.isRunning() == false);
}
