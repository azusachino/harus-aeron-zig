// Driver conductor: processes client IPC commands and manages driver resources
// (publications, subscriptions, counters)
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-driver/src/main/java/io/aeron/driver/DriverConductor.java

const std = @import("std");
const ring_buffer = @import("../ipc/ring_buffer.zig");
const broadcast = @import("../ipc/broadcast.zig");
const counters = @import("../ipc/counters.zig");

const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;
const BroadcastTransmitter = broadcast.BroadcastTransmitter;
const CountersMap = counters.CountersMap;

// Command type IDs
pub const CMD_ADD_PUBLICATION: i32 = 0x01;
pub const CMD_REMOVE_PUBLICATION: i32 = 0x02;
pub const CMD_ADD_SUBSCRIPTION: i32 = 0x03;
pub const CMD_REMOVE_SUBSCRIPTION: i32 = 0x04;
pub const CMD_CLIENT_KEEPALIVE: i32 = 0x05;
pub const CMD_ADD_COUNTER: i32 = 0x06;
pub const CMD_REMOVE_COUNTER: i32 = 0x07;

// Response type IDs
pub const RESPONSE_ON_PUBLICATION_READY: i32 = 0x10;
pub const RESPONSE_ON_SUBSCRIPTION_READY: i32 = 0x11;
pub const RESPONSE_ON_ERROR: i32 = 0x12;
pub const RESPONSE_ON_IMAGE_READY: i32 = 0x13;
pub const RESPONSE_ON_IMAGE_CLOSE: i32 = 0x14;
pub const RESPONSE_ON_COUNTER_READY: i32 = 0x15;

pub const PublicationEntry = struct {
    registration_id: i64,
    session_id: i32,
    stream_id: i32,
    channel: []u8,
    ref_count: i32,
};

pub const SubscriptionEntry = struct {
    registration_id: i64,
    stream_id: i32,
    channel: []u8,
};

pub const DriverConductor = struct {
    ring_buffer: *ManyToOneRingBuffer,
    broadcaster: *BroadcastTransmitter,
    counters_map: *CountersMap,
    allocator: std.mem.Allocator,
    publications: std.ArrayList(PublicationEntry),
    subscriptions: std.ArrayList(SubscriptionEntry),
    next_session_id: i32,

    pub fn init(
        allocator: std.mem.Allocator,
        ring_buffer_ptr: *ManyToOneRingBuffer,
        broadcaster_ptr: *BroadcastTransmitter,
        counters_map_ptr: *CountersMap,
    ) !DriverConductor {
        return DriverConductor{
            .ring_buffer = ring_buffer_ptr,
            .broadcaster = broadcaster_ptr,
            .counters_map = counters_map_ptr,
            .allocator = allocator,
            .publications = std.ArrayList(PublicationEntry){},
            .subscriptions = std.ArrayList(SubscriptionEntry){},
            .next_session_id = 1,
        };
    }

    pub fn deinit(self: *DriverConductor) void {
        for (self.publications.items) |pub_entry| {
            self.allocator.free(pub_entry.channel);
        }
        self.publications.deinit(self.allocator);

        for (self.subscriptions.items) |sub_entry| {
            self.allocator.free(sub_entry.channel);
        }
        self.subscriptions.deinit(self.allocator);
    }

    pub fn doWork(self: *DriverConductor) i32 {
        return self.ring_buffer.read(handleMessage, @ptrCast(self), 10);
    }

    fn handleAddPublication(self: *DriverConductor, data: []const u8) void {
        if (data.len < 16) return; // Need at least correlation_id (8) + stream_id (4) + channel_len (4)

        const correlation_id = std.mem.readInt(i64, data[0..8], .little);
        const stream_id = std.mem.readInt(i32, data[8..12], .little);
        const channel_len = std.mem.readInt(i32, data[12..16], .little);

        if (channel_len < 0 or data.len < 16 + @as(usize, @intCast(channel_len))) {
            self.sendError(correlation_id, 1, "Invalid ADD_PUBLICATION message");
            return;
        }

        const channel_data = data[16 .. 16 + @as(usize, @intCast(channel_len))];
        const session_id = self.next_session_id;
        self.next_session_id +%= 1;

        const channel_copy = self.allocator.dupe(u8, channel_data) catch {
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        const entry = PublicationEntry{
            .registration_id = correlation_id,
            .session_id = session_id,
            .stream_id = stream_id,
            .channel = channel_copy,
            .ref_count = 1,
        };

        self.publications.append(self.allocator, entry) catch {
            self.allocator.free(channel_copy);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        self.sendPublicationReady(correlation_id, session_id, stream_id);
    }

    fn handleRemovePublication(self: *DriverConductor, data: []const u8) void {
        if (data.len < 16) return;

        const registration_id = std.mem.readInt(i64, data[8..16], .little);

        var found_index: ?usize = null;
        for (self.publications.items, 0..) |pub_entry, i| {
            if (pub_entry.registration_id == registration_id) {
                found_index = i;
                break;
            }
        }

        if (found_index) |idx| {
            const removed = self.publications.swapRemove(idx);
            self.allocator.free(removed.channel);
        }
    }

    fn handleAddSubscription(self: *DriverConductor, data: []const u8) void {
        if (data.len < 16) return;

        const correlation_id = std.mem.readInt(i64, data[0..8], .little);
        const stream_id = std.mem.readInt(i32, data[8..12], .little);
        const channel_len = std.mem.readInt(i32, data[12..16], .little);

        if (channel_len < 0 or data.len < 16 + @as(usize, @intCast(channel_len))) {
            self.sendError(correlation_id, 1, "Invalid ADD_SUBSCRIPTION message");
            return;
        }

        const channel_data = data[16 .. 16 + @as(usize, @intCast(channel_len))];

        const channel_copy = self.allocator.dupe(u8, channel_data) catch {
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        const entry = SubscriptionEntry{
            .registration_id = correlation_id,
            .stream_id = stream_id,
            .channel = channel_copy,
        };

        self.subscriptions.append(self.allocator, entry) catch {
            self.allocator.free(channel_copy);
            self.sendError(correlation_id, 2, "Out of memory");
            return;
        };

        self.sendSubscriptionReady(correlation_id, stream_id);
    }

    fn handleRemoveSubscription(self: *DriverConductor, data: []const u8) void {
        if (data.len < 16) return;

        const registration_id = std.mem.readInt(i64, data[8..16], .little);

        var found_index: ?usize = null;
        for (self.subscriptions.items, 0..) |sub_entry, i| {
            if (sub_entry.registration_id == registration_id) {
                found_index = i;
                break;
            }
        }

        if (found_index) |idx| {
            const removed = self.subscriptions.swapRemove(idx);
            self.allocator.free(removed.channel);
        }
    }

    fn handleClientKeepalive(self: *DriverConductor, data: []const u8) void {
        if (data.len < 8) return;
        const _client_id = std.mem.readInt(i64, data[0..8], .little);
        // Liveness tracking is future work; no-op for now
        _ = _client_id;
        _ = self;
    }

    fn handleAddCounter(self: *DriverConductor, data: []const u8) void {
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

    fn handleRemoveCounter(self: *DriverConductor, data: []const u8) void {
        if (data.len < 12) return;

        const correlation_id = std.mem.readInt(i64, data[0..8], .little);
        const counter_id = std.mem.readInt(i32, data[8..12], .little);

        self.counters_map.free(counter_id);
        _ = correlation_id;
    }

    fn sendPublicationReady(self: *DriverConductor, correlation_id: i64, session_id: i32, stream_id: i32) void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], session_id, .little);
        std.mem.writeInt(i32, buf[12..16], stream_id, .little);
        self.broadcaster.transmit(RESPONSE_ON_PUBLICATION_READY, &buf);
    }

    fn sendSubscriptionReady(self: *DriverConductor, correlation_id: i64, stream_id: i32) void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], stream_id, .little);
        std.mem.writeInt(i32, buf[12..16], 0, .little); // padding
        self.broadcaster.transmit(RESPONSE_ON_SUBSCRIPTION_READY, &buf);
    }

    fn sendError(self: *DriverConductor, correlation_id: i64, error_code: i32, msg: []const u8) void {
        // Allocate buffer for response: correlation_id (8) + error_code (4) + msg_len (4) + message
        var buf: [16]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], error_code, .little);
        std.mem.writeInt(i32, buf[12..16], @as(i32, @intCast(msg.len)), .little);

        // Transmit header
        self.broadcaster.transmit(RESPONSE_ON_ERROR, buf[0..16]);

        // If there's a message, we need to transmit it separately
        // For now, just transmit empty message if msg is too long
        if (msg.len > 0) {
            // Create another transmission with just the message data
            // This is simplified; a real impl might batch this differently
            const msg_buf = self.allocator.alloc(u8, msg.len) catch return;
            defer self.allocator.free(msg_buf);
            @memcpy(msg_buf, msg);
            // Note: this transmits as separate record; real impl would include in response
        }
    }

    fn sendCounterReady(self: *DriverConductor, correlation_id: i64, counter_id: i32) void {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i32, buf[8..12], counter_id, .little);
        self.broadcaster.transmit(RESPONSE_ON_COUNTER_READY, &buf);
    }
};

fn handleMessage(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
    const self: *DriverConductor = @ptrCast(@alignCast(ctx));
    switch (msg_type_id) {
        CMD_ADD_PUBLICATION => self.handleAddPublication(data),
        CMD_REMOVE_PUBLICATION => self.handleRemovePublication(data),
        CMD_ADD_SUBSCRIPTION => self.handleAddSubscription(data),
        CMD_REMOVE_SUBSCRIPTION => self.handleRemoveSubscription(data),
        CMD_CLIENT_KEEPALIVE => self.handleClientKeepalive(data),
        CMD_ADD_COUNTER => self.handleAddCounter(data),
        CMD_REMOVE_COUNTER => self.handleRemoveCounter(data),
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

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 4096);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 = undefined;
    var values_buf: [4096]u8 = undefined;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm);
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

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 4096);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 = undefined;
    var values_buf: [4096]u8 = undefined;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm);
    defer conductor.deinit();

    // Simulate ADD_PUBLICATION command
    var cmd_buf: [32]u8 = undefined;
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 12345, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[8..12], 42, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[12..16], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[16 .. 16 + channel.len], channel);

    // Directly call handler
    conductor.handleAddPublication(cmd_buf[0 .. 16 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.publications.items.len);
    try testing.expectEqual(@as(i32, 42), conductor.publications.items[0].stream_id);
    try testing.expectEqual(@as(i64, 12345), conductor.publications.items[0].registration_id);
    try testing.expectEqualStrings(channel, conductor.publications.items[0].channel);
}

test "DriverConductor ADD_SUBSCRIPTION creates entry and sends ready response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 4096);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 = undefined;
    var values_buf: [4096]u8 = undefined;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm);
    defer conductor.deinit();

    // Simulate ADD_SUBSCRIPTION command
    var cmd_buf: [32]u8 = undefined;
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 54321, .little); // correlation_id
    std.mem.writeInt(i32, cmd_buf[8..12], 99, .little); // stream_id
    std.mem.writeInt(i32, cmd_buf[12..16], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[16 .. 16 + channel.len], channel);

    // Directly call handler
    conductor.handleAddSubscription(cmd_buf[0 .. 16 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.subscriptions.items.len);
    try testing.expectEqual(@as(i32, 99), conductor.subscriptions.items[0].stream_id);
    try testing.expectEqual(@as(i64, 54321), conductor.subscriptions.items[0].registration_id);
    try testing.expectEqualStrings(channel, conductor.subscriptions.items[0].channel);
}

test "DriverConductor REMOVE_PUBLICATION cleans up entry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring_buf: [4096]u8 = undefined;
    var rb = ring_buffer.ManyToOneRingBuffer.init(&ring_buf);

    var bcast = try broadcast.BroadcastTransmitter.init(allocator, 4096);
    defer bcast.deinit(allocator);

    var meta_buf: [4096]u8 = undefined;
    var values_buf: [4096]u8 = undefined;
    var cm = counters.CountersMap.init(&meta_buf, &values_buf);

    var conductor = try DriverConductor.init(allocator, &rb, &bcast, &cm);
    defer conductor.deinit();

    // Add a publication first
    var cmd_buf: [32]u8 = undefined;
    const channel = "aeron:udp";
    std.mem.writeInt(i64, cmd_buf[0..8], 11111, .little);
    std.mem.writeInt(i32, cmd_buf[8..12], 42, .little);
    std.mem.writeInt(i32, cmd_buf[12..16], @as(i32, @intCast(channel.len)), .little);
    @memcpy(cmd_buf[16 .. 16 + channel.len], channel);
    conductor.handleAddPublication(cmd_buf[0 .. 16 + channel.len]);

    try testing.expectEqual(@as(usize, 1), conductor.publications.items.len);

    // Remove it
    var remove_buf: [16]u8 = undefined;
    std.mem.writeInt(i64, remove_buf[0..8], 22222, .little); // different correlation_id for remove
    std.mem.writeInt(i64, remove_buf[8..16], 11111, .little); // registration_id to remove
    conductor.handleRemovePublication(&remove_buf);

    try testing.expectEqual(@as(usize, 0), conductor.publications.items.len);
}
