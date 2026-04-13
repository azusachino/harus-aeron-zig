const std = @import("std");
const aeron = @import("aeron");
const MediaDriver = aeron.driver.MediaDriver;
const ExclusivePublication = aeron.ExclusivePublication;
const Subscription = aeron.Subscription;
const Image = aeron.Image;
const LogBuffer = aeron.logbuffer.LogBuffer;
const FragmentHandler = aeron.logbuffer.term_reader.FragmentHandler;

const Context = struct {
    count: i32 = 0,
};

const TIMEOUT_NS = 60 * std.time.ns_per_s;

fn resetLogBuffer(initial_term_id: i32, lb: *LogBuffer, publication: *ExclusivePublication, img: *Image) void {
    @memset(lb.termBuffer(0), 0);

    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    publication.* = ExclusivePublication.init(publication.session_id, publication.stream_id, initial_term_id, publication.term_length, publication.mtu, lb);
    publication.publisher_limit = std.math.maxInt(i64);
    img.* = Image.init(img.session_id, img.stream_id, initial_term_id, lb);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var start_time = std.time.nanoTimestamp();

    // Start embedded driver
    const driver = try MediaDriver.create(allocator, .{
        .ipc_term_buffer_length = 64 * 1024,
    });
    defer driver.destroy();

    const term_length = 16 * 1024 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer {
        lb.deinit();
        allocator.destroy(lb);
    }
    lb.* = try LogBuffer.init(allocator, term_length);

    const initial_term_id: i32 = 100;
    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    var pub_instance = ExclusivePublication.init(1, 1, initial_term_id, term_length, 1408, lb);
    pub_instance.publisher_limit = std.math.maxInt(i64);

    var sub = try Subscription.init(allocator, 1, "aeron:ipc");
    defer sub.deinit();

    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1, initial_term_id, lb);
    try sub.addImage(img);

    var context = Context{};
    const handler = struct {
        fn handle(_: *const aeron.protocol.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const c = @as(*Context, @ptrCast(@alignCast(ctx)));
            c.count += 1;
        }
    }.handle;

    // Warmup: send 1000 messages
    const warmup_msg = "warmup";
    var warmup_sent: usize = 0;
    context.count = 0;
    while (warmup_sent < 1000) {
        if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) return error.Timeout;
        switch (pub_instance.offer(warmup_msg)) {
            .ok => |_| warmup_sent += 1,
            .admin_action => {},
            .back_pressure => {
                while (context.count < @as(i32, @intCast(warmup_sent))) {
                    if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) return error.Timeout;
                    _ = try driver.doWork();
                    _ = sub.poll(handler, &context, 1000);
                }
                resetLogBuffer(initial_term_id, lb, &pub_instance, img);
                context.count = 0;
                warmup_sent = 0;
            },
            else => {},
        }
        _ = try driver.doWork();
        _ = sub.poll(handler, &context, 1000);
    }

    while (context.count < 1000) {
        if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) return error.Timeout;
        _ = try driver.doWork();
        _ = sub.poll(handler, &context, 1000);
    }

    const sizes = [_]usize{ 64, 1024, 8192 };
    const message_count: usize = 1000;
    const message_count_i32: i32 = @intCast(message_count);

    std.debug.print("| Size   | Msgs/sec  | MB/sec     |\n", .{});
    std.debug.print("|--------|-----------|------------|\n", .{});

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        @memset(payload, 0xAB);

        resetLogBuffer(initial_term_id, lb, &pub_instance, img);
        context.count = 0;
        start_time = std.time.nanoTimestamp(); // Reset global timeout for each size

        var sent: usize = 0;
        var timer = try std.time.Timer.start();
        while (sent < message_count) {
            if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) {
                std.debug.print("\nTimeout at size {d}: sent={d}, count={d}\n", .{ size, sent, context.count });
                return error.Timeout;
            }
            switch (pub_instance.offer(payload)) {
                .ok => |_| sent += 1,
                .admin_action => {},
                .back_pressure => {
                    while (context.count < @as(i32, @intCast(sent))) {
                        if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) {
                            std.debug.print("\nTimeout during backpressure at size {d}: sent={d}, count={d}\n", .{ size, sent, context.count });
                            return error.Timeout;
                        }
                        _ = try driver.doWork();
                        _ = sub.poll(handler, &context, 1000);
                    }
                    resetLogBuffer(initial_term_id, lb, &pub_instance, img);
                    context.count = 0;
                    sent = 0;
                    timer = try std.time.Timer.start();
                    continue;
                },
                else => {},
            }
            _ = try driver.doWork();
            _ = sub.poll(handler, &context, 1000);
        }
        const elapsed_ns = timer.read();
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

        while (context.count < message_count_i32) {
            if (std.time.nanoTimestamp() - start_time > TIMEOUT_NS) {
                std.debug.print("\nTimeout during draining at size {d}: sent={d}, count={d}\n", .{ size, sent, context.count });
                return error.Timeout;
            }
            _ = try driver.doWork();
            _ = sub.poll(handler, &context, 1000);
        }

        const msgs_per_sec = @as(f64, @floatFromInt(message_count)) / elapsed_sec;
        const mb_per_sec = (msgs_per_sec * @as(f64, @floatFromInt(size))) / 1e6;

        std.debug.print("| {: >6} | {: >9.0} | {: >10.2} |\n", .{ size, msgs_per_sec, mb_per_sec });
    }
}
