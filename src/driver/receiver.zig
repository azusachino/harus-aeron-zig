// Receiver duty agent — polls incoming UDP frames and dispatches by type
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/c/aeron_receiver.c
const std = @import("std");
const net = @import("../net.zig");
const time = @import("../time.zig");
const builtin = @import("builtin");
const logbuffer = @import("../logbuffer/log_buffer.zig");
const metadata = @import("../logbuffer/metadata.zig");
const agrona = @import("agrona");
const counters = agrona.counters;
const protocol = @import("../protocol/frame.zig");
const transport = @import("../transport/endpoint.zig");
const loss_report = @import("../loss_report.zig");
const event_log_mod = @import("../event_log.zig");

const SpinMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.state.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.unlock();
    }
};

pub const Image = struct {
    session_id: i32,
    stream_id: i32,
    term_length: i32,
    mtu: i32,
    initial_term_id: i32,
    log_buffer: *logbuffer.LogBuffer,
    receiver_hwm: counters.CounterHandle, // highest term_offset seen
    subscriber_position: counters.CounterHandle, // client-owned image position counter
    rebuild_position: i64, // tracks gap filling progress
    last_status_position: i64,
    last_status_ns: i64,
    term_ids: [metadata.PARTITION_COUNT]i32,
    source_address: net.Address,
    nak_state: NakState,
    last_activity_ns: i64,

    pub fn init(
        session_id: i32,
        stream_id: i32,
        term_length: i32,
        mtu: i32,
        initial_term_id: i32,
        active_term_id: i32,
        log_buffer: *logbuffer.LogBuffer,
        receiver_hwm: counters.CounterHandle,
        subscriber_position: counters.CounterHandle,
        source_address: net.Address,
    ) Image {
        // H4 fix: start rebuild at the active term so advanceRebuildPosition
        // doesn't stall waiting for data in an earlier (empty) partition.
        const term_count = @as(i64, active_term_id - initial_term_id);
        const initial_rebuild_position = term_count * @as(i64, term_length);
        var term_ids = [_]i32{std.math.minInt(i32)} ** metadata.PARTITION_COUNT;
        const active_partition = @as(usize, @intCast(@mod(active_term_id - initial_term_id, @as(i32, @intCast(metadata.PARTITION_COUNT)))));
        term_ids[active_partition] = active_term_id;
        if (builtin.mode == .Debug) {
            std.debug.print("[IMAGE] init: session={d} stream={d} initial_term_id={d} active_term_id={d} rebuild_start={d}\n", .{ session_id, stream_id, initial_term_id, active_term_id, initial_rebuild_position });
        }
        return .{
            .session_id = session_id,
            .stream_id = stream_id,
            .term_length = term_length,
            .mtu = mtu,
            .initial_term_id = initial_term_id,
            .log_buffer = log_buffer,
            .receiver_hwm = receiver_hwm,
            .subscriber_position = subscriber_position,
            .rebuild_position = initial_rebuild_position,
            .last_status_position = 0,
            .last_status_ns = 0,
            .term_ids = term_ids,
            .source_address = source_address,
            .nak_state = NakState.init(log_buffer.allocator, stream_id),
            .last_activity_ns = @as(i64, @intCast(time.nanoTimestamp())),
        };
    }

    pub fn deinit(self: *Image) void {
        self.nak_state.deinit();
        // log_buffer owned externally — no-op
    }

    fn positionFor(self: *const Image, term_id: i32, term_offset: i32) i64 {
        const term_count = term_id - self.initial_term_id;
        return @as(i64, term_count) * self.term_length + term_offset;
    }

    fn prepareTerm(self: *Image, partition: usize, term_id: i32) []u8 {
        const term_buffer = self.log_buffer.termBuffer(partition);
        if (self.term_ids[partition] != term_id) {
            // A partition is reused after three terms. Clear old commit markers
            // before the new term can be considered contiguous by rebuild scan.
            @memset(term_buffer, 0);
            self.term_ids[partition] = term_id;
        }
        return term_buffer;
    }

    // Write an incoming DATA frame into the log buffer at the correct partition+offset
    // Returns true if written, false if out-of-bounds or duplicate
    pub fn insertFrame(self: *Image, counters_map: *counters.CountersMap, header: *const protocol.DataHeader, payload: []const u8) bool {
        // LESSON(receiver): Write header then payload to term buffer, then write frame_length last (atomic commit signal). See docs/tutorial/03-driver/02-receiver.md
        // Compute active partition for header.term_id
        const term_count = header.term_id - self.initial_term_id;
        const partition = @as(usize, @intCast(@mod(term_count, 3)));

        const frame_offset = @as(usize, @intCast(header.term_offset));
        const term_buffer = self.prepareTerm(partition, header.term_id);

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

        // Align frame length to FRAME_ALIGNMENT boundary (for position tracking)
        const aligned_len = @as(i32, @intCast((total_frame_len + protocol.FRAME_ALIGNMENT - 1) / protocol.FRAME_ALIGNMENT * protocol.FRAME_ALIGNMENT));

        // Write original frame_length as commit signal (NOT aligned — payload length must be exact)
        // advanceRebuildPosition and TermReader both align at read time.
        const len_ptr = @as(*i32, @ptrCast(@alignCast(&term_buffer[frame_offset])));
        @atomicStore(i32, len_ptr, @as(i32, @intCast(total_frame_len)), .release);

        // Update receiver_hwm counter using absolute stream position.
        const new_hwm = self.positionFor(header.term_id, header.term_offset + aligned_len);
        const current_hwm = counters_map.get(self.receiver_hwm.counter_id);
        if (new_hwm > current_hwm) {
            counters_map.set(self.receiver_hwm.counter_id, new_hwm);
        }

        self.advanceRebuildPosition(counters_map);

        return true;
    }

    // LESSON(receiver): Padding is part of the reliable term stream; storing it locally lets rebuild position and STATUS cross the ring boundary. See docs/tutorial/03-driver/02-receiver.md
    pub fn insertPadding(self: *Image, counters_map: *counters.CountersMap, header: *const protocol.DataHeader) bool {
        const term_count = header.term_id - self.initial_term_id;
        const partition = @as(usize, @intCast(@mod(term_count, @as(i32, @intCast(metadata.PARTITION_COUNT)))));
        const frame_offset = @as(usize, @intCast(header.term_offset));
        const padding_length = header.frame_length;
        const term_buffer = self.prepareTerm(partition, header.term_id);

        if (padding_length < @as(i32, @intCast(protocol.DataHeader.LENGTH)) or
            frame_offset + @as(usize, @intCast(padding_length)) > term_buffer.len)
        {
            return false;
        }

        const header_ptr = @as(*protocol.DataHeader, @ptrCast(@alignCast(&term_buffer[frame_offset])));
        header_ptr.* = header.*;
        const len_ptr = @as(*i32, @ptrCast(@alignCast(&term_buffer[frame_offset])));
        @atomicStore(i32, len_ptr, padding_length, .release);

        const new_hwm = self.positionFor(header.term_id, header.term_offset + padding_length);
        const current_hwm = counters_map.get(self.receiver_hwm.counter_id);
        if (new_hwm > current_hwm) {
            counters_map.set(self.receiver_hwm.counter_id, new_hwm);
        }
        self.advanceRebuildPosition(counters_map);
        return true;
    }

    fn advanceRebuildPosition(self: *Image, counters_map: *counters.CountersMap) void {
        _ = counters_map;
        var position = self.rebuild_position;

        while (true) {
            const term_count = @divTrunc(position, @as(i64, @intCast(self.term_length)));
            const partition = @as(usize, @intCast(@mod(term_count, metadata.PARTITION_COUNT)));
            const term_offset = @as(usize, @intCast(@mod(position, @as(i64, @intCast(self.term_length)))));
            const term_buffer = self.log_buffer.termBuffer(partition);

            if (term_offset + 4 > term_buffer.len) break;

            const frame_length = std.mem.readInt(i32, term_buffer[term_offset..][0..4], .little);
            if (frame_length <= 0) break;

            const aligned_length = std.mem.alignForward(i32, frame_length, @as(i32, @intCast(protocol.FRAME_ALIGNMENT)));
            if (aligned_length <= 0) break;
            if (term_offset + @as(usize, @intCast(aligned_length)) > term_buffer.len) break;

            position += aligned_length;
        }

        self.rebuild_position = position;
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
    source_address: net.Address,
};

pub const StatusSignal = struct {
    session_id: i32,
    stream_id: i32,
    consumption_term_id: i32,
    consumption_term_offset: i32,
    receiver_window: i32,
    receiver_id: i64,
};

pub const NakSignal = struct {
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    term_offset: i32,
    length: i32,
};

const NAK_DELAY_NS: i64 = 1_000_000; // 1ms
const STATUS_REFRESH_NS: i64 = 200_000_000; // 200ms, recover lost flow-control feedback

pub const GapRange = struct { offset: i32, length: i32 };

pub const NakState = struct {
    allocator: std.mem.Allocator,
    stream_id: i32,
    gap_list: std.ArrayListUnmanaged(GapRange) = .empty,
    first_gap_ns: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, stream_id: i32) NakState {
        return .{ .allocator = allocator, .stream_id = stream_id };
    }

    /// For tests: inject a known first_gap_ns instead of using the real clock.
    pub fn initWithTime(allocator: std.mem.Allocator, stream_id: i32, first_gap_ns: i64) NakState {
        return .{ .allocator = allocator, .stream_id = stream_id, .first_gap_ns = first_gap_ns };
    }

    pub fn deinit(self: *NakState) void {
        self.gap_list.deinit(self.allocator);
        self.gap_list = .empty;
        self.first_gap_ns = 0;
    }

    pub fn recordGap(self: *NakState, offset: i32, length: i32) !void {
        const end = offset + length;
        // Try to merge with existing gap
        var i: usize = 0;
        while (i < self.gap_list.items.len) : (i += 1) {
            var g = &self.gap_list.items[i];
            if (offset <= g.offset + g.length and end >= g.offset) {
                g.offset = @min(g.offset, offset);
                g.length = @max(g.offset + g.length, end) - g.offset;
                return;
            }
        }
        if (self.gap_list.items.len == 0) self.first_gap_ns = @as(i64, @intCast(time.nanoTimestamp()));
        try self.gap_list.append(self.allocator, .{ .offset = offset, .length = length });
    }

    pub fn shouldSend(self: *const NakState, now_ns: i64) bool {
        return self.gap_list.items.len > 0 and (now_ns - self.first_gap_ns) >= NAK_DELAY_NS;
    }

    pub fn gaps(self: *const NakState) []const GapRange {
        return self.gap_list.items;
    }

    pub fn clear(self: *NakState) void {
        self.gap_list.clearRetainingCapacity();
        self.first_gap_ns = 0;
    }
};

pub const Receiver = struct {
    images: std.ArrayListUnmanaged(*Image),
    pending_setups: std.ArrayListUnmanaged(SetupSignal) = .empty,
    pending_status_messages: std.ArrayListUnmanaged(StatusSignal) = .empty,
    pending_nak_messages: std.ArrayListUnmanaged(NakSignal) = .empty,
    recv_endpoint: *transport.ReceiveChannelEndpoint,
    send_endpoint: *transport.SendChannelEndpoint,
    counters_map: *counters.CountersMap,
    loss_report_instance: ?*loss_report.LossReport,
    event_log: ?*event_log_mod.EventLog,
    allocator: std.mem.Allocator,
    recv_buf: [65536]u8 align(8), // 64KB — fits any Aeron datagram incl. batched frames
    mutex: SpinMutex = .{},
    // Diagnostic counters (atomic for cross-thread visibility)
    data_frames_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    data_frames_before_image: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    status_messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

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
            .images = std.ArrayListUnmanaged(*Image).empty,
            .pending_setups = std.ArrayListUnmanaged(SetupSignal).empty,
            .recv_endpoint = recv_ep,
            .send_endpoint = send_ep,
            .counters_map = counters_map_,
            .loss_report_instance = loss_rpt,
            .event_log = el,
            .allocator = allocator,
            .recv_buf = undefined,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Receiver) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.images.items) |image| {
            image.deinit();
            image.log_buffer.deinit();
            self.allocator.destroy(image.log_buffer);
            self.allocator.destroy(image);
        }
        self.images.deinit(self.allocator);
        self.pending_setups.deinit(self.allocator);
        self.pending_status_messages.deinit(self.allocator);
        self.pending_nak_messages.deinit(self.allocator);
    }

    pub fn drainPendingSetups(self: *Receiver) []SetupSignal {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slice = self.pending_setups.toOwnedSlice(self.allocator) catch return &.{};
        return slice;
    }

    pub fn drainPendingStatusMessages(self: *Receiver) []StatusSignal {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slice = self.pending_status_messages.toOwnedSlice(self.allocator) catch return &.{};
        return slice;
    }

    pub fn drainPendingNakMessages(self: *Receiver) []NakSignal {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending_nak_messages.toOwnedSlice(self.allocator) catch return &.{};
    }

    pub fn statusMessagesSent(self: *const Receiver) u64 {
        return self.status_messages_sent.load(.monotonic);
    }

    pub fn processDatagram(self: *Receiver, data: []const u8, src_addr: net.Address) i32 {
        if (data.len < 8) return 0;

        // H2 fix: walk ALL Aeron frames packed into this UDP datagram.
        // Java Sender may coalesce multiple small frames into one MTU-sized packet.
        // Each frame is padded to FRAME_ALIGNMENT (32 bytes); advance by aligned frame_length.
        var offset: usize = 0;
        var work: i32 = 0;

        while (offset + 8 <= data.len) {
            const frame_data = data[offset..];
            const raw_frame_len = std.mem.readInt(i32, frame_data[0..4], .little);
            if (raw_frame_len <= 0) break; // zero or padding — end of batch
            const frame_type_raw = std.mem.readInt(u16, frame_data[6..8], .little);
            const aligned_advance = std.mem.alignForward(usize, @as(usize, @intCast(raw_frame_len)), protocol.FRAME_ALIGNMENT);

            if (frame_type_raw == @intFromEnum(protocol.FrameType.data)) {
                if (frame_data.len < protocol.DataHeader.LENGTH) break;
                const header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&frame_data[0])));
                if (header.frame_length < @as(i32, @intCast(protocol.DataHeader.LENGTH))) {
                    offset += aligned_advance;
                    continue;
                }

                const total = self.data_frames_total.fetchAdd(1, .monotonic) + 1;
                if (builtin.mode == .Debug) {
                    std.debug.print("[RECEIVER] DATA frame #{d}: pkt_len={d} term_id={d} term_offset={d} frame_len={d} session={d} stream={d}\n", .{
                        total, data.len, header.term_id, header.term_offset, header.frame_length, header.session_id, header.stream_id,
                    });
                }

                const payload_len_raw = @as(i32, header.frame_length) - @as(i32, @intCast(protocol.DataHeader.LENGTH));
                const payload_len: usize = if (payload_len_raw > 0) @intCast(payload_len_raw) else 0;
                const payload_offset = protocol.DataHeader.LENGTH;

                self.mutex.lock();

                var image_for_status: ?*Image = null;
                var found_image = false;
                for (self.images.items) |image| {
                    if (image.session_id == header.session_id and image.stream_id == header.stream_id) {
                        found_image = true;
                        image.last_activity_ns = @as(i64, @intCast(time.nanoTimestamp()));
                        if (payload_offset + payload_len <= frame_data.len) {
                            const payload = frame_data[payload_offset .. payload_offset + payload_len];

                            const written = image.insertFrame(self.counters_map, header, payload);
                            if (!written) {
                                if (builtin.mode == .Debug) {
                                    std.debug.print("[RECEIVER] insertFrame FAILED: session={d} stream={d} term_id={d} term_offset={d}\n", .{
                                        header.session_id, header.stream_id, header.term_id, header.term_offset,
                                    });
                                }
                            }

                            if (self.event_log) |el| {
                                const evt_now: i64 = @as(i64, @intCast(time.nanoTimestamp()));
                                el.log(.frame_in, evt_now, image.session_id, image.stream_id, payload);
                            }

                            if (image.hasGap(self.counters_map)) {
                                const hwm = self.counters_map.get(image.receiver_hwm.counter_id);
                                const gap_len = @as(i32, @intCast(hwm - image.rebuild_position));
                                const gap_off = @as(i32, @intCast(@mod(image.rebuild_position, @as(i64, @intCast(image.term_length)))));
                                image.nak_state.recordGap(gap_off, gap_len) catch |err| {
                                    std.log.err("receiver failed to record NAK gap session_id={} stream_id={} err={}", .{ image.session_id, image.stream_id, err });
                                };
                                if (self.loss_report_instance) |lr| {
                                    const lnow: i64 = @as(i64, @intCast(time.nanoTimestamp()));
                                    lr.recordObservation(@as(i64, @intCast(payload.len)), lnow, image.session_id, image.stream_id, "aeron:udp");
                                }
                            }

                            const now = @as(i64, @intCast(time.nanoTimestamp()));
                            if (image.nak_state.shouldSend(now)) {
                                self.sendNak(image) catch {};
                                image.nak_state.clear();
                            }

                            image_for_status = image;
                        }
                        break;
                    }
                }

                if (!found_image) {
                    _ = self.data_frames_before_image.fetchAdd(1, .monotonic);
                    if (builtin.mode == .Debug) {
                        std.debug.print("[RECEIVER] DATA for unknown session={d} stream={d} (images={d}) term_id={d} term_offset={d}\n", .{
                            header.session_id, header.stream_id, self.images.items.len, header.term_id, header.term_offset,
                        });
                    }
                }

                self.mutex.unlock();

                // Send STATUS outside the lock; image pointer is stable while driver is running
                if (image_for_status) |img| {
                    if (builtin.mode == .Debug) {
                        std.debug.print("[RECEIVER] sending STATUS to {any}\n", .{img.source_address});
                    }
                    self.sendStatus(img) catch |err| switch (err) {
                        error.WouldBlock => {},
                        else => std.log.err("receiver STATUS send failed session_id={} stream_id={} err={}", .{ img.session_id, img.stream_id, err }),
                    };
                }

                work += 1;
            } else if (frame_type_raw == @intFromEnum(protocol.FrameType.padding)) {
                if (frame_data.len < protocol.DataHeader.LENGTH) break;
                const header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&frame_data[0])));

                self.mutex.lock();
                var image_for_status: ?*Image = null;
                for (self.images.items) |image| {
                    if (image.session_id == header.session_id and image.stream_id == header.stream_id) {
                        if (image.insertPadding(self.counters_map, header)) {
                            image.last_activity_ns = @as(i64, @intCast(time.nanoTimestamp()));
                            image_for_status = image;
                        }
                        break;
                    }
                }
                self.mutex.unlock();

                if (image_for_status) |img| {
                    self.sendStatus(img) catch |err| switch (err) {
                        error.WouldBlock => {},
                        else => std.log.err("receiver padding STATUS send failed session_id={} stream_id={} err={}", .{ img.session_id, img.stream_id, err }),
                    };
                }
                work += 1;
            } else if (frame_type_raw == @intFromEnum(protocol.FrameType.setup)) {
                if (frame_data.len < protocol.SetupHeader.LENGTH) {
                    offset += aligned_advance;
                    continue;
                }
                const setup = @as(*const protocol.SetupHeader, @ptrCast(@alignCast(&frame_data[0])));
                if (builtin.mode == .Debug) {
                    std.debug.print("[RECEIVER] SETUP: session={d} stream={d} initial_term_id={d} active_term_id={d} src={any}\n", .{
                        setup.session_id, setup.stream_id, setup.initial_term_id, setup.active_term_id, src_addr,
                    });
                }
                self.mutex.lock();
                self.pending_setups.append(self.allocator, .{
                    .session_id = setup.session_id,
                    .stream_id = setup.stream_id,
                    .initial_term_id = setup.initial_term_id,
                    .active_term_id = setup.active_term_id,
                    .term_length = setup.term_length,
                    .mtu = setup.mtu,
                    .source_address = src_addr,
                }) catch {};
                self.mutex.unlock();
                work += 1;
            } else if (frame_type_raw == @intFromEnum(protocol.FrameType.status)) {
                if (frame_data.len < protocol.StatusMessage.LENGTH) {
                    offset += aligned_advance;
                    continue;
                }
                const status = @as(*const protocol.StatusMessage, @ptrCast(@alignCast(&frame_data[0])));
                self.mutex.lock();
                // STATUS frames are flow-control feedback for publications; queue for conductor/sender.
                self.pending_status_messages.append(self.allocator, .{
                    .session_id = status.session_id,
                    .stream_id = status.stream_id,
                    .consumption_term_id = status.consumption_term_id,
                    .consumption_term_offset = status.consumption_term_offset,
                    .receiver_window = status.receiver_window,
                    .receiver_id = status.receiver_id,
                }) catch {};
                self.mutex.unlock();
                work += 1;
            } else if (frame_type_raw == @intFromEnum(protocol.FrameType.nak)) {
                if (frame_data.len >= protocol.NakHeader.LENGTH) {
                    const nak = @as(*const protocol.NakHeader, @ptrCast(@alignCast(&frame_data[0])));
                    self.mutex.lock();
                    self.pending_nak_messages.append(self.allocator, .{
                        .session_id = nak.session_id,
                        .stream_id = nak.stream_id,
                        .term_id = nak.term_id,
                        .term_offset = nak.term_offset,
                        .length = nak.length,
                    }) catch {};
                    self.mutex.unlock();
                    work += 1;
                }
            }

            offset += aligned_advance;
        }

        return work;
    }

    // Single duty cycle: recv one frame, dispatch, return work count (0 or 1)
    pub fn doWork(self: *Receiver) i32 {
        var src_addr: net.Address = undefined;
        const bytes_read = self.recv_endpoint.recv(&self.recv_buf, &src_addr) catch |err| {
            if (err != error.WouldBlock and builtin.mode == .Debug) {
                std.debug.print("[RECEIVER] recv error: {any}\n", .{err});
            }
            return self.refreshSubscriberStatuses();
        };

        if (bytes_read == 0) {
            return self.refreshSubscriberStatuses();
        }

        return self.processDatagram(self.recv_buf[0..bytes_read], src_addr);
    }

    fn refreshSubscriberStatuses(self: *Receiver) i32 {
        var work: i32 = 0;
        const now_ns = @as(i64, @intCast(time.nanoTimestamp()));
        self.mutex.lock();
        const images = self.images.items;
        for (images) |image| {
            if (image.nak_state.shouldSend(now_ns)) {
                self.mutex.unlock();
                self.sendNak(image) catch |err| {
                    std.log.err("receiver idle NAK send failed session_id={} stream_id={} err={}", .{ image.session_id, image.stream_id, err });
                };
                image.nak_state.clear();
                work += 1;
                self.mutex.lock();
            }

            const subscriber_position = self.counters_map.get(image.subscriber_position.counter_id);
            const consumption_position = @min(image.rebuild_position, subscriber_position);
            if (consumption_position > image.last_status_position or
                now_ns - image.last_status_ns >= STATUS_REFRESH_NS)
            {
                self.mutex.unlock();
                self.sendStatus(image) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => std.log.err("receiver refresh STATUS send failed session_id={} stream_id={} err={}", .{ image.session_id, image.stream_id, err }),
                };
                work += 1;
                self.mutex.lock();
            }
        }
        self.mutex.unlock();
        return work;
    }

    pub fn onAddSubscription(self: *Receiver, image: *Image) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.images.append(self.allocator, image);
    }

    pub fn hasImage(self: *Receiver, session_id: i32, stream_id: i32) bool {
        for (self.images.items) |image| {
            if (image.session_id == session_id and image.stream_id == stream_id) {
                return true;
            }
        }
        return false;
    }

    pub fn onRemoveSubscription(self: *Receiver, session_id: i32, stream_id: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].session_id == session_id and self.images.items[i].stream_id == stream_id) {
                const image = self.images.swapRemove(i);
                image.deinit();
                return;
            }
            i += 1;
        }
    }

    // Send a NAK frame back to source_address for the given image's gaps
    pub fn sendNak(self: *Receiver, image: *Image) !void {
        // LESSON(receiver): NAK generation coalesces gaps then sends one NAK per gap after 1ms delay. See docs/tutorial/03-driver/02-receiver.md
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
                const nak_now: i64 = @as(i64, @intCast(time.nanoTimestamp()));
                el.log(.send_nak, nak_now, image.session_id, image.stream_id, nak_bytes);
            }
        }
    }

    // Send a STATUS message to source_address acknowledging receipt
    pub fn sendStatus(self: *Receiver, image: *Image) !void {
        // STATUS must describe the slowest client-visible position, not merely
        // network receipt. Otherwise a fast source can lap the three-term ring
        // and overwrite frames before the subscriber reads them.
        const subscriber_position = self.counters_map.get(image.subscriber_position.counter_id);
        const consumption_position = @min(image.rebuild_position, subscriber_position);
        const consumption_term_id = image.initial_term_id + @as(i32, @intCast(@divTrunc(consumption_position, @as(i64, @intCast(image.term_length)))));
        const consumption_term_offset = @as(i32, @intCast(@mod(consumption_position, @as(i64, @intCast(image.term_length)))));

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
        _ = self.status_messages_sent.fetchAdd(1, .monotonic);
        image.last_status_position = consumption_position;
        image.last_status_ns = @as(i64, @intCast(time.nanoTimestamp()));
    }
};

// Unit tests
test "NAK: adjacent gaps produce one coalesced NAK" {
    const allocator = std.testing.allocator;
    // Create two adjacent gap records for the same Image
    var nak_state = NakState.init(allocator, 1001);
    defer nak_state.deinit();
    try nak_state.recordGap(100, 64); // gap at offset 100, length 64
    try nak_state.recordGap(164, 128); // adjacent gap at 164, length 128

    // Should coalesce into one gap: offset=100, length=192
    const gaps = nak_state.gaps();
    try std.testing.expectEqual(@as(usize, 1), gaps.len);
    try std.testing.expectEqual(@as(i32, 100), gaps[0].offset);
    try std.testing.expectEqual(@as(i32, 192), gaps[0].length);
}

test "NAK: no NAK sent within delay window" {
    const allocator = std.testing.allocator;
    // Use an injectable base_time to avoid non-determinism from @as(i64, @intCast(time.nanoTimestamp())).
    // NakState.initWithTime(allocator, stream_id, first_gap_ns) sets first_gap_ns directly.
    var nak_state = NakState.initWithTime(allocator, 1001, 0);
    defer nak_state.deinit();
    try nak_state.gap_list.append(allocator, .{ .offset = 100, .length = 64 });

    // Before delay elapses: should not send
    try std.testing.expect(!nak_state.shouldSend(NAK_DELAY_NS - 1));
    // After delay: should send
    try std.testing.expect(nak_state.shouldSend(NAK_DELAY_NS));
}

test "NAK: gap list grows past sixteen entries" {
    const allocator = std.testing.allocator;

    var nak_state = NakState.init(allocator, 1001);
    defer nak_state.deinit();

    for (0..17) |i| {
        try nak_state.recordGap(@as(i32, @intCast(i * 64)), 32);
    }

    try std.testing.expectEqual(@as(usize, 17), nak_state.gaps().len);
}

test "Receiver init and deinit" {
    const allocator = std.testing.allocator;

    // Create minimal channel setup
    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    // Create mock endpoints (we won't actually use them)
    // Just test that Receiver can be created and destroyed
    const dummy_socket: net.socket_t = undefined;
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

    const dummy_socket: net.socket_t = undefined;
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
        100,
        &log_buf,
        hwm_handle,
        sub_pos_handle,
        undefined,
    );

    try receiver.onAddSubscription(&image);
    try std.testing.expectEqual(@as(usize, 1), receiver.images.items.len);
    try std.testing.expect(receiver.hasImage(1, 2));

    receiver.onRemoveSubscription(1, 2);
    try std.testing.expectEqual(@as(usize, 0), receiver.images.items.len);
    try std.testing.expect(!receiver.hasImage(1, 2));
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
    try std.testing.expectEqual(hwm, image.rebuild_position);
    try std.testing.expectEqual(@as(i64, 0), counters_map.get(sub_pos_handle.counter_id));
}

test "Image clears a reused term partition before rebuilding" {
    const allocator = std.testing.allocator;
    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);
    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    const hwm_handle = counters_map.allocate(counters.RECEIVER_HWM, "wrap-hwm");
    const sub_pos_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "wrap-sub");
    var image = Image.init(1, 2, 64 * 1024, 1500, 0, 0, &log_buf, hwm_handle, sub_pos_handle, undefined);

    var header: protocol.DataHeader = undefined;
    header.frame_length = @as(i32, @intCast(protocol.DataHeader.LENGTH + 3));
    header.version = protocol.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(protocol.FrameType.data);
    header.term_offset = 0;
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 0;
    header.reserved_value = 0;
    try std.testing.expect(image.insertFrame(&counters_map, &header, "old"));

    image.rebuild_position = 3 * @as(i64, image.term_length);
    header.term_id = 3;
    try std.testing.expect(image.insertFrame(&counters_map, &header, "new"));

    const term_buffer = log_buf.termBuffer(0);
    try std.testing.expectEqualStrings("new", term_buffer[protocol.DataHeader.LENGTH .. protocol.DataHeader.LENGTH + 3]);
    try std.testing.expectEqual(@as(i32, 3), image.term_ids[0]);
}

test "Image insertPadding advances rebuild position across a term" {
    const allocator = std.testing.allocator;

    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    const hwm_handle = counters_map.allocate(counters.RECEIVER_HWM, "test-padding-hwm");
    const sub_pos_handle = counters_map.allocate(counters.SUBSCRIBER_POSITION, "test-padding-sub");
    var image = Image.init(1, 2, 64 * 1024, 1500, 0, 0, &log_buf, hwm_handle, sub_pos_handle, undefined);
    image.rebuild_position = 64 * 1024 - 32;

    var header: protocol.DataHeader = undefined;
    header.frame_length = 32;
    header.version = protocol.VERSION;
    header.flags = protocol.DataHeader.PADDING_FLAG;
    header.type = @intFromEnum(protocol.FrameType.padding);
    header.term_offset = 64 * 1024 - 32;
    header.session_id = 1;
    header.stream_id = 2;
    header.term_id = 0;
    header.reserved_value = 0;

    try std.testing.expect(image.insertPadding(&counters_map, &header));
    try std.testing.expectEqual(@as(i64, 64 * 1024), image.rebuild_position);
    try std.testing.expectEqual(@as(i64, 64 * 1024), counters_map.get(hwm_handle.counter_id));
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

test "Image insertFrame keeps gap until missing prefix arrives" {
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
        0,
        &log_buf,
        hwm_handle,
        sub_pos_handle,
        undefined,
    );

    var first: protocol.DataHeader = undefined;
    first.frame_length = 43;
    first.version = protocol.VERSION;
    first.flags = 0;
    first.type = @intFromEnum(protocol.FrameType.data);
    first.term_offset = 64;
    first.session_id = 1;
    first.stream_id = 2;
    first.term_id = 0;
    first.reserved_value = 0;

    try std.testing.expect(image.insertFrame(&counters_map, &first, "late-frame"));
    try std.testing.expectEqual(@as(i64, 0), image.rebuild_position);
    try std.testing.expect(image.hasGap(&counters_map));

    var prefix: protocol.DataHeader = first;
    prefix.term_offset = 0;
    try std.testing.expect(image.insertFrame(&counters_map, &prefix, "first-frame"));
    try std.testing.expect(!image.hasGap(&counters_map));
    try std.testing.expect(image.rebuild_position > 64);
    try std.testing.expectEqual(@as(i64, 0), counters_map.get(sub_pos_handle.counter_id));
}

test "Receiver queues STATUS messages for sender flow control" {
    const allocator = std.testing.allocator;
    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    const dummy_socket: net.socket_t = undefined;
    var recv_endpoint = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = transport.SendChannelEndpoint{
        .socket = dummy_socket,
    };

    var receiver = try Receiver.init(allocator, &recv_endpoint, &send_endpoint, &counters_map, null);
    defer receiver.deinit();

    var status: protocol.StatusMessage = undefined;
    status.frame_length = protocol.StatusMessage.LENGTH;
    status.version = protocol.VERSION;
    status.flags = 0;
    status.type = @intFromEnum(protocol.FrameType.status);
    status.session_id = 9;
    status.stream_id = 1001;
    status.consumption_term_id = 3;
    status.consumption_term_offset = 2048;
    status.receiver_window = 4096;
    status.receiver_id = 77;

    const bytes = @as([*]const u8, @ptrCast(&status))[0..protocol.StatusMessage.LENGTH];
    try std.testing.expectEqual(@as(i32, 1), receiver.processDatagram(bytes, net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123)));

    const pending = receiver.drainPendingStatusMessages();
    defer allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(@as(i32, 9), pending[0].session_id);
    try std.testing.expectEqual(@as(i32, 1001), pending[0].stream_id);
    try std.testing.expectEqual(@as(i32, 2048), pending[0].consumption_term_offset);
    try std.testing.expectEqual(@as(i32, 4096), pending[0].receiver_window);
}

test "Receiver queues NAK messages for sender retransmission" {
    const allocator = std.testing.allocator;
    var meta_buffer align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values_buffer align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta_buffer, &values_buffer);

    const dummy_socket: net.socket_t = undefined;
    var recv_endpoint = transport.ReceiveChannelEndpoint{
        .socket = dummy_socket,
        .bound_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    };
    var send_endpoint = transport.SendChannelEndpoint{ .socket = dummy_socket };
    var receiver = try Receiver.init(allocator, &recv_endpoint, &send_endpoint, &counters_map, null);
    defer receiver.deinit();

    var nak: protocol.NakHeader = undefined;
    nak.frame_length = protocol.NakHeader.LENGTH;
    nak.version = protocol.VERSION;
    nak.flags = 0;
    nak.type = @intFromEnum(protocol.FrameType.nak);
    nak.session_id = 9;
    nak.stream_id = 1001;
    nak.term_id = 7;
    nak.term_offset = 2048;
    nak.length = 4096;

    const bytes = @as([*]const u8, @ptrCast(&nak))[0..protocol.NakHeader.LENGTH];
    try std.testing.expectEqual(@as(i32, 1), receiver.processDatagram(bytes, net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123)));

    const pending = receiver.drainPendingNakMessages();
    defer allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(@as(i32, 9), pending[0].session_id);
    try std.testing.expectEqual(@as(i32, 7), pending[0].term_id);
    try std.testing.expectEqual(@as(i32, 2048), pending[0].term_offset);
    try std.testing.expectEqual(@as(i32, 4096), pending[0].length);
}
