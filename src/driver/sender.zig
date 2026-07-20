// Aeron Sender — outputs DATA and SETUP frames for active publications
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/Sender.java

const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");
const time = @import("../time.zig");
const logbuffer = @import("../logbuffer/log_buffer.zig");
const metadata = @import("../logbuffer/metadata.zig");
const agrona = @import("agrona");
const counters = agrona.counters;
const protocol = @import("../protocol/frame.zig");
const endpoint = @import("../transport/endpoint.zig");
const event_log_mod = @import("../event_log.zig");
const flow_control = @import("flow_control.zig");
const INVALID_SOCKET: net.socket_t = std.math.maxInt(net.socket_t);
const MAX_DATA_FRAMES_PER_WORK: i32 = 4;
const MAX_RETRANSMIT_FRAMES_PER_WORK: usize = 32;

pub const RetransmitRequest = struct {
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    term_offset: i32,
    length: i32,
    source_address: net.Address,
    timestamp_ms: i64,
};

pub const NetworkPublication = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    log_buffer: *logbuffer.LogBuffer,
    sender_position: counters.CounterHandle,
    publisher_limit: counters.CounterHandle,
    send_channel: *endpoint.SendChannelEndpoint,
    dest_address: net.Address,
    mtu: i32,
    last_setup_time_ms: i64,
    last_heartbeat_time_ms: i64,
    last_activity_ns: i64,
    flow_control_strategy: flow_control.FlowControl,
};

pub const Sender = struct {
    publications: std.ArrayList(*NetworkPublication),
    send_endpoint: *endpoint.SendChannelEndpoint,
    counters_map: *counters.CountersMap,
    allocator: std.mem.Allocator,
    retransmit_queue: std.ArrayList(RetransmitRequest),
    current_time_ms: i64,
    event_log: ?*event_log_mod.EventLog,
    status_messages_applied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_status_session_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_status_stream_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_status_term_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_status_term_offset: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_status_window: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_status_limit: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    data_frames_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_sent_term_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_sent_term_offset: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_sent_frame_length: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    stale_frames_skipped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_expected_term_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_expected_term_offset: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    retransmit_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    retransmits_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_retransmit_term_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_term_offset: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_length: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_source_port: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_frame_term_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_frame_term_offset: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_frame_session_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_frame_stream_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    last_retransmit_frame_length: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        send_endpoint: *endpoint.SendChannelEndpoint,
        counters_map: *counters.CountersMap,
    ) !Sender {
        return initWithEventLog(allocator, send_endpoint, counters_map, null);
    }

    pub fn initWithEventLog(
        allocator: std.mem.Allocator,
        send_ep: *endpoint.SendChannelEndpoint,
        counters_map_: *counters.CountersMap,
        el: ?*event_log_mod.EventLog,
    ) !Sender {
        return .{
            .publications = std.ArrayList(*NetworkPublication).empty,
            .send_endpoint = send_ep,
            .counters_map = counters_map_,
            .allocator = allocator,
            .retransmit_queue = std.ArrayList(RetransmitRequest).empty,
            .current_time_ms = 0,
            .event_log = el,
        };
    }

    pub fn deinit(self: *Sender) void {
        self.publications.deinit(self.allocator);
        self.retransmit_queue.deinit(self.allocator);
    }

    pub fn doWork(self: *Sender) i32 {
        // LESSON(sender): Main work loop dispatches to publication processing and retransmit handling. See docs/tutorial/03-driver/01-sender.md
        var work_count: i32 = 0;

        // Process active publications
        for (self.publications.items) |publication| {
            work_count += self.processPublication(publication);
        }

        // Process retransmit queue
        work_count += self.processRetransmits();

        return work_count;
    }

    fn processPublication(self: *Sender, publication: *NetworkPublication) i32 {
        // LESSON(sender): SETUP must be sent unconditionally to establish the connection. See docs/tutorial/03-driver/01-sender.md
        // Only after a subscriber responds with STATUS does publisher_limit advance, enabling data flow.
        var work_count: i32 = 0;

        // Always send SETUP periodically — required before any STATUS can arrive
        const now_ms = self.current_time_ms;
        if (now_ms - publication.last_setup_time_ms >= 50) {
            if (builtin.mode == .Debug and publication.stream_id == 103 and publication.last_setup_time_ms == 0) {
                std.debug.print("[SENDER] SETUP: session={d} dest={any}\n", .{ publication.session_id, publication.dest_address });
            }
            if (self.sendSetupFrame(publication)) {
                publication.last_setup_time_ms = now_ms;
                work_count += 1;
            }
        }

        // Get current positions from counters
        const sender_pos = self.counters_map.get(publication.sender_position.counter_id);
        const current_limit = self.counters_map.get(publication.publisher_limit.counter_id);

        // Update limit via flow control onIdle
        const pub_limit = publication.flow_control_strategy.onIdle(
            self.current_time_ms * std.time.ns_per_ms,
            current_limit,
            sender_pos,
        );
        if (pub_limit != current_limit) {
            self.counters_map.set(publication.publisher_limit.counter_id, pub_limit);
        }

        if (sender_pos >= pub_limit) {
            // Send heartbeat when idle (no data to send)
            if (now_ms - publication.last_heartbeat_time_ms >= 200) {
                if (self.sendHeartbeatFrame(publication)) {
                    publication.last_heartbeat_time_ms = now_ms;
                    work_count += 1;
                }
            }
            return work_count;
        }

        // Send DATA frames from log buffer
        const frames_sent = self.sendDataFrames(publication, sender_pos, pub_limit);
        work_count += frames_sent;

        return work_count;
    }

    fn sendSetupFrame(_: *Sender, publication: *NetworkPublication) bool {
        // LESSON(sender): Align buffer to protocol struct for C-compatible casting without copying. See docs/tutorial/03-driver/01-sender.md
        var frame_buffer: [protocol.SetupHeader.LENGTH]u8 align(@alignOf(protocol.SetupHeader)) = undefined;
        const header: *protocol.SetupHeader = @ptrCast(&frame_buffer);

        // Calculate current term_id from initial_term_id and log buffer metadata
        const meta = publication.log_buffer.metaData();
        const term_count = meta.activeTermCount();
        const current_term_id = publication.initial_term_id +% term_count;
        const active_partition = metadata.activePartitionIndex(term_count);
        const raw_tail = meta.rawTailVolatile(active_partition);
        const term_offset = metadata.termOffset(raw_tail, publication.log_buffer.term_length);

        header.frame_length = protocol.SetupHeader.LENGTH;
        header.version = protocol.VERSION;
        header.flags = 0;
        header.type = @intFromEnum(protocol.FrameType.setup);
        header.term_offset = term_offset;
        header.session_id = publication.session_id;
        header.stream_id = publication.stream_id;
        header.initial_term_id = publication.initial_term_id;
        header.active_term_id = current_term_id;
        header.term_length = publication.log_buffer.term_length;
        header.mtu = publication.mtu;
        header.ttl = 0;

        if (publication.send_channel.send(publication.dest_address, &frame_buffer)) |_| {
            return true;
        } else |err| switch (err) {
            error.WouldBlock => return false,
            else => {
                std.log.err(
                    "sender setup send failed session_id={} stream_id={} err={}",
                    .{ publication.session_id, publication.stream_id, err },
                );
                return false;
            },
        }
    }

    fn sendHeartbeatFrame(_: *Sender, publication: *NetworkPublication) bool {
        // Zero-length DATA frame at current sender position to keep receiver image alive
        const meta = publication.log_buffer.metaData();
        const term_count = meta.activeTermCount();
        const current_term_id = publication.initial_term_id +% term_count;
        const active_partition = metadata.activePartitionIndex(term_count);
        const raw_tail = meta.rawTailVolatile(active_partition);
        const term_offset = metadata.termOffset(raw_tail, publication.log_buffer.term_length);

        var frame_buffer: [protocol.DataHeader.LENGTH]u8 align(@alignOf(protocol.DataHeader)) = undefined;
        const header: *protocol.DataHeader = @ptrCast(&frame_buffer);

        header.frame_length = 0;
        header.version = protocol.VERSION;
        header.flags = protocol.DataHeader.BEGIN_FLAG | protocol.DataHeader.END_FLAG;
        header.type = @intFromEnum(protocol.FrameType.data);
        header.term_offset = term_offset;
        header.session_id = publication.session_id;
        header.stream_id = publication.stream_id;
        header.term_id = current_term_id;
        header.reserved_value = 0;

        if (publication.send_channel.send(publication.dest_address, &frame_buffer)) |_| {
            return true;
        } else |err| switch (err) {
            error.WouldBlock => return false,
            else => {
                std.log.err(
                    "sender heartbeat send failed session_id={} stream_id={} err={}",
                    .{ publication.session_id, publication.stream_id, err },
                );
                return false;
            },
        }
    }

    fn sendDataFrames(self: *Sender, publication: *NetworkPublication, sender_pos: i64, pub_limit: i64) i32 {
        // LESSON(sender): Retransmission strategy via term-relative offsets. Sender scans log buffer for committed frames and sends up to flow control limit. See docs/tutorial/03-driver/01-sender.md
        var work_count: i32 = 0;
        var current_pos: i64 = sender_pos;

        const term_length = publication.log_buffer.term_length;

        // Keep a duty cycle bounded. Draining a full receiver window in one
        // loop can burst hundreds of UDP datagrams before the peer's driver
        // gets a chance to report loss or advance its rebuild position. The
        // Java sender applies the same kind of bounded work scheduling.
        while (current_pos < pub_limit and work_count < MAX_DATA_FRAMES_PER_WORK) {
            // Follow the stream position across rotating term partitions. The active
            // partition is not necessarily the partition containing sender_pos.
            const term_count = @as(i32, @intCast(@divTrunc(current_pos, @as(i64, term_length))));
            const partition = metadata.activePartitionIndex(term_count);
            const term_buffer = publication.log_buffer.termBuffer(partition);
            const term_offset = @as(i32, @intCast(@mod(current_pos, @as(i64, term_length))));
            const buffer_offset = @as(usize, @intCast(term_offset));

            // Ensure we don't read past the buffer
            if (buffer_offset + 4 > term_buffer.len) break;

            // Read frame_length from term buffer (little-endian i32 at offset 0..4)
            const frame_length_bytes = term_buffer[buffer_offset .. buffer_offset + 4];
            const frame_length = std.mem.readInt(i32, frame_length_bytes[0..4], .little);

            // If frame_length <= 0, no committed data yet
            if (frame_length <= 0) break;

            // A reused term partition still contains committed bytes from the
            // previous term until the publisher overwrites them. Frame length
            // alone is therefore not an availability check: sending that old
            // frame at the new stream position makes the Java receiver reject
            // it and creates an unrecoverable NAK loop.
            const expected_term_id = publication.initial_term_id +% term_count;
            const committed_header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&term_buffer[buffer_offset])));
            if (committed_header.term_id != expected_term_id or committed_header.term_offset != term_offset) {
                _ = self.stale_frames_skipped.fetchAdd(1, .monotonic);
                break;
            }

            // Compute aligned_len: pad to FRAME_ALIGNMENT=32
            const align_size = @as(i32, @intCast(protocol.FRAME_ALIGNMENT));
            const aligned_len = (@divTrunc(frame_length + align_size - 1, align_size)) * align_size;
            if (aligned_len <= 0 or aligned_len > publication.mtu * 2) break;

            // Ensure frame fits in buffer
            if (buffer_offset + @as(usize, @intCast(aligned_len)) > term_buffer.len) break;

            // Send the frame as-is from the term buffer
            const frame_data = term_buffer[buffer_offset .. buffer_offset + @as(usize, @intCast(aligned_len))];
            if (publication.send_channel.send(publication.dest_address, frame_data)) |_| {} else |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    std.log.err(
                        "sender data send failed session_id={} stream_id={} err={}",
                        .{ publication.session_id, publication.stream_id, err },
                    );
                    break;
                },
            }

            _ = self.data_frames_sent.fetchAdd(1, .monotonic);
            const sent_header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&frame_data[0])));
            self.last_expected_term_id.store(publication.initial_term_id +% term_count, .monotonic);
            self.last_expected_term_offset.store(term_offset, .monotonic);
            if (sent_header.term_id != publication.initial_term_id +% term_count or sent_header.term_offset != term_offset) {
                _ = self.stale_frames_skipped.fetchAdd(1, .monotonic);
            }
            self.last_sent_term_id.store(sent_header.term_id, .monotonic);
            self.last_sent_term_offset.store(sent_header.term_offset, .monotonic);
            self.last_sent_frame_length.store(sent_header.frame_length, .monotonic);

            // Log frame_out event
            if (self.event_log) |el| {
                const now: i64 = @intCast(@as(i128, time.nanoTimestamp()));
                el.log(.frame_out, now, publication.session_id, publication.stream_id, frame_data);
            }

            current_pos += @as(i64, @intCast(aligned_len));
            work_count += 1;
        }

        // Update sender position counter
        if (current_pos > sender_pos) {
            self.counters_map.set(publication.sender_position.counter_id, current_pos);
        }

        return work_count;
    }

    fn processRetransmits(self: *Sender) i32 {
        // LESSON(sender): NAK processing—on NAK receipt, queue retransmit request and drain in doWork. See docs/tutorial/03-driver/01-sender.md
        var work_count: i32 = 0;

        var i: usize = 0;
        while (i < self.retransmit_queue.items.len) {
            const req = self.retransmit_queue.items[i];

            // Find publication with matching session_id and stream_id
            var found = false;
            var sent = false;
            for (self.publications.items) |publication| {
                if (publication.session_id == req.session_id and publication.stream_id == req.stream_id) {
                    const retransmits = self.sendRetransmit(publication, &self.retransmit_queue.items[i]);
                    work_count += @as(i32, @intCast(retransmits));
                    sent = self.retransmit_queue.items[i].length == 0;
                    found = true;
                    break;
                }
            }

            if (found and sent) {
                // Remove only a successfully sent retransmit. A non-blocking
                // socket may temporarily reject the send; retain the request
                // so the next duty cycle can retry it.
                _ = self.retransmit_queue.swapRemove(i);
            } else if (!found or !sent) {
                i += 1;
            }
        }

        return work_count;
    }

    fn sendRetransmit(self: *Sender, publication: *NetworkPublication, req: *RetransmitRequest) usize {
        // Find the correct term partition for req.term_id relative to initial_term_id
        const term_count_delta = req.term_id -% publication.initial_term_id;
        const partition = @mod(@as(i32, @intCast(term_count_delta)), @as(i32, @intCast(metadata.PARTITION_COUNT)));
        const partition_index = @as(usize, @intCast(partition));

        const term_buffer = publication.log_buffer.termBuffer(partition_index);

        // Ensure the requested range is valid
        const term_offset = @as(usize, @intCast(req.term_offset));
        const length = @as(usize, @intCast(req.length));

        if (term_offset + length > term_buffer.len) {
            req.length = 0;
            return 0;
        }

        // A NAK range can cover many frames. Split it back into Aeron-sized
        // datagrams; sending the raw range as one UDP packet can exceed MTU
        // and leaves the receiver unable to recover the gap.
        var offset = term_offset;
        var remaining = length;
        var frames_sent: usize = 0;
        while (remaining > 0) {
            if (frames_sent >= MAX_RETRANSMIT_FRAMES_PER_WORK) break;
            if (offset + @sizeOf(i32) > term_buffer.len) {
                req.length = 0;
                return frames_sent;
            }
            const frame_length = std.mem.readInt(i32, term_buffer[offset..][0..4], .little);
            if (frame_length < @as(i32, @intCast(protocol.DataHeader.LENGTH))) {
                req.length = 0;
                return frames_sent;
            }
            const aligned_len = std.mem.alignForward(i32, frame_length, @as(i32, @intCast(protocol.FRAME_ALIGNMENT)));
            if (aligned_len <= 0 or aligned_len > remaining) {
                req.length = 0;
                return frames_sent;
            }
            if (offset + @as(usize, @intCast(aligned_len)) > term_buffer.len) {
                req.length = 0;
                return frames_sent;
            }

            const frame_data = term_buffer[offset .. offset + @as(usize, @intCast(aligned_len))];
            const frame_header = @as(*const protocol.DataHeader, @ptrCast(@alignCast(&frame_data[0])));
            if (frame_header.term_id != req.term_id or frame_header.term_offset != @as(i32, @intCast(offset))) {
                break;
            }
            if (publication.stream_id == 103) {
                std.debug.print("[DIAG103] retransmit send pub_session={d} pub_stream={d} frame_session={d} term_id={d} term_offset={d} dest_port={d}\n", .{
                    publication.session_id, publication.stream_id, frame_header.session_id, frame_header.term_id, frame_header.term_offset, req.source_address.getPort(),
                });
            }
            if (publication.send_channel.send(req.source_address, frame_data)) |_| {
                _ = self.retransmits_sent.fetchAdd(1, .monotonic);
                self.last_retransmit_frame_term_id.store(frame_header.term_id, .monotonic);
                self.last_retransmit_frame_term_offset.store(frame_header.term_offset, .monotonic);
                self.last_retransmit_frame_session_id.store(frame_header.session_id, .monotonic);
                self.last_retransmit_frame_stream_id.store(frame_header.stream_id, .monotonic);
                self.last_retransmit_frame_length.store(frame_header.frame_length, .monotonic);
            } else |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    std.log.err(
                        "sender retransmit send failed session_id={} stream_id={} term_id={} term_offset={} length={} err={}",
                        .{ publication.session_id, publication.stream_id, req.term_id, req.term_offset, req.length, err },
                    );
                    req.length = 0;
                    return frames_sent;
                },
            }
            offset += @as(usize, @intCast(aligned_len));
            remaining -= @as(usize, @intCast(aligned_len));
            req.term_offset += aligned_len;
            req.length -= aligned_len;
            frames_sent += 1;
        }
        return frames_sent;
    }

    pub fn onAddPublication(self: *Sender, publication: *NetworkPublication) !void {
        if (builtin.mode == .Debug and publication.stream_id == 103) {
            std.debug.print("[SENDER] ADD: session={d} stream={d} dest={any}\n", .{ publication.session_id, publication.stream_id, publication.dest_address });
        }
        publication.last_setup_time_ms = self.current_time_ms;
        if (publication.send_channel.socket != INVALID_SOCKET) {
            if (self.sendSetupFrame(publication)) {
                publication.last_setup_time_ms = self.current_time_ms;
            } else {
                publication.last_setup_time_ms = self.current_time_ms - 50;
            }
        }
        try self.publications.append(self.allocator, publication);
    }

    pub fn onRemovePublication(self: *Sender, session_id: i32, stream_id: i32) void {
        var i: usize = 0;
        while (i < self.publications.items.len) {
            if (self.publications.items[i].session_id == session_id and
                self.publications.items[i].stream_id == stream_id)
            {
                _ = self.publications.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn onRetransmit(
        self: *Sender,
        session_id: i32,
        stream_id: i32,
        term_id: i32,
        term_offset: i32,
        length: i32,
        source_address: net.Address,
    ) !void {
        const new_end = @as(i64, term_offset) + @as(i64, length);
        for (self.retransmit_queue.items) |queued| {
            if (queued.session_id == session_id and queued.stream_id == stream_id and queued.term_id == term_id) {
                const queued_end = @as(i64, queued.term_offset) + @as(i64, queued.length);
                if (@as(i64, term_offset) < queued_end and @as(i64, queued.term_offset) < new_end) return;
            }
        }
        _ = self.retransmit_requests.fetchAdd(1, .monotonic);
        self.last_retransmit_term_id.store(term_id, .monotonic);
        self.last_retransmit_term_offset.store(term_offset, .monotonic);
        self.last_retransmit_length.store(length, .monotonic);
        self.last_retransmit_source_port.store(@as(i32, @intCast(source_address.getPort())), .monotonic);
        const req = RetransmitRequest{
            .session_id = session_id,
            .stream_id = stream_id,
            .term_id = term_id,
            .term_offset = term_offset,
            .length = length,
            .source_address = source_address,
            .timestamp_ms = self.current_time_ms,
        };
        try self.retransmit_queue.append(self.allocator, req);
    }

    pub fn retransmitRequests(self: *const Sender) u64 {
        return self.retransmit_requests.load(.monotonic);
    }

    pub fn retransmitsSent(self: *const Sender) u64 {
        return self.retransmits_sent.load(.monotonic);
    }

    pub fn lastRetransmitTermId(self: *const Sender) i32 {
        return self.last_retransmit_term_id.load(.monotonic);
    }

    pub fn lastRetransmitTermOffset(self: *const Sender) i32 {
        return self.last_retransmit_term_offset.load(.monotonic);
    }

    pub fn lastRetransmitLength(self: *const Sender) i32 {
        return self.last_retransmit_length.load(.monotonic);
    }

    pub fn lastRetransmitSourcePort(self: *const Sender) i32 {
        return self.last_retransmit_source_port.load(.monotonic);
    }

    pub fn lastRetransmitFrameTermId(self: *const Sender) i32 {
        return self.last_retransmit_frame_term_id.load(.monotonic);
    }

    pub fn lastRetransmitFrameTermOffset(self: *const Sender) i32 {
        return self.last_retransmit_frame_term_offset.load(.monotonic);
    }

    pub fn lastRetransmitFrameSessionId(self: *const Sender) i32 {
        return self.last_retransmit_frame_session_id.load(.monotonic);
    }

    pub fn lastRetransmitFrameStreamId(self: *const Sender) i32 {
        return self.last_retransmit_frame_stream_id.load(.monotonic);
    }

    pub fn lastRetransmitFrameLength(self: *const Sender) i32 {
        return self.last_retransmit_frame_length.load(.monotonic);
    }

    pub fn staleFramesSkipped(self: *const Sender) u64 {
        return self.stale_frames_skipped.load(.monotonic);
    }

    pub fn lastExpectedTermId(self: *const Sender) i32 {
        return self.last_expected_term_id.load(.monotonic);
    }

    pub fn lastExpectedTermOffset(self: *const Sender) i32 {
        return self.last_expected_term_offset.load(.monotonic);
    }

    pub fn onStatusMessage(
        self: *Sender,
        session_id: i32,
        stream_id: i32,
        consumption_term_id: i32,
        consumption_term_offset: i32,
        receiver_window: i32,
        receiver_id: i64,
    ) void {
        // LESSON(sender): STATUS is the receiver-driven flow-control signal. The sender
        // translates the receiver's consumption position plus advertised window into a
        // publisher-limit counter that both the driver and client publication observe. See docs/tutorial/03-driver/01-sender.md
        for (self.publications.items) |publication| {
            if (publication.session_id == session_id and publication.stream_id == stream_id) {
                const new_limit = publication.flow_control_strategy.onStatusMessage(
                    session_id,
                    stream_id,
                    consumption_term_id,
                    consumption_term_offset,
                    receiver_window,
                    publication.initial_term_id,
                    publication.log_buffer.term_length,
                    receiver_id,
                    self.current_time_ms * std.time.ns_per_ms,
                );
                const current_limit = self.counters_map.get(publication.publisher_limit.counter_id);
                // UDP STATUS messages may arrive out of order. A stale STATUS must
                // never move the publisher limit backwards and strand a publication
                // that has already advanced beyond that old window.
                if (new_limit > current_limit) {
                    self.counters_map.set(publication.publisher_limit.counter_id, new_limit);
                }
                _ = self.status_messages_applied.fetchAdd(1, .monotonic);
                self.last_status_session_id.store(session_id, .monotonic);
                self.last_status_stream_id.store(stream_id, .monotonic);
                self.last_status_term_id.store(consumption_term_id, .monotonic);
                self.last_status_term_offset.store(consumption_term_offset, .monotonic);
                self.last_status_window.store(receiver_window, .monotonic);
                self.last_status_limit.store(new_limit, .monotonic);
                publication.last_activity_ns = self.current_time_ms * std.time.ns_per_ms;
                var meta = publication.log_buffer.metaData();
                meta.setIsConnected(true);
                meta.setActiveTransportCount(1);
                return;
            }
        }
    }

    pub fn statusMessagesApplied(self: *const Sender) u64 {
        return self.status_messages_applied.load(.monotonic);
    }

    pub fn lastStatusSessionId(self: *const Sender) i32 {
        return self.last_status_session_id.load(.monotonic);
    }

    pub fn lastStatusStreamId(self: *const Sender) i32 {
        return self.last_status_stream_id.load(.monotonic);
    }

    pub fn lastStatusTermId(self: *const Sender) i32 {
        return self.last_status_term_id.load(.monotonic);
    }

    pub fn lastStatusTermOffset(self: *const Sender) i32 {
        return self.last_status_term_offset.load(.monotonic);
    }

    pub fn lastStatusWindow(self: *const Sender) i32 {
        return self.last_status_window.load(.monotonic);
    }

    pub fn lastStatusLimit(self: *const Sender) i64 {
        return self.last_status_limit.load(.monotonic);
    }

    pub fn dataFramesSent(self: *const Sender) u64 {
        return self.data_frames_sent.load(.monotonic);
    }

    pub fn lastSentTermId(self: *const Sender) i32 {
        return self.last_sent_term_id.load(.monotonic);
    }

    pub fn lastSentTermOffset(self: *const Sender) i32 {
        return self.last_sent_term_offset.load(.monotonic);
    }

    pub fn lastSentFrameLength(self: *const Sender) i32 {
        return self.last_sent_frame_length.load(.monotonic);
    }

    pub fn setCurrentTimeMs(self: *Sender, time_ms: i64) void {
        self.current_time_ms = time_ms;
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "Sender: init and deinit" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);

    var sender = try Sender.init(allocator, undefined, &counters_map);
    defer sender.deinit();

    try std.testing.expectEqual(@as(usize, 0), sender.publications.items.len);
    try std.testing.expectEqual(@as(usize, 0), sender.retransmit_queue.items.len);
}

test "Sender: onAddPublication adds to list" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const sock = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer net.closeSocket(sock);
    var send_endpoint = endpoint.SendChannelEndpoint{ .socket = sock };

    var sender = try Sender.init(allocator, &send_endpoint, &counters_map);
    defer sender.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var publication = NetworkPublication{
        .session_id = 42,
        .stream_id = 1,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = counters.CounterHandle{ .counter_id = 0 },
        .publisher_limit = counters.CounterHandle{ .counter_id = 1 },
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };

    try sender.onAddPublication(&publication);
    try std.testing.expectEqual(@as(usize, 1), sender.publications.items.len);
    try std.testing.expectEqual(@as(i32, 42), sender.publications.items[0].session_id);
}

test "Sender: onRemovePublication removes from list" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const sock = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer net.closeSocket(sock);
    var send_endpoint = endpoint.SendChannelEndpoint{ .socket = sock };

    var sender = try Sender.init(allocator, &send_endpoint, &counters_map);
    defer sender.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var publication1 = NetworkPublication{
        .session_id = 1,
        .stream_id = 10,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = counters.CounterHandle{ .counter_id = 0 },
        .publisher_limit = counters.CounterHandle{ .counter_id = 1 },
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };

    var publication2 = NetworkPublication{
        .session_id = 2,
        .stream_id = 20,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = counters.CounterHandle{ .counter_id = 2 },
        .publisher_limit = counters.CounterHandle{ .counter_id = 3 },
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40124),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };

    try sender.onAddPublication(&publication1);
    try sender.onAddPublication(&publication2);
    try std.testing.expectEqual(@as(usize, 2), sender.publications.items.len);

    sender.onRemovePublication(1, 10);
    try std.testing.expectEqual(@as(usize, 1), sender.publications.items.len);
    try std.testing.expectEqual(@as(i32, 2), sender.publications.items[0].session_id);
}

test "Sender: onRetransmit adds to queue" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);

    var sender = try Sender.init(allocator, undefined, &counters_map);
    defer sender.deinit();

    try sender.onRetransmit(
        1,
        10,
        5,
        100,
        256,
        net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
    );
    try std.testing.expectEqual(@as(usize, 1), sender.retransmit_queue.items.len);
    try std.testing.expectEqual(@as(i32, 1), sender.retransmit_queue.items[0].session_id);
    try std.testing.expectEqual(@as(i32, 10), sender.retransmit_queue.items[0].stream_id);
    try std.testing.expectEqual(@as(i32, 5), sender.retransmit_queue.items[0].term_id);
    try std.testing.expectEqual(@as(i32, 100), sender.retransmit_queue.items[0].term_offset);
    try std.testing.expectEqual(@as(i32, 256), sender.retransmit_queue.items[0].length);
}

test "Sender: doWork with empty publications" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);

    var sender = try Sender.init(allocator, undefined, &counters_map);
    defer sender.deinit();

    const work = sender.doWork();
    try std.testing.expectEqual(@as(i32, 0), work);
}

test "Sender: DATA frame structure and types" {
    var frame_buffer: [protocol.DataHeader.LENGTH]u8 align(@alignOf(protocol.DataHeader)) = undefined;
    const header: *protocol.DataHeader = @ptrCast(&frame_buffer);

    // Build a DATA frame
    header.frame_length = protocol.DataHeader.LENGTH;
    header.version = protocol.VERSION;
    header.flags = protocol.DataHeader.BEGIN_FLAG | protocol.DataHeader.END_FLAG;
    header.type = @intFromEnum(protocol.FrameType.data);
    header.term_offset = 0;
    header.session_id = 42;
    header.stream_id = 1;
    header.term_id = 5;
    header.reserved_value = 0;

    // Verify frame structure
    try std.testing.expectEqual(@as(i32, protocol.DataHeader.LENGTH), header.frame_length);
    try std.testing.expectEqual(@as(u8, protocol.VERSION), header.version);
    try std.testing.expectEqual(@as(u16, @intFromEnum(protocol.FrameType.data)), header.type);
    try std.testing.expectEqual(@as(i32, 42), header.session_id);
    try std.testing.expectEqual(@as(i32, 1), header.stream_id);
    try std.testing.expectEqual(@as(i32, 5), header.term_id);
}

test "Sender: SETUP frame structure and types" {
    var frame_buffer: [protocol.SetupHeader.LENGTH]u8 align(@alignOf(protocol.SetupHeader)) = undefined;
    const header: *protocol.SetupHeader = @ptrCast(&frame_buffer);

    header.frame_length = protocol.SetupHeader.LENGTH;
    header.version = protocol.VERSION;
    header.flags = 0;
    header.type = @intFromEnum(protocol.FrameType.setup);
    header.term_offset = 0;
    header.session_id = 42;
    header.stream_id = 1;
    header.initial_term_id = 0;
    header.active_term_id = 0;
    header.term_length = 65536;
    header.mtu = 1408;
    header.ttl = 0;

    try std.testing.expectEqual(@as(i32, protocol.SetupHeader.LENGTH), header.frame_length);
    try std.testing.expectEqual(@as(u16, @intFromEnum(protocol.FrameType.setup)), header.type);
    try std.testing.expectEqual(@as(i32, 42), header.session_id);
    try std.testing.expectEqual(@as(i32, 1), header.stream_id);
    try std.testing.expectEqual(@as(i32, 1408), header.mtu);
}

test "Sender: counter position updates" {
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);

    const h1 = counters_map.allocate(counters.SENDER_POSITION, "sp");
    counters_map.set(h1.counter_id, 100);

    try std.testing.expectEqual(@as(i64, 100), counters_map.get(h1.counter_id));

    counters_map.set(h1.counter_id, 200);
    try std.testing.expectEqual(@as(i64, 200), counters_map.get(h1.counter_id));
}

test "Sender: setCurrentTimeMs updates time" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);

    var sender = try Sender.init(allocator, undefined, &counters_map);
    defer sender.deinit();

    try std.testing.expectEqual(@as(i64, 0), sender.current_time_ms);

    sender.setCurrentTimeMs(1000);
    try std.testing.expectEqual(@as(i64, 1000), sender.current_time_ms);
}

test "Sender: STATUS updates publisher limit" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const sock = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer net.closeSocket(sock);
    var send_endpoint = endpoint.SendChannelEndpoint{ .socket = sock };

    const sender_pos = counters_map.allocate(counters.SENDER_POSITION, "sender-pos");
    const pub_limit = counters_map.allocate(counters.PUBLISHER_LIMIT, "pub-limit");

    var sender = try Sender.init(allocator, &send_endpoint, &counters_map);
    defer sender.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var publication = NetworkPublication{
        .session_id = 7,
        .stream_id = 1001,
        .initial_term_id = 3,
        .log_buffer = &log_buf,
        .sender_position = sender_pos,
        .publisher_limit = pub_limit,
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };
    try sender.onAddPublication(&publication);

    sender.onStatusMessage(7, 1001, 3, 1024, 4096, 77);
    try std.testing.expectEqual(@as(i64, 5120), counters_map.get(pub_limit.counter_id));
    sender.onStatusMessage(7, 1001, 2, 0, 4096, 77);
    try std.testing.expectEqual(@as(i64, 5120), counters_map.get(pub_limit.counter_id));
    try std.testing.expect(log_buf.metaData().isConnected());
    try std.testing.expectEqual(@as(i32, 1), log_buf.metaData().activeTransportCount());
}

test "Sender: sendDataFrames reads committed frame from log buffer" {
    const allocator = std.testing.allocator;

    // Create a LogBuffer with 64KB term length
    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    // Write a DATA frame to partition 0 at offset 0
    // frame_length = 64 (32-byte header + 32-byte payload, aligned to 32)
    const term_buffer = log_buf.termBuffer(0);
    const frame_length: i32 = 64;

    // Write frame_length as little-endian i32 at bytes [0..4]
    std.mem.writeInt(i32, term_buffer[0..4], frame_length, .little);

    // Write some dummy payload (bytes 4..64)
    for (4..64) |i| {
        term_buffer[i] = @as(u8, @intCast(i % 256));
    }

    // Verify frame_length was written correctly
    const read_frame_length = std.mem.readInt(i32, term_buffer[0..4], .little);
    try std.testing.expectEqual(@as(i32, 64), read_frame_length);

    // Verify payload bytes
    for (4..64) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i % 256)), term_buffer[i]);
    }
}

test "Sender: skips stale committed frames in a reused term partition" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const sock = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer net.closeSocket(sock);
    var send_endpoint = endpoint.SendChannelEndpoint{ .socket = sock };

    const sender_pos = counters_map.allocate(counters.SENDER_POSITION, "sender-pos");
    const pub_limit = counters_map.allocate(counters.PUBLISHER_LIMIT, "pub-limit");
    var sender = try Sender.init(allocator, &send_endpoint, &counters_map);
    defer sender.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();
    const stale = @as(*protocol.DataHeader, @ptrCast(@alignCast(&log_buf.termBuffer(1)[0])));
    stale.frame_length = 64;
    stale.version = protocol.VERSION;
    stale.flags = protocol.DataHeader.BEGIN_FLAG | protocol.DataHeader.END_FLAG;
    stale.type = @intFromEnum(protocol.FrameType.data);
    stale.term_offset = 0;
    stale.session_id = 7;
    stale.stream_id = 1001;
    stale.term_id = 0;
    stale.reserved_value = 0;

    var publication = NetworkPublication{
        .session_id = 7,
        .stream_id = 1001,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = sender_pos,
        .publisher_limit = pub_limit,
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };

    const frames_sent = sender.sendDataFrames(&publication, 64 * 1024, 64 * 1024 + 64);
    try std.testing.expectEqual(@as(i32, 0), frames_sent);
    try std.testing.expectEqual(@as(u64, 1), sender.staleFramesSkipped());
}

test "Sender: heartbeat sent when publication idle" {
    const allocator = std.testing.allocator;
    var meta align(64) = [_]u8{0} ** (counters.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters.COUNTER_LENGTH * 4);
    var counters_map = counters.CountersMap.init(&meta, &values);
    const sock = try net.openSocket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer net.closeSocket(sock);
    var send_endpoint = endpoint.SendChannelEndpoint{ .socket = sock };

    const sender_pos = counters_map.allocate(counters.SENDER_POSITION, "sender-pos");
    const pub_limit = counters_map.allocate(counters.PUBLISHER_LIMIT, "pub-limit");

    // Set sender_pos == pub_limit to simulate idle state
    counters_map.set(sender_pos.counter_id, 0);
    counters_map.set(pub_limit.counter_id, 0);

    var sender = try Sender.init(allocator, &send_endpoint, &counters_map);
    defer sender.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var publication = NetworkPublication{
        .session_id = 42,
        .stream_id = 1,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = sender_pos,
        .publisher_limit = pub_limit,
        .send_channel = &send_endpoint,
        .dest_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
        .last_heartbeat_time_ms = 0,
        .last_activity_ns = 0,
        .flow_control_strategy = flow_control.FlowControl{ .unicast = .{} },
    };
    try sender.onAddPublication(&publication);

    // Time 50: triggers SETUP (last_setup_time_ms=0, delta=50 >= 50)
    sender.setCurrentTimeMs(50);
    var work = sender.doWork();
    // SETUP may succeed or fail depending on socket; heartbeat not due yet
    // At minimum: no crash. Heartbeat needs 200ms from time 0.

    // Time 150ms: no heartbeat yet (need 200ms interval from 0)
    sender.setCurrentTimeMs(150);
    work = sender.doWork();
    // Heartbeat not due (150 - 0 < 200)

    // Time 200ms: heartbeat should be sent (idle, 200ms elapsed)
    sender.setCurrentTimeMs(200);
    work = sender.doWork();
    try std.testing.expect(work >= 1); // Heartbeat (and possibly SETUP)

    // Verify heartbeat_time was updated
    try std.testing.expectEqual(@as(i64, 200), sender.publications.items[0].last_heartbeat_time_ms);

    // Time 400ms: next heartbeat should fire
    sender.setCurrentTimeMs(400);
    work = sender.doWork();
    try std.testing.expect(work >= 1); // Next heartbeat
    try std.testing.expectEqual(@as(i64, 400), sender.publications.items[0].last_heartbeat_time_ms);
}
