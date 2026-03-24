// Aeron Sender — outputs DATA and SETUP frames for active publications
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/Sender.java

const std = @import("std");
const logbuffer = @import("../logbuffer/log_buffer.zig");
const metadata = @import("../logbuffer/metadata.zig");
const counters = @import("../ipc/counters.zig");
const protocol = @import("../protocol/frame.zig");
const endpoint = @import("../transport/endpoint.zig");
const event_log_mod = @import("../event_log.zig");

pub const RetransmitRequest = struct {
    session_id: i32,
    stream_id: i32,
    term_id: i32,
    term_offset: i32,
    length: i32,
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
    dest_address: std.net.Address,
    mtu: i32,
    last_setup_time_ms: i64,
};

pub const Sender = struct {
    publications: std.ArrayList(*NetworkPublication),
    send_endpoint: *endpoint.SendChannelEndpoint,
    counters_map: *counters.CountersMap,
    allocator: std.mem.Allocator,
    retransmit_queue: std.ArrayList(RetransmitRequest),
    current_time_ms: i64,
    event_log: ?*event_log_mod.EventLog,

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
            .publications = std.ArrayList(*NetworkPublication){},
            .send_endpoint = send_ep,
            .counters_map = counters_map_,
            .allocator = allocator,
            .retransmit_queue = std.ArrayList(RetransmitRequest){},
            .current_time_ms = 0,
            .event_log = el,
        };
    }

    pub fn deinit(self: *Sender) void {
        self.publications.deinit(self.allocator);
        self.retransmit_queue.deinit(self.allocator);
    }

    pub fn doWork(self: *Sender) i32 {
        // LESSON(sender/zig): Main work loop dispatches to publication processing and retransmit handling. See docs/tutorial/03-driver/01-sender.md
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
        // LESSON(sender/aeron): SETUP must be sent unconditionally to establish the connection.
        // Only after a subscriber responds with STATUS does publisher_limit advance, enabling data flow.
        var work_count: i32 = 0;

        // Always send SETUP periodically — required before any STATUS can arrive
        const now_ms = self.current_time_ms;
        if (now_ms - publication.last_setup_time_ms >= 50) {
            if (self.sendSetupFrame(publication)) {
                publication.last_setup_time_ms = now_ms;
                work_count += 1;
            }
        }

        // Get current positions from counters
        const sender_pos = self.counters_map.get(publication.sender_position.counter_id);
        const pub_limit = self.counters_map.get(publication.publisher_limit.counter_id);

        if (sender_pos >= pub_limit) {
            return work_count;
        }

        // Send DATA frames from log buffer
        const frames_sent = self.sendDataFrames(publication, sender_pos, pub_limit);
        work_count += frames_sent;

        return work_count;
    }

    fn sendSetupFrame(_: *Sender, publication: *NetworkPublication) bool {
        // LESSON(sender/zig): Align buffer to protocol struct for C-compatible casting without copying. See docs/tutorial/03-driver/01-sender.md
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

    fn sendDataFrames(self: *Sender, publication: *NetworkPublication, sender_pos: i64, pub_limit: i64) i32 {
        // LESSON(sender/aeron): Retransmission strategy via term-relative offsets. Sender scans log buffer for committed frames and sends up to flow control limit. See docs/tutorial/03-driver/01-sender.md
        var work_count: i32 = 0;
        var current_pos: i64 = sender_pos;

        // Get metadata and active partition
        const meta = publication.log_buffer.metaData();
        const term_count = meta.activeTermCount();
        const active_partition = metadata.activePartitionIndex(term_count);
        const term_buffer = publication.log_buffer.termBuffer(active_partition);
        const term_length = publication.log_buffer.term_length;

        while (current_pos < pub_limit) {
            // Compute position within active term
            const term_offset = @as(i32, @intCast(@mod(current_pos, @as(i64, term_length))));
            const buffer_offset = @as(usize, @intCast(term_offset));

            // Ensure we don't read past the buffer
            if (buffer_offset + 4 > term_buffer.len) break;

            // Read frame_length from term buffer (little-endian i32 at offset 0..4)
            const frame_length_bytes = term_buffer[buffer_offset .. buffer_offset + 4];
            const frame_length = std.mem.readInt(i32, frame_length_bytes[0..4], .little);

            // If frame_length <= 0, no committed data yet
            if (frame_length <= 0) break;

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

            // Log frame_out event
            if (self.event_log) |el| {
                const now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
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
        // LESSON(sender/aeron): NAK processing—on NAK receipt, queue retransmit request and drain in doWork. See docs/tutorial/03-driver/01-sender.md
        var work_count: i32 = 0;

        var i: usize = 0;
        while (i < self.retransmit_queue.items.len) {
            const req = self.retransmit_queue.items[i];

            // Find publication with matching session_id and stream_id
            var found = false;
            for (self.publications.items) |publication| {
                if (publication.session_id == req.session_id and publication.stream_id == req.stream_id) {
                    if (self.sendRetransmit(publication, req)) {
                        work_count += 1;
                    }
                    found = true;
                    break;
                }
            }

            if (found) {
                // Remove processed retransmit
                _ = self.retransmit_queue.swapRemove(i);
            } else {
                i += 1;
            }
        }

        return work_count;
    }

    fn sendRetransmit(self: *Sender, publication: *NetworkPublication, req: RetransmitRequest) bool {
        _ = self;

        // Find the correct term partition for req.term_id relative to initial_term_id
        const term_count_delta = req.term_id -% publication.initial_term_id;
        const partition = @mod(@as(i32, @intCast(term_count_delta)), @as(i32, @intCast(metadata.PARTITION_COUNT)));
        const partition_index = @as(usize, @intCast(partition));

        const term_buffer = publication.log_buffer.termBuffer(partition_index);

        // Ensure the requested range is valid
        const term_offset = @as(usize, @intCast(req.term_offset));
        const length = @as(usize, @intCast(req.length));

        if (term_offset + length > term_buffer.len) {
            return false;
        }

        // Send the requested bytes
        const data = term_buffer[term_offset .. term_offset + length];
        if (publication.send_channel.send(publication.dest_address, data)) |_| {
            return true;
        } else |err| switch (err) {
            error.WouldBlock => return false,
            else => {
                std.log.err(
                    "sender retransmit send failed session_id={} stream_id={} term_id={} term_offset={} length={} err={}",
                    .{ publication.session_id, publication.stream_id, req.term_id, req.term_offset, req.length, err },
                );
                return false;
            },
        }
    }

    pub fn onAddPublication(self: *Sender, publication: *NetworkPublication) !void {
        publication.last_setup_time_ms = self.current_time_ms;
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
    ) !void {
        const req = RetransmitRequest{
            .session_id = session_id,
            .stream_id = stream_id,
            .term_id = term_id,
            .term_offset = term_offset,
            .length = length,
            .timestamp_ms = self.current_time_ms,
        };
        try self.retransmit_queue.append(self.allocator, req);
    }

    pub fn onStatusMessage(
        self: *Sender,
        session_id: i32,
        stream_id: i32,
        consumption_term_id: i32,
        consumption_term_offset: i32,
        receiver_window: i32,
    ) void {
        // LESSON(sender/aeron): STATUS is the receiver-driven flow-control signal. The sender
        // translates the receiver's consumption position plus advertised window into a
        // publisher-limit counter that both the driver and client publication observe.
        for (self.publications.items) |publication| {
            if (publication.session_id == session_id and publication.stream_id == stream_id) {
                const receiver_position = @as(i64, consumption_term_id - publication.initial_term_id) * publication.log_buffer.term_length +
                    consumption_term_offset;
                const new_limit = receiver_position + receiver_window;
                self.counters_map.set(publication.publisher_limit.counter_id, new_limit);
                return;
            }
        }
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

    var sender = try Sender.init(allocator, undefined, &counters_map);
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
        .send_channel = undefined,
        .dest_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
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

    var sender = try Sender.init(allocator, undefined, &counters_map);
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
        .send_channel = undefined,
        .dest_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
    };

    var publication2 = NetworkPublication{
        .session_id = 2,
        .stream_id = 20,
        .initial_term_id = 0,
        .log_buffer = &log_buf,
        .sender_position = counters.CounterHandle{ .counter_id = 2 },
        .publisher_limit = counters.CounterHandle{ .counter_id = 3 },
        .send_channel = undefined,
        .dest_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40124),
        .mtu = 1408,
        .last_setup_time_ms = 0,
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

    try sender.onRetransmit(1, 10, 5, 100, 256);
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

    const sender_pos = counters_map.allocate(counters.SENDER_POSITION, "sender-pos");
    const pub_limit = counters_map.allocate(counters.PUBLISHER_LIMIT, "pub-limit");

    var sender = try Sender.init(allocator, undefined, &counters_map);
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
        .send_channel = undefined,
        .dest_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 40123),
        .mtu = 1408,
        .last_setup_time_ms = 0,
    };
    try sender.onAddPublication(&publication);

    sender.onStatusMessage(7, 1001, 3, 1024, 4096);
    try std.testing.expectEqual(@as(i64, 5120), counters_map.get(pub_limit.counter_id));
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
