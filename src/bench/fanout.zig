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

    const handler = struct {
        fn handle(_: *const aeron.protocol.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const c = @as(*Context, @ptrCast(@alignCast(ctx)));
            c.count += 1;
        }
    }.handle;

    const message_count: usize = 10000;
    const sub_counts = [_]usize{ 1, 2, 4, 8 };
    const payload = "bench_fanout_message";

    std.debug.print("| Subs | Msgs/sec  | Overhead |\n", .{});
    std.debug.print("|------|-----------|----------|\n", .{});

    var baseline_time: u64 = 0;

    for (sub_counts) |sub_count| {
        // Create subscriptions
        const subs = try allocator.alloc(*Subscription, sub_count);
        defer {
            for (subs) |s| {
                s.deinit();
                allocator.destroy(s);
            }
            allocator.free(subs);
        }

        for (0..sub_count) |i| {
            subs[i] = try allocator.create(Subscription);
            subs[i].* = try Subscription.init(allocator, @intCast(i + 1), "aeron:ipc");

            const img = try allocator.create(Image);
            img.* = Image.init(1, @intCast(i + 1), 100, lb);
            try subs[i].addImage(img);
        }

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

        // Receive phase: all subs must receive all messages
        var contexts: [8]Context = undefined;
        for (0..sub_count) |i| {
            contexts[i] = Context{};
        }

        while (true) {
            var all_done = true;
            for (0..sub_count) |i| {
                if (contexts[i].count < message_count) {
                    _ = driver.doWork();
                    _ = subs[i].poll(handler, &contexts[i], 100);
                    all_done = false;
                }
            }
            if (all_done) break;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const msgs_per_sec = @as(f64, @floatFromInt(@as(u64, @intCast(message_count)))) / elapsed_sec;

        if (sub_count == 1) {
            baseline_time = elapsed_ns;
            std.debug.print("| {: >4} | {: >9.0} | baseline |\n", .{ sub_count, msgs_per_sec });
        } else {
            const overhead = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(baseline_time)) - 1.0) * 100.0;
            std.debug.print("| {: >4} | {: >9.0} | {: >6.1}% |\n", .{ sub_count, msgs_per_sec, overhead });
        }
    }
}
