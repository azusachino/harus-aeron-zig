// Aeron Media Driver entry point
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const media_driver = @import("driver/media_driver.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Aeron Media Driver starting...", .{});

    // Parse CLI arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var ctx = media_driver.MediaDriverContext{};

    // Parse -Daeron.dir=PATH, -Daeron.term.buffer.length=N, etc.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "-Daeron.dir=")) {
            const path = arg["-Daeron.dir=".len..];
            ctx.aeron_dir = path;
            std.log.info("Set aeron_dir={s}", .{path});
        } else if (std.mem.startsWith(u8, arg, "-Daeron.term.buffer.length=")) {
            const val_str = arg["-Daeron.term.buffer.length=".len..];
            if (std.fmt.parseInt(i32, val_str, 10)) |val| {
                ctx.term_buffer_length = val;
                std.log.info("Set term_buffer_length={}", .{val});
            } else |_| {
                std.log.warn("Invalid term buffer length: {s}", .{val_str});
            }
        } else if (std.mem.startsWith(u8, arg, "-Daeron.ipc.term.buffer.length=")) {
            const val_str = arg["-Daeron.ipc.term.buffer.length=".len..];
            if (std.fmt.parseInt(i32, val_str, 10)) |val| {
                ctx.ipc_term_buffer_length = val;
                std.log.info("Set ipc_term_buffer_length={}", .{val});
            } else |_| {
                std.log.warn("Invalid IPC term buffer length: {s}", .{val_str});
            }
        } else if (std.mem.startsWith(u8, arg, "-Daeron.mtu.length=")) {
            const val_str = arg["-Daeron.mtu.length=".len..];
            if (std.fmt.parseInt(i32, val_str, 10)) |val| {
                ctx.mtu_length = val;
                std.log.info("Set mtu_length={}", .{val});
            } else |_| {
                std.log.warn("Invalid MTU length: {s}", .{val_str});
            }
        }
    }

    // Initialize MediaDriver
    var md = try media_driver.MediaDriver.init(allocator, ctx);
    defer md.deinit();

    std.log.info("MediaDriver initialized with aeron_dir={s}", .{ctx.aeron_dir});

    // Embedded mode: run duty-cycle loop
    // In real implementation, this would spawn threads or wait for signals
    var work_count: i64 = 0;
    while (work_count < 100) : (work_count += 1) {
        _ = md.doWork();
    }

    std.log.info("Aeron Media Driver stopping...", .{});
}
