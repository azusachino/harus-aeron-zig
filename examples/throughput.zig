// Throughput Example
// Bidirectional pub/sub on IPC with live stats: msgs/sec, bytes/sec
const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol;
const MediaDriver = aeron.driver.MediaDriver;
const LogBuffer = aeron.logbuffer.LogBuffer;
const Image = aeron.Image;
const ExclusivePublication = aeron.ExclusivePublication;
const Subscription = aeron.Subscription;

const ThroughputContext = struct {
    messages_received: i64 = 0,
    bytes_received: i64 = 0,
};

const Options = struct {
    duration_s: u64 = 10,
    message_size: usize = 256,
    term_length: i32 = 16 * 1024 * 1024,
};

// ZIG: FragmentHandler callback is called for each message in the log buffer.
// AERON: Zero-copy delivery. The buffer slice points directly into the mmap'd term.
fn fragmentHandler(header: *const frame.DataHeader, buffer: []const u8, ctx_ptr: *anyopaque) void {
    _ = header;
    const ctx: *ThroughputContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.messages_received += 1;
    ctx.bytes_received += @intCast(buffer.len);
}

fn printUsage() void {
    std.debug.print(
        \\Throughput example (IPC, embedded driver)
        \\
        \\Usage:
        \\  throughput [--duration <seconds>] [--size <bytes>] [--term-length <bytes>]
        \\
        \\Defaults:
        \\  --duration 10
        \\  --size 256
        \\  --term-length 16777216
        \\
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var opts = Options{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            opts.duration_s = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--size")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            opts.message_size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--term-length")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            opts.term_length = try std.fmt.parseInt(i32, args[i], 10);
        } else {
            return error.InvalidArguments;
        }
    }

    if (opts.duration_s == 0 or opts.message_size == 0 or opts.term_length <= 0) {
        return error.InvalidArguments;
    }

    return opts;
}

fn resetIpcLogBuffer(initial_term_id: i32, lb: *LogBuffer, publication: *ExclusivePublication, img: *Image) void {
    @memset(lb.termBuffer(0), 0);

    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    publication.* = ExclusivePublication.init(publication.session_id, publication.stream_id, initial_term_id, publication.term_length, publication.mtu, lb);
    publication.publisher_limit = std.math.maxInt(i64);

    img.* = Image.init(img.session_id, img.stream_id, initial_term_id, lb);
}

pub fn main() !void {
    // ZIG: GPA for memory safety.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = parseArgs(allocator) catch |err| switch (err) {
        error.InvalidArguments => {
            printUsage();
            return;
        },
        else => return err,
    };

    std.debug.print("\n=== Throughput Test ===\n", .{});
    std.debug.print("Running for {d} seconds on IPC channel\n\n", .{opts.duration_s});

    // ZIG: MediaDriver.create launches the Conductor, Sender, and Receiver agents.
    // AERON: Media driver manages shared memory buffers and network I/O.
    const driver = try MediaDriver.create(allocator, .{});
    defer driver.destroy();

    // ZIG: Allocating a large log buffer for high-throughput IPC.
    // AERON: IPC (Inter-Process Communication) uses shared memory log buffers directly.
    const term_length = opts.term_length;
    const lb = try allocator.create(LogBuffer);
    defer allocator.destroy(lb);
    lb.* = try LogBuffer.init(allocator, term_length);
    defer lb.deinit();

    // ZIG: Volatile writes to metadata ensure visibility across CPU caches.
    const initial_term_id = 100;
    var meta = lb.metaData();
    meta.setRawTailVolatile(0, @as(i64, initial_term_id) << 32);
    meta.setActiveTermCount(0);

    // ZIG: ExclusivePublication avoids mutexes by assuming a single writer thread.
    // AERON: Publications are the write handles for an Aeron stream.
    var publication = ExclusivePublication.init(1, 1, initial_term_id, term_length, 1408, lb);
    publication.publisher_limit = std.math.maxInt(i64);

    // ZIG: Image represents a specific publisher's session within a subscription.
    const img = try allocator.create(Image);
    defer allocator.destroy(img);
    img.* = Image.init(1, 1, initial_term_id, lb);

    // ZIG: Subscription aggregates one or more Images for a given stream_id.
    var subscription = try Subscription.init(allocator, 1, "aeron:ipc");
    defer subscription.deinit();
    try subscription.addImage(img);

    // ZIG: Configurable payload size keeps the example usable as a benchmark harness.
    const msg = try allocator.alloc(u8, opts.message_size);
    defer allocator.free(msg);
    @memset(msg, 'X');

    // ZIG: std.time.Timer provides high-resolution monotonic time.
    var timer = try std.time.Timer.start();
    const test_duration_ns = opts.duration_s * std.time.ns_per_s;
    var stat_timer = try std.time.Timer.start();
    const stat_interval_ns = 1 * std.time.ns_per_s;

    var total_sent: i64 = 0;
    var total_received: i64 = 0;
    var total_bytes: i64 = 0;
    var ctx = ThroughputContext{};

    std.debug.print("Time(s)  | Messages/sec | Bytes/sec    | Total Sent | Total Recv\n", .{});
    std.debug.print("---------+--------------+--------------+------------+-----------\n", .{});

    var last_total_received: i64 = 0;
    var last_total_bytes: i64 = 0;
    while (timer.read() < test_duration_ns) {
        // AERON: offer() writes the message and advances the tail cursor via CAS.
        // Reset the single-term IPC log when it fills so the example does not stall permanently.
        switch (publication.offer(msg)) {
            .ok => |_| total_sent += 1,
            .admin_action => {},
            .back_pressure => resetIpcLogBuffer(initial_term_id, lb, &publication, img),
            else => {},
        }

        // AERON: poll() reads messages and invokes the handler. fragment_limit=100 for batching.
        ctx.messages_received = 0;
        ctx.bytes_received = 0;
        const fragments = subscription.poll(fragmentHandler, &ctx, 100);
        total_received += ctx.messages_received;
        total_bytes += ctx.bytes_received;

        // ZIG: Periodic stats output.
        if (stat_timer.read() >= stat_interval_ns) {
            const elapsed_sec: i64 = @intCast(timer.read() / std.time.ns_per_s);
            const msg_per_sec = total_received - last_total_received;
            const bytes_per_sec = total_bytes - last_total_bytes;
            last_total_received = total_received;
            last_total_bytes = total_bytes;

            std.debug.print(
                "{d:7} | {d:12} | {d:12} | {d:10} | {d:9}\n",
                .{ elapsed_sec, msg_per_sec, bytes_per_sec, total_sent, total_received },
            );

            stat_timer = try std.time.Timer.start();
        }

        // ZIG: Yield if no work was done to be good to the OS scheduler.
        if (fragments == 0) {
            std.Thread.sleep(100);
        }
    }

    // Final summary
    const elapsed_sec: i64 = @intCast(timer.read() / std.time.ns_per_s);
    const final_msg_sec = if (elapsed_sec > 0) @divTrunc(total_received, elapsed_sec) else 0;
    const final_bytes_sec = if (elapsed_sec > 0) @divTrunc(total_bytes, elapsed_sec) else 0;

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Duration: {d}s\n", .{elapsed_sec});
    std.debug.print("Messages Sent: {d}\n", .{total_sent});
    std.debug.print("Messages Received: {d}\n", .{total_received});
    std.debug.print("Average Throughput: {d} msg/sec, {d} bytes/sec\n\n", .{ final_msg_sec, final_bytes_sec });
}
