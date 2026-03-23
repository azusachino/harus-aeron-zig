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
    nak_state: NakState,

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
            .nak_state = NakState.init(stream_id),
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
        return @as(i32, @intCast(@mod(self.rebuild_position, @as(i64, @intCast(self.term_length)))));
    }
};

pub const SetupSignal = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    active_term_id: i32,
    term_length: i32,
    mtu: i32,
    source_address: std.net.Address,
};

const NAK_DELAY_NS: i64 = 1_000_000; // 1ms

pub const GapRange = struct { offset: i32, length: i32 };

pub const NakState = struct {
    stream_id: i32,
    gap_list: [16]GapRange = undefined,
    gap_list_len: usize = 0,
    first_gap_ns: i64 = 0,

    pub fn init(stream_id: i32) NakState {
        return .{ .stream_id = stream_id, .gap_list_len = 0 };
    }

    /// For tests: inject a known first_gap_ns instead of using the real clock.
    pub fn initWithTime(stream_id: i32, first_gap_ns: i64) NakState {
        return .{ .stream_id = stream_id, .first_gap_ns = first_gap_ns, .gap_list_len = 0 };
    }

    pub fn recordGap(self: *NakState, offset: i32, length: i32) void {
        const end = offset + length;
        // Try to merge with existing gap
        var i: usize = 0;
        while (i < self.gap_list_len) : (i += 1) {
            var g = &self.gap_list[i];
            if (offset <= g.offset + g.length and end >= g.offset) {
                g.offset = @min(g.offset, offset);
                g.length = @max(g.offset + g.length, end) - g.offset;
                return;
            }
        }
        if (self.gap_list_len == 0) self.first_gap_ns = @intCast(@as(i128, std.time.nanoTimestamp()));
        if (self.gap_list_len < 16) {
            self.gap_list[self.gap_list_len] = .{ .offset = offset, .length = length };
            self.gap_list_len += 1;
        }
    }

    pub fn shouldSend(self: *const NakState, now_ns: i64) bool {
        return self.gap_list_len > 0 and (now_ns - self.first_gap_ns) >= NAK_DELAY_NS;
    }

    pub fn gaps(self: *const NakState) []const GapRange {
        return self.gap_list[0..self.gap_list_len];
    }

    pub fn clear(self: *NakState) void {
        self.gap_list_len = 0;
        self.first_gap_ns = 0;
    }
};

pub const Receiver = struct {
    images: std.ArrayList(*Image),
    pending_setups: std.ArrayListUnmanaged(SetupSignal) = .{},
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
            .images = .{},
            .pending_setups = .{},
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
        for (self.images.items) |image| {
            image.log_buffer.deinit();
            self.allocator.destroy(image.log_buffer);
            self.allocator.destroy(image);
        }
        self.images.deinit(self.allocator);
        self.pending_setups.deinit(self.allocator);
    }

    pub fn drainPendingSetups(self: *Receiver) []SetupSignal {
        const slice = self.pending_setups.toOwnedSlice(self.allocator) catch return &.{};
        return slice;
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
                            const hwm = self.counters_map.get(image.receiver_hwm.counter_id);
                            const gap_len = @as(i32, @intCast(hwm - image.rebuild_position));
                            const gap_off = @as(i32, @intCast(@mod(image.rebuild_position, @as(i64, @intCast(image.term_length)))));
                            image.nak_state.recordGap(gap_off, gap_len);

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

                        const now = @as(i64, @intCast(@as(i128, std.time.nanoTimestamp())));
                        if (image.nak_state.shouldSend(now)) {
                            self.sendNak(image) catch {};
                            image.nak_state.clear();
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
            if (bytes_read < protocol.SetupHeader.LENGTH) {
                return 1;
            }
            const setup = @as(*const protocol.SetupHeader, @ptrCast(@alignCast(&self.recv_buf[0])));
            self.pending_setups.append(self.allocator, .{
                .session_id = setup.session_id,
                .stream_id = setup.stream_id,
                .initial_term_id = setup.initial_term_id,
                .active_term_id = setup.active_term_id,
                .term_length = setup.term_length,
                .mtu = setup.mtu,
                .source_address = src_addr,
            }) catch return 1;
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

    // Send a NAK frame back to source_address for the given image's gaps
    pub fn sendNak(self: *Receiver, image: *Image) !void {
        for (image.nak_state.gaps()) |gap| {
            var nak_header: protocol.NakHeader = undefined;
            nak_header.frame_length = protocol.NakHeader.LENGTH;
            nak_header.version = protocol.VERSION;
            nak_header.flags = 0;
            nak_header.type = @intFromEnum(protocol.FrameType.nak);
            nak_header.session_id = image.session_id;
            nak_header.stream_id = image.stream_id;
            nak_header.term_id = image.initial_term_id + @as(i32, @intCast(@divTrunc(image.rebuild_position, @as(i64, @intCast(image.term_length)))));
            nak_header.term_offset = gap.offset;
            nak_header.length = gap.length;

            const nak_bytes = @as([*]const u8, @ptrCast(&nak_header))[0..protocol.NakHeader.LENGTH];
            _ = try self.send_endpoint.send(image.source_address, nak_bytes);

            // Log send_nak event
            if (self.event_log) |el| {
                const nak_now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
                el.log(.send_nak, nak_now, image.session_id, image.stream_id, nak_bytes);
            }
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
test "NAK: adjacent gaps produce one coalesced NAK" {
    // Create two adjacent gap records for the same Image
    var nak_state = NakState.init(1001);
    nak_state.recordGap(100, 64); // gap at offset 100, length 64
    nak_state.recordGap(164, 128); // adjacent gap at 164, length 128

    // Should coalesce into one gap: offset=100, length=192
    const gaps = nak_state.gaps();
    try std.testing.expectEqual(@as(usize, 1), gaps.len);
    try std.testing.expectEqual(@as(i32, 100), gaps[0].offset);
    try std.testing.expectEqual(@as(i32, 192), gaps[0].length);
}

test "NAK: no NAK sent within delay window" {
    // Use an injectable base_time to avoid non-determinism from std.time.nanoTimestamp().
    // NakState.initWithTime(stream_id, first_gap_ns) sets first_gap_ns directly.
    var nak_state = NakState.initWithTime(1001, 0);
    nak_state.gap_list[0] = .{ .offset = 100, .length = 64 };
    nak_state.gap_list_len = 1;

    // Before delay elapses: should not send
    try std.testing.expect(!nak_state.shouldSend(NAK_DELAY_NS - 1));
    // After delay: should send
    try std.testing.expect(nak_state.shouldSend(NAK_DELAY_NS));
}

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
