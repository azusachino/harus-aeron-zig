// Aeron client library root
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub const protocol = @import("protocol/frame.zig");
pub const logbuffer = @import("logbuffer/log_buffer.zig");
pub const ipc = @import("ipc.zig");
pub const driver = @import("driver/media_driver.zig");
pub const cnc = @import("driver/cnc.zig");
pub const loss_report = @import("loss_report.zig");
pub const event_log = @import("event_log.zig");
pub const counters_report = @import("counters_report.zig");
pub const archive = struct {
    pub const protocol = @import("archive/protocol.zig");
    pub const catalog = @import("archive/catalog.zig");
    pub const conductor = @import("archive/conductor.zig");
    pub const recorder = @import("archive/recorder.zig");
    pub const replayer = @import("archive/replayer.zig");
};
pub const cluster = struct {
    pub const protocol = @import("cluster/protocol.zig");
    pub const election = @import("cluster/election.zig");
    pub const log = @import("cluster/log.zig");
    pub const conductor = @import("cluster/conductor.zig");
    pub const consensus = @import("cluster/cluster.zig");
};
pub const transport = struct {
    pub const ReceiveChannelEndpoint = @import("transport/endpoint.zig").ReceiveChannelEndpoint;
    pub const Poller = @import("transport/poller.zig").Poller;
    pub const UdpChannel = @import("transport/udp_channel.zig").UdpChannel;
    pub const AeronUri = @import("transport/uri.zig").AeronUri;
};

pub const ExclusivePublication = @import("publication.zig").ExclusivePublication;
pub const Subscription = @import("subscription.zig").Subscription;
pub const Image = @import("image.zig").Image;

pub const AeronContext = struct {
    aeron_dir: []const u8 = "/tmp/aeron",
};

pub const Aeron = struct {
    ctx: AeronContext,
    allocator: std.mem.Allocator,
    cnc_file: cnc.CncFile,
    to_driver_ring_buffer: ipc.ring_buffer.ManyToOneRingBuffer,
    to_clients_broadcast_receiver: ipc.broadcast.BroadcastReceiver,
    next_correlation_id: std.atomic.Value(i64),
    subscriptions: std.ArrayListUnmanaged(*Subscription),

    pub fn init(allocator: std.mem.Allocator, ctx: AeronContext) !Aeron {
        const cnc_path = try std.fmt.allocPrint(allocator, "{s}/CnC.dat", .{ctx.aeron_dir});
        defer allocator.free(cnc_path);

        var file = try cnc.CncFile.open(allocator, cnc_path);
        const to_driver = file.toDriverBuffer();
        const to_clients = file.toClientsBuffer();

        return Aeron{
            .ctx = ctx,
            .allocator = allocator,
            .cnc_file = file,
            .to_driver_ring_buffer = ipc.ring_buffer.ManyToOneRingBuffer.init(to_driver),
            .to_clients_broadcast_receiver = ipc.broadcast.BroadcastReceiver.wrap(to_clients),
            .next_correlation_id = std.atomic.Value(i64).init(1),
            .subscriptions = .{},
        };
    }

    pub fn deinit(self: *Aeron) void {
        var mutable_cnc = self.cnc_file;
        mutable_cnc.deinit();
        self.subscriptions.deinit(self.allocator);
    }

    pub fn doWork(self: *Aeron) i32 {
        var work: i32 = 0;
        while (self.to_clients_broadcast_receiver.receiveNext()) {
            const msg_type_id = self.to_clients_broadcast_receiver.typeId();
            const buffer = self.to_clients_broadcast_receiver.buffer();

            if (msg_type_id == driver.conductor.RESPONSE_ON_IMAGE_READY) {
                const registration_id = std.mem.readInt(i64, buffer[0..8], .little);
                const session_id = std.mem.readInt(i32, buffer[8..12], .little);
                const stream_id = std.mem.readInt(i32, buffer[12..16], .little);

                std.debug.print("[AERON] Image Ready: reg={d} session={d} stream={d}\n", .{ registration_id, session_id, stream_id });
                work += 1;
            } else if (msg_type_id == driver.conductor.RESPONSE_ON_SUBSCRIPTION_READY) {
                const correlation_id = std.mem.readInt(i64, buffer[0..8], .little);
                const stream_id = std.mem.readInt(i32, buffer[8..12], .little);
                std.debug.print("[AERON] Subscription Ready: correlation={d} stream={d}\n", .{ correlation_id, stream_id });
                work += 1;
            } else if (msg_type_id == driver.conductor.RESPONSE_ON_PUBLICATION_READY) {
                const correlation_id = std.mem.readInt(i64, buffer[0..8], .little);
                const session_id = std.mem.readInt(i32, buffer[8..12], .little);
                const stream_id = std.mem.readInt(i32, buffer[12..16], .little);
                std.debug.print("[AERON] Publication Ready: correlation={d} session={d} stream={d}\n", .{ correlation_id, session_id, stream_id });
                work += 1;
            }
        }
        return work;
    }

    pub fn addSubscription(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.next_correlation_id.fetchAdd(1, .monotonic);

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i64, buf[8..16], -1, .little); // registration_id (-1 for new)
        std.mem.writeInt(i32, buf[16..20], stream_id, .little);
        std.mem.writeInt(i32, buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(buf[24 .. 24 + channel.len], channel);

        if (!self.to_driver_ring_buffer.write(driver.conductor.CMD_ADD_SUBSCRIPTION, buf[0 .. 24 + channel.len])) {
            return error.RingBufferFull;
        }

        return correlation_id;
    }

    pub fn addPublication(self: *Aeron, channel: []const u8, stream_id: i32) !i64 {
        const correlation_id = self.next_correlation_id.fetchAdd(1, .monotonic);

        var buf: [1024]u8 = undefined;
        std.mem.writeInt(i64, buf[0..8], correlation_id, .little);
        std.mem.writeInt(i64, buf[8..16], -1, .little); // registration_id (-1 for new)
        std.mem.writeInt(i32, buf[16..20], stream_id, .little);
        std.mem.writeInt(i32, buf[20..24], @as(i32, @intCast(channel.len)), .little);
        @memcpy(buf[24 .. 24 + channel.len], channel);

        if (!self.to_driver_ring_buffer.write(driver.conductor.CMD_ADD_PUBLICATION, buf[0 .. 24 + channel.len])) {
            return error.RingBufferFull;
        }

        return correlation_id;
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "Aeron init and deinit" {
    const allocator = std.testing.allocator;
    const ctx = AeronContext{ .aeron_dir = "/tmp/aeron-test-client" };
    defer std.fs.deleteTreeAbsolute(ctx.aeron_dir) catch {};

    // Need a driver to create CnC.dat first
    var md = try driver.MediaDriver.create(allocator, .{ .aeron_dir = ctx.aeron_dir });
    defer md.destroy();

    var aeron = try Aeron.init(allocator, ctx);
    defer aeron.deinit();
    _ = aeron.doWork();
}
