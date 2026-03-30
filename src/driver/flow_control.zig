const std = @import("std");
const protocol = @import("../protocol/frame.zig");

pub const FlowControl = union(enum) {
    unicast: UnicastFlowControl,
    min_multicast: MinMulticastFlowControl,

    pub fn onStatusMessage(
        self: *FlowControl,
        session_id: i32,
        stream_id: i32,
        consumption_term_id: i32,
        consumption_term_offset: i32,
        receiver_window: i32,
        initial_term_id: i32,
        term_length: i32,
        now_ns: i64,
    ) i64 {
        return switch (self.*) {
            .unicast => |*fc| fc.onStatusMessage(consumption_term_id, consumption_term_offset, receiver_window, initial_term_id, term_length),
            .min_multicast => |*fc| fc.onStatusMessage(session_id, stream_id, consumption_term_id, consumption_term_offset, receiver_window, initial_term_id, term_length, now_ns),
        };
    }

    pub fn onIdle(self: *FlowControl, now_ns: i64, sender_limit: i64, sender_position: i64) i64 {
        return switch (self.*) {
            .unicast => sender_limit,
            .min_multicast => |*fc| fc.onIdle(now_ns, sender_limit, sender_position),
        };
    }
};

pub const UnicastFlowControl = struct {
    pub fn onStatusMessage(
        self: *UnicastFlowControl,
        consumption_term_id: i32,
        consumption_term_offset: i32,
        receiver_window: i32,
        initial_term_id: i32,
        term_length: i32,
    ) i64 {
        _ = self;
        const receiver_position = @as(i64, consumption_term_id - initial_term_id) * term_length + consumption_term_offset;
        return receiver_position + receiver_window;
    }
};

pub const MinMulticastFlowControl = struct {
    const ReceiverRecord = struct {
        receiver_id: i64,
        position: i64,
        last_activity_ns: i64,
    };

    allocator: std.mem.Allocator,
    receivers: std.ArrayListUnmanaged(ReceiverRecord),
    timeout_ns: i64,

    pub fn init(allocator: std.mem.Allocator, timeout_ns: i64) MinMulticastFlowControl {
        return .{
            .allocator = allocator,
            .receivers = .{},
            .timeout_ns = timeout_ns,
        };
    }

    pub fn deinit(self: *MinMulticastFlowControl) void {
        self.receivers.deinit(self.allocator);
    }

    pub fn onStatusMessage(
        self: *MinMulticastFlowControl,
        session_id: i32,
        stream_id: i32,
        consumption_term_id: i32,
        consumption_term_offset: i32,
        receiver_window: i32,
        initial_term_id: i32,
        term_length: i32,
        now_ns: i64,
    ) i64 {
        _ = self;
        _ = session_id;
        _ = stream_id;
        const receiver_id: i64 = 0; // TODO: handle receiver_id from STATUS message
        const receiver_position = @as(i64, consumption_term_id - initial_term_id) * term_length + consumption_term_offset;
        const limit = receiver_position + receiver_window;

        // For now, MinMulticast is just a placeholder that behaves like Unicast
        // but tracks multiple receivers if we had receiver_id.
        // Since we don't have receiver_id in our STATUS frame yet (it's in the spec but maybe not in our struct),
        // we'll just treat it as single receiver for now.
        _ = receiver_id;
        _ = now_ns;

        return limit;
    }

    pub fn onIdle(self: *MinMulticastFlowControl, now_ns: i64, sender_limit: i64, sender_position: i64) i64 {
        _ = self;
        _ = now_ns;

        _ = now_ns;
        _ = sender_position;
        return sender_limit;
    }
};
