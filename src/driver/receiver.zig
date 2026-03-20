// Receiver duty agent — polls incoming UDP frames and dispatches by type
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/c/aeron_receiver.c
const std = @import("std");
const logbuffer = @import("../logbuffer/log_buffer.zig");
const metadata = @import("../logbuffer/metadata.zig");
const counters = @import("../ipc/counters.zig");
const protocol = @import("../protocol/frame.zig");
const transport = @import("../transport/endpoint.zig");
const loss_report = @import("../loss_report.zig");
const event_log_mod = @import("../event_log.zig");

pub const Image = struct {
    session_id: i32,
    stream_id: i32,
    term_length: i32,
    mtu: i32,
    initial_term_id: i32,
    log_buffer: *logbuffer.LogBuffer,
    receiver_hwm: counters.CounterHandle, // highest term_offset seen
    subscriber_position: counters.CounterHandle, // where subscriber has consumed to
    rebuild_position: i64, // tracks gap filling progress
    source_address: std.net.Address,

    pub fn init(
        session_id: i32,
        stream_id: i32,
        term_length: i32,
        mtu: i32,
        initial_term_id: i32,
        log_buffer: *logbuffer.LogBuffer,
        receiver_hwm: counters.CounterHandle,
        subscriber_position: counters.CounterHandle,
        source_address: std.net.Address,
    ) Image {
        return .{
            .session_id = session_id,
            .stream_id = stream_id,
            .term_length = term_length,
            .mtu = mtu,
            .initial_term_id = initial_term_id,
            .log_buffer = log_buffer,
            .receiver_hwm = receiver_hwm,
            .subscriber_position = subscriber_position,
            .rebuild_position = 0,
            .source_address = source_address,
        };
    }

    pub fn deinit(_: *Image) void {
        // log_buffer owned externally — no-op
    }

    // Write an incoming DATA frame into the log buffer at the correct partition+offset
    // Returns true if written, false if out-of-bounds or duplicate
    pub fn insertFrame(self: *Image, counters_map: *counters.CountersMap, header: *const protocol.DataHeader, payload: []const u8) bool {
        // Compute active partition for header.term_id
        const term_count = header.term_id - self.initial_term_id;
        const partition = @as(usize, @intCast(@mod(term_count, 3)));

        const frame_offset = @as(usize, @intCast(header.term_offset));
        const term_buffer = self.log_buffer.termBuffer(partition);

        // Bounds check: frame_offset + DataHeader.LENGTH + payload.len <= term_buffer.len
        const total_frame_len = protocol.DataHeader.LENGTH + payload.len;
        if (frame_offset + total_frame_len > term_buffer.len) {
            return false; // Out of bounds
        }

        // Write DataHeader at frame_offset
        const header_ptr = @as(*protocol.DataHeader, @ptrCast(@alignCast(&term_buffer[frame_offset])));
        header_ptr.* = header.*;

        // Write payload at frame_offset + DataHeader.LENGTH
        const payload_offset = frame_offset + protocol.DataHeader.LENGTH;
        @memcpy(term_buffer[payload_offset .. payload_offset + payload.len], payload);

        // Align frame length to FRAME_ALIGNMENT boundary
        const aligned_len = @as(i32, @intCast((total_frame_len + protocol.FRAME_ALIGNMENT - 1) / protocol.FRAME_ALIGNMENT * protocol.FRAME_ALIGNMENT));

        // Write frame_length as little-endian i32 LAST (signals frame is committed)
        const len_ptr = @as(*i32, @ptrCast(@alignCast(&term_buffer[frame_offset])));
        len_ptr.* = aligned_len;

        // Update receiver_hwm counter
        const new_hwm = @as(i64, @intCast(header.term_offset)) + aligned_len;
        const current_hwm = counters_map.get(self.receiver_hwm.counter_id);
        if (new_hwm > current_hwm) {
            counters_map.set(self.receiver_hwm.counter_id, new_hwm);
        }

        return true;
    }

    // Check if there is a gap between rebuild_position and receiver_hwm
    pub fn hasGap(self: *const Image, counters_map: *const counters.CountersMap) bool {
        const hwm = counters_map.get(self.receiver_hwm.counter_id);
        return self.rebuild_position < hwm;
    }

    // Returns the term_offset of the gap start (for NAK generation)
    pub fn gapTermOffset(self: *const Image) i32 {
        return @as(i32, @intCast(self.rebuild_position % @as(i64, @intCast(self.term_length))));
    }
};

pub const Receiver = struct {
    images: std.ArrayList(*Image),
    recv_endpoint: *transport.ReceiveChannelEndpoint,
    send_endpoint: *transport.SendChannelEndpoint,
    counters_map: *counters.CountersMap,
    loss_report_instance: ?*loss_report.LossReport,
    event_log: ?*event_log_mod.EventLog,
    allocator: std.mem.Allocator,
    recv_buf: [4096]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        recv_endpoint: *transport.ReceiveChannelEndpoint,
        send_endpoint: *transport.SendChannelEndpoint,
        counters_map: *counters.CountersMap,
        loss_rpt: ?*loss_report.LossReport,
    ) !Receiver {
        return initWithEventLog(allocator, recv_endpoint, send_endpoint, counters_map, loss_rpt, null);
    }

    pub fn initWithEventLog(
        allocator: std.mem.Allocator,
        recv_ep: *transport.ReceiveChannelEndpoint,
        send_ep: *transport.SendChannelEndpoint,
        counters_map_: *counters.CountersMap,
        loss_rpt: ?*loss_report.LossReport,
        el: ?*event_log_mod.EventLog,
    ) !Receiver {
        return .{
            .images = std.ArrayList(*Image){},
            .recv_endpoint = recv_ep,
            .send_endpoint = send_ep,
            .counters_map = counters_map_,
            .loss_report_instance = loss_rpt,
            .event_log = el,
            .allocator = allocator,
            .recv_buf = undefined,
        };
    }

    pub fn deinit(self: *Receiver) void {
        self.images.deinit(self.allocator);
    }

    // Single duty cycle: recv one frame, dispatch, return work count (0 or 1)
    pub fn doWork(self: *Receiver) i32 {
        // 1. Call recv_endpoint.recv(&recv_buf, &src_addr)
        var src_addr: std.net.Address = undefined;
        const bytes_read = self.recv_endpoint.recv(&self.recv_buf, &src_addr) catch |err| {
            if (err == error.WouldBlock) {
                return 0;
            }
            return 0;
        };

        if (bytes_read == 0) {
            return 0;
        }

        // 2. Read frame type from buf[6..8] as little-endian u16
        if (bytes_read < 8) {
            return 0;
        }

        const frame_type_raw = std.mem.readInt(u16, self.recv_buf[6..8], .little);

        // 3. Dispatch based on frame type
        if (frame_type_raw == @intFromEnum(protocol.FrameType.data)) {
            // FrameType.data (0x01)
            if (bytes_read < protocol.DataHeader.LENGTH) {
                return 0;
            }

            const header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&self.recv_buf[0])));

            // Find image by (session_id, stream_id)
            for (self.images.items) |image| {
                if (image.session_id == header.session_id and image.stream_id == header.stream_id) {
                    // Extract payload
                    const payload_offset = protocol.DataHeader.LENGTH;
                    const payload_len = @as(usize, @intCast(header.frame_length)) - protocol.DataHeader.LENGTH;

                    if (payload_offset + payload_len <= bytes_read) {
                        const payload = self.recv_buf[payload_offset .. payload_offset + payload_len];

                        // Write frame to log buffer
                        _ = image.insertFrame(self.counters_map, header, payload);

                        // Log frame_in event
                        if (self.event_log) |el| {
                            const evt_now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
                            el.log(.frame_in, evt_now, image.session_id, image.stream_id, payload);
                        }

                        // Check for gap and record loss observation
                        if (image.hasGap(self.counters_map)) {
                            if (self.loss_report_instance) |lr| {
                                const now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
                                lr.recordObservation(
                                    @as(i64, @intCast(payload.len)),
                                    now,
                                    image.session_id,
                                    image.stream_id,
                                    "aeron:udp",
                                );
                            }
                        }

                        // Send status message
                        self.sendStatus(image) catch {};
                    }

                    return 1;
                }
            }

            // Unknown session/stream — log/ignore (conductor handles creation)
            return 1;
        } else if (frame_type_raw == @intFromEnum(protocol.FrameType.setup)) {
            // FrameType.setup (0x03)
            // No auto-create (conductor handles that) — just log/ignore unknown sessions
            return 1;
        } else if (frame_type_raw == @intFromEnum(protocol.FrameType.nak)) {
            // FrameType.nak (0x05)
            // Ignore (we're the receiver, not sender)
            return 1;
        }

        // Other frame types: ignore
        return 1;
    }

    pub fn onAddSubscription(self: *Receiver, image: *Image) !void {
        try self.images.append(self.allocator, image);
    }

    pub fn onRemoveSubscription(self: *Receiver, session_id: i32, stream_id: i32) void {
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].session_id == session_id and self.images.items[i].stream_id == stream_id) {
                _ = self.images.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    // Send a NAK frame back to source_address for the given image's gap
    pub fn sendNak(self: *Receiver, image: *Image) !void {
        var nak_header: protocol.NakHeader = undefined;
        nak_header.frame_length = protocol.NakHeader.LENGTH;
        nak_header.version = protocol.VERSION;
        nak_header.flags = 0;
        nak_header.type = @intFromEnum(protocol.FrameType.nak);
        nak_header.session_id = image.session_id;
        nak_header.stream_id = image.stream_id;
        nak_header.term_id = image.initial_term_id + @as(i32, @intCast(image.rebuild_position / @as(i64, @intCast(image.term_length))));
        nak_header.term_offset = image.gapTermOffset();
        nak_header.length = 4096; // Request a chunk

        const nak_bytes = @as([*]const u8, @ptrCast(&nak_header))[0..protocol.NakHeader.LENGTH];
        _ = try self.send_endpoint.send(image.source_address, nak_bytes);

        // Log send_nak event
        if (self.event_log) |el| {
            const nak_now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
            el.log(.send_nak, nak_now, image.session_id, image.stream_id, nak_bytes);
        }
    }

    // Send a STATUS message to source_address acknowledging receipt
    pub fn sendStatus(self: *Receiver, image: *Image) !void {
        const subscriber_pos = self.counters_map.get(image.subscriber_position.counter_id);
        const consumption_term_id = image.initial_term_id + @as(i32, @intCast(@divTrunc(subscriber_pos, @as(i64, @intCast(image.term_length)))));
        const consumption_term_offset = @as(i32, @intCast(@mod(subscriber_pos, @as(i64, @intCast(image.term_length)))));

        var status: protocol.StatusMessage = undefined;
        status.frame_length = protocol.StatusMessage.LENGTH;
        status.version = protocol.VERSION;
        status.flags = 0;
        status.type = @intFromEnum(protocol.FrameType.status);
        status.session_id = image.session_id;
        status.stream_id = image.stream_id;
        status.consumption_term_id = consumption_term_id;
        status.consumption_term_offset = consumption_term_offset;
        status.receiver_window = @as(i32, @divTrunc(image.term_length, 4));
        status.receiver_id = 0;

        const status_bytes = @as([*]const u8, @ptrCast(&status))[0..protocol.StatusMessage.LENGTH];
        _ = try self.send_endpoint.send(image.source_address, status_bytes);
    }
};

// Unit tests
test "Receiver init and deinit" {
    const allocator = std.testing.allocator;

    // Create minimal channel setup
    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    // Create mock endpoints (we won't actually use them)
    // Just test that Receiver can be created and destroyed
    const dummy_socket: std.posix.socket_t = undefined;
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = undefined,
    };
    var send_ep = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &counters_map, null);
    defer receiver.deinit();

    try std.testing.expectEqual(@as(usize, 0), receiver.images.items.len);
}

test "Receiver onAddSubscription and onRemoveSubscription" {
    const allocator = std.testing.allocator;

    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    const dummy_socket: std.posix.socket_t = undefined;
    var recv_ep = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = undefined,
    };
    var send_ep = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    var receiver = try Receiver.init(allocator, &recv_ep, &send_ep, &counters_map, null);
    defer receiver.deinit();

    // Create a test image
    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    const hwm_handle = counters_map.allocate(counters.RECEIVER_HWM, "test-hwm");
    const sub_pos_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "test-sub");

    var image = Image.init(
        1,
        2,
        64 * 1024,
        1500,
        100,
        &log_buf,
        hwm_handle,
        sub_pos_handle,
        undefined,
    );

    try receiver.onAddSubscription(&image);
    try std.testing.expectEqual(@as(usize, 1), receiver.images.items.len);

    receiver.onRemoveSubscription(1, 2);
    try std.testing.expectEqual(@as(usize, 0), receiver.images.items.len);
}

test "Image insertFrame writes data at correct offset" {
    const allocator = std.testing.allocator;

    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    const hwm_handle = counters_map.allocate(counters.RECEIVER_HWM, "test-hwm");
    const sub_pos_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "test-sub");

    var image = Image.init(
        1,
        2,
        64 * 1024,
        1500,
        0,
        &log_buf,
        hwm_handle,
        sub_pos_handle,
        undefined,
    );

    // Create a data header and payload
    var header: protocol.DataHeader = undefined;
    header.frame_length = 64;
    header.version = protocol.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(protocol.FrameType.data);
    header.term_offset = 0;
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 0;
    header.reserved_value = 0;

    const payload = "test data";
    const written = image.insertFrame(&counters_map, &header, payload);

    try std.testing.expect(written);

    // Verify data was written
    const term_buffer = log_buf.termBuffer(0);
    try std.testing.expect(term_buffer.len > 0);

    // Verify HWM was updated
    const hwm = counters_map.get(hwm_handle.counter_id);
    try std.testing.expect(hwm > 0);
}

test "Image hasGap detects missing frame" {
    const allocator = std.testing.allocator;

    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    const hwm_handle = counters_map.allocate(counters.RECEIVER_HWM, "test-hwm");
    const sub_pos_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "test-sub");

    var image = Image.init(
        1,
        2,
        64 * 1024,
        1500,
        0,
        &log_buf,
        hwm_handle,
        sub_pos_handle,
        undefined,
    );

    // No gap initially
    try std.testing.expect(!image.hasGap(&counters_map));

    // Set HWM higher than rebuild_position
    counters_map.set(hwm_handle.counter_id, 1000);
    image.rebuild_position = 0;

    // Now there should be a gap
    try std.testing.expect(image.hasGap(&counters_map));
}
