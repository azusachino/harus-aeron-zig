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
        receiver_id: i64,
        now_ns: i64,
    ) i64 {
        return switch (self.*) {
            .unicast => |*fc| fc.onStatusMessage(consumption_term_id, consumption_term_offset, receiver_window, initial_term_id, term_length),
            .min_multicast => |*fc| fc.onStatusMessage(session_id, stream_id, consumption_term_id, consumption_term_offset, receiver_window, initial_term_id, term_length, receiver_id, now_ns),
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
        window: i32,
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
        receiver_id: i64,
        now_ns: i64,
    ) i64 {
        _ = session_id;
        _ = stream_id;
        const receiver_position = @as(i64, consumption_term_id - initial_term_id) * term_length + consumption_term_offset;

        // Update or add receiver record
        var found = false;
        for (self.receivers.items) |*rec| {
            if (rec.receiver_id == receiver_id) {
                rec.position = receiver_position;
                rec.window = receiver_window;
                rec.last_activity_ns = now_ns;
                found = true;
                break;
            }
        }

        if (!found) {
            self.receivers.append(self.allocator, .{
                .receiver_id = receiver_id,
                .position = receiver_position,
                .window = receiver_window,
                .last_activity_ns = now_ns,
            }) catch {};
        }

        // MinMulticast limit is the minimum of all (position + window)
        var min_limit: i64 = std.math.maxInt(i64);

        for (self.receivers.items) |rec| {
            const rec_limit = rec.position + rec.window;
            if (rec_limit < min_limit) {
                min_limit = rec_limit;
            }
        }

        return if (self.receivers.items.len > 0) min_limit else receiver_position + receiver_window;
    }

    pub fn onIdle(self: *MinMulticastFlowControl, now_ns: i64, sender_limit: i64, sender_position: i64) i64 {
        _ = sender_position;
        const deadline = now_ns - self.timeout_ns;
        var i: usize = 0;
        var changed = false;
        while (i < self.receivers.items.len) {
            if (self.receivers.items[i].last_activity_ns < deadline) {
                _ = self.receivers.swapRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }

        if (self.receivers.items.len == 0) {
            return sender_limit;
        }

        if (!changed) {
            return sender_limit;
        }

        var min_limit: i64 = std.math.maxInt(i64);
        for (self.receivers.items) |rec| {
            const rec_limit = rec.position + rec.window;
            if (rec_limit < min_limit) {
                min_limit = rec_limit;
            }
        }
        return min_limit;
    }
};
