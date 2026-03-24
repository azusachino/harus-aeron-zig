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

    // Start embedded driver
    const driver = try MediaDriver.create(allocator, .{
        .ipc_term_buffer_length = 64 * 1024,
    });
    defer driver.destroy();

    // Create log buffer and publication. This is a simplified benchmark that reuses a single term.
    // To avoid stalling when the term fills, we reset the term once all sent messages are drained.
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

    // Create subscription and image
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
        switch (pub_instance.offer(warmup_msg)) {
            .ok => |_| warmup_sent += 1,
            .admin_action => {},
            .back_pressure => {
                while (context.count < @as(i32, @intCast(warmup_sent))) {
                    _ = driver.doWork();
                    _ = sub.poll(handler, &context, 100);
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                }
                resetLogBuffer(initial_term_id, lb, &pub_instance, img);
            },
            else => {},
        }
        _ = driver.doWork();
        _ = sub.poll(handler, &context, 100);
    }

    while (context.count < 1000) {
        _ = driver.doWork();
        _ = sub.poll(handler, &context, 100);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Test at different message sizes
    const sizes = [_]usize{ 64, 1024, 65536 };
    const message_count: usize = 100000;
    const message_count_i32: i32 = @intCast(message_count);

    std.debug.print("| Size   | Msgs/sec  | MB/sec     |\n", .{});
    std.debug.print("|--------|-----------|------------|\n", .{});

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        @memset(payload, 0xAB);

        resetLogBuffer(initial_term_id, lb, &pub_instance, img);
        context.count = 0;

        // Send phase
        var sent: usize = 0;
        var timer = try std.time.Timer.start();
        while (sent < message_count) {
            switch (pub_instance.offer(payload)) {
                .ok => |_| sent += 1,
                .admin_action => {},
                .back_pressure => {
                    while (context.count < @as(i32, @intCast(sent))) {
                        _ = driver.doWork();
                        _ = sub.poll(handler, &context, 100);
                        if (context.count < @as(i32, @intCast(sent))) {
                            std.Thread.sleep(1 * std.time.ns_per_ms);
                        }
                    }
                    resetLogBuffer(initial_term_id, lb, &pub_instance, img);
                },
                else => {},
            }
            _ = driver.doWork();
        }
        const elapsed_ns = timer.read();
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

        // Receive phase
        while (context.count < message_count_i32) {
            _ = driver.doWork();
            _ = sub.poll(handler, &context, 100);
            if (context.count < message_count_i32) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        const msgs_per_sec = @as(f64, @floatFromInt(message_count)) / elapsed_sec;
        const mb_per_sec = (msgs_per_sec * @as(f64, @floatFromInt(size))) / 1e6;

        std.debug.print("| {: >6} | {: >9.0} | {: >10.2} |\n", .{ size, msgs_per_sec, mb_per_sec });
    }
}
