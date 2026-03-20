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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start embedded driver
    const driver = try MediaDriver.create(allocator, .{
        .ipc_term_buffer_length = 64 * 1024,
    });
    defer driver.destroy();

    // Create log buffer and publication
    const term_length = 64 * 1024;
    const lb = try allocator.create(LogBuffer);
    defer {
        lb.deinit();
        allocator.destroy(lb);
    }
    lb.* = try LogBuffer.init(allocator, term_length);

    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, 100) << 32);
    meta.setActiveTermCount(0);

    var pub_instance = ExclusivePublication.init(1, 1, 100, term_length, 1408, lb);
    pub_instance.publisher_limit = 1024 * 1024;

    // Create subscription and image
    var sub = try Subscription.init(allocator, 1, "aeron:ipc");
    defer sub.deinit();

    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1, 100, lb);
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
    for (0..1000) |_| {
        while (true) {
            const result = pub_instance.offer(warmup_msg);
            if (result == .ok) break;
            _ = driver.doWork();
        }
    }
    context.count = 0;
    while (context.count < 1000) {
        _ = driver.doWork();
        _ = sub.poll(handler, &context, 100);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Test at different message sizes
    const sizes = [_]usize{ 64, 1024, 65536 };
    const message_count: usize = 100000;

    std.debug.print("| Size   | Msgs/sec  | MB/sec     |\n", .{});
    std.debug.print("|--------|-----------|------------|\n", .{});

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        @memset(payload, 0xAB);

        // Send phase
        var timer = try std.time.Timer.start();
        for (0..message_count) |_| {
            while (true) {
                const result = pub_instance.offer(payload);
                if (result == .ok) break;
                _ = driver.doWork();
            }
        }
        const elapsed_ns = timer.read();
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

        // Receive phase
        context.count = 0;
        while (context.count < message_count) {
            _ = driver.doWork();
            _ = sub.poll(handler, &context, 100);
            if (context.count < message_count) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        const msgs_per_sec = @as(f64, @floatFromInt(message_count)) / elapsed_sec;
        const mb_per_sec = (msgs_per_sec * @as(f64, @floatFromInt(size))) / 1e6;

        std.debug.print("| {: >6} | {: >9.0} | {: >10.2} |\n", .{ size, msgs_per_sec, mb_per_sec });
    }
}
