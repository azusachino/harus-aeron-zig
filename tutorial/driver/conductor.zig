// EXERCISE: Chapter 3.3 — The Conductor
// Reference: docs/tutorial/03-driver/C-6-conductor.md
//
// Your task: implement `doWork` and `handleAddPublication`.
// The command dispatch and response sending are provided.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

// To make this stub compile, we mock out the dependencies.
// In the real code, these would be imported from other modules.
const ManyToOneRingBuffer = struct {
    pub fn read(self: *ManyToOneRingBuffer, handler: anytype, ctx: *anyopaque, max_msgs: i32) i32 {
        _ = self;
        _ = handler;
        _ = ctx;
        _ = max_msgs;
        return 0;
    }
};

const BroadcastTransmitter = struct {
    pub fn transmit(self: *BroadcastTransmitter, msg_type_id: i32, data: []const u8) void {
        _ = self;
        _ = msg_type_id;
        _ = data;
    }
};

const CountersMap = struct {
    pub fn allocate(self: *CountersMap, type_id: i32, label: []const u8) struct { counter_id: i32 } {
        _ = self;
        _ = type_id;
        _ = label;
        return .{ .counter_id = 0 };
    }
    pub fn set(self: *CountersMap, counter_id: i32, value: i64) void {
        _ = self;
        _ = counter_id;
        _ = value;
    }
    pub fn free(self: *CountersMap, counter_id: i32) void {
        _ = self;
        _ = counter_id;
    }
};

const Receiver = struct {
    pub fn drainPendingSetups(self: *Receiver) []const SetupSignal {
        _ = self;
        return &[_]SetupSignal{};
    }
    pub fn onAddSubscription(self: *Receiver, image: *anyopaque) !void {
        _ = self;
        _ = image;
    }
};

const SetupSignal = struct {
    stream_id: i32,
    session_id: i32,
    term_length: i32,
    mtu: i32,
    initial_term_id: i32,
    source_address: std.net.Address,
};

const Sender = struct {
    send_endpoint: *anyopaque,
    pub fn onAddPublication(self: *Sender, net_pub: *anyopaque) void {
        _ = self;
        _ = net_pub;
    }
    pub fn onRemovePublication(self: *Sender, session_id: i32, stream_id: i32) void {
        _ = self;
        _ = session_id;
        _ = stream_id;
    }
};

const ReceiveChannelEndpoint = struct {
    socket: std.posix.socket_t,
};

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
    log_buffer: ?*anyopaque = null,
    network_pub: ?*anyopaque = null,
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
    receiver: *Receiver,
    sender: *Sender,
    allocator: std.mem.Allocator,
    publications: std.ArrayList(PublicationEntry),
    subscriptions: std.ArrayList(SubscriptionEntry),
    next_session_id: i32,
    recv_endpoint: *ReceiveChannelEndpoint,
    recv_bound: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        ring_buffer_ptr: *ManyToOneRingBuffer,
        broadcaster_ptr: *BroadcastTransmitter,
        counters_map_ptr: *CountersMap,
        receiver_ptr: *Receiver,
        sender_ptr: *Sender,
        recv_ep: *ReceiveChannelEndpoint,
        recv_bound: bool,
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
            .publications = std.ArrayList(PublicationEntry).init(allocator),
            .subscriptions = std.ArrayList(SubscriptionEntry).init(allocator),
            .next_session_id = 1,
        };
    }

    pub fn deinit(self: *DriverConductor) void {
        for (self.publications.items) |pub_entry| {
            self.allocator.free(pub_entry.channel);
        }
        self.publications.deinit();

        for (self.subscriptions.items) |sub_entry| {
            self.allocator.free(sub_entry.channel);
        }
        self.subscriptions.deinit();
    }

    pub fn doWork(self: *DriverConductor) i32 {
        _ = self;
        @panic("TODO: implement doWork to drain ring buffer and process SETUP signals");
    }

    pub fn handleAddPublication(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
        @panic("TODO: implement handleAddPublication");
    }

    // Other handlers stubbed out for simplicity
    pub fn handleRemovePublication(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
    pub fn handleAddSubscription(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
    pub fn handleRemoveSubscription(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
    pub fn handleClientKeepalive(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
    pub fn handleAddCounter(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
    pub fn handleRemoveCounter(self: *DriverConductor, data: []const u8) void {
        _ = self;
        _ = data;
    }
};

test "DriverConductor learner stub" {
    // Tests will be defined here to check the learner's implementation
}
