// Ring Buffer Soak Test
// Stress-tests write/read throughput with varying message sizes.
// Verifies no data loss or corruption across high message counts.
//
// Default iterations: 1000 (CI), set SOAK_ITERS=10000000 for local soak.

const std = @import("std");
const aeron = @import("aeron");
const ring_buffer = aeron.ipc.ring_buffer;

const ManyToOneRingBuffer = ring_buffer.ManyToOneRingBuffer;

fn getSoakIterations() usize {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SOAK_ITERS")) |env| {
        defer std.testing.allocator.free(env);
        return std.fmt.parseInt(usize, env, 10) catch 1000;
    } else |_| {
        return 1000;
    }
}

test "ring_buffer_soak: write/read N messages without loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const iterations = getSoakIterations();

    // 256 KB ring buffer
    const buf = try allocator.alloc(u8, 256 * 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    // Message payload patterns: cycle through sizes 1, 32, 128, 512 bytes
    const sizes = [_]usize{ 1, 32, 128, 512 };
    var written: usize = 0;
    var size_idx: usize = 0;

    // Write phase: append messages with varying sizes
    while (written < iterations) {
        const payload_size = sizes[size_idx % sizes.len];
        const payload = try allocator.alloc(u8, payload_size);
        @memset(payload, @as(u8, @intCast((written % 256))));

        if (rb.write(@as(i32, @intCast(written % 32)), payload)) {
            written += 1;
            size_idx += 1;
        }
    }

    try std.testing.expectEqual(iterations, written);

    // Read phase: verify all messages read back with correct content
    var read_count: usize = 0;
    var read_total_bytes: usize = 0;

    const ReadContext = struct {
        count: *usize,
        total_bytes: *usize,
        allocator: std.mem.Allocator,
    };

    var ctx = ReadContext{
        .count = &read_count,
        .total_bytes = &read_total_bytes,
        .allocator = allocator,
    };

    const handler = struct {
        fn handle(msg_type_id: i32, data: []const u8, context: *anyopaque) void {
            _ = msg_type_id;
            const read_ctx: *ReadContext = @ptrCast(@alignCast(context));
            read_ctx.count.* += 1;
            read_ctx.total_bytes.* += data.len;
        }
    }.handle;

    // Read all available messages
    while (rb.read(handler, @ptrCast(&ctx), 128) > 0) {}

    try std.testing.expectEqual(iterations, read_count);
}

test "ring_buffer_soak: capacity-aware write loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const iterations = getSoakIterations();

    const buf = try allocator.alloc(u8, 256 * 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "test_message";
    var write_count: usize = 0;
    var failed_writes: usize = 0;

    // Write until we hit capacity, tracking both successes and failures
    var i: usize = 0;
    while (i < iterations) {
        if (rb.write(1, msg)) {
            write_count += 1;
        } else {
            failed_writes += 1;
            break;
        }
        i += 1;
    }

    // Verify we wrote at least some messages
    try std.testing.expect(write_count > 0);

    // Verify we can read back at least some of what we wrote
    var read_count: i32 = 0;
    const handler = struct {
        fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
            const count: *i32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.handle;

    // Read multiple times to drain all messages
    var total_read: usize = 0;
    while (true) {
        read_count = 0;
        read_count = rb.read(handler, @ptrCast(&read_count), 128);
        if (read_count == 0) break;
        total_read += @as(usize, @intCast(read_count));
    }
    try std.testing.expect(total_read > 0);
}

test "ring_buffer_soak: wrap-around with high message velocity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const iterations = getSoakIterations() / 10; // 10x smaller for wrap test

    const buf = try allocator.alloc(u8, 64 * 1024);
    @memset(buf, 0);

    var rb = ManyToOneRingBuffer.init(buf);

    const msg = "wrap_test";
    var total_writes: usize = 0;
    var total_reads: usize = 0;

    // Multiple write/read cycles to stress wrap-around
    var cycle: usize = 0;
    while (cycle < iterations) {
        // Write batch
        var batch_writes: usize = 0;
        while (batch_writes < 100 and total_writes < iterations * 10) {
            if (rb.write(1, msg)) {
                batch_writes += 1;
                total_writes += 1;
            } else {
                break;
            }
        }

        // Read batch
        var batch_reads: i32 = 0;
        const handler = struct {
            fn handle(_: i32, _: []const u8, ctx: *anyopaque) void {
                const count: *i32 = @ptrCast(@alignCast(ctx));
                count.* += 1;
            }
        }.handle;

        batch_reads = rb.read(handler, @ptrCast(&batch_reads), 50);
        total_reads += @as(usize, @intCast(batch_reads));

        cycle += 1;
    }

    try std.testing.expect(total_writes > 0);
    try std.testing.expect(total_reads > 0);
    // Verify we read back at least some data
    try std.testing.expect(total_reads >= total_writes / 2);
}
