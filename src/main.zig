// Aeron unified entry point — runs media driver, archive, or cluster node
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const media_driver = @import("driver/media_driver.zig");
const archive_mod = @import("archive/archive.zig");
const cluster_mod = @import("cluster/cluster.zig");

const Mode = enum { driver, archive, cluster };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Determine mode from args
    var mode: Mode = .driver;
    var driver_ctx = media_driver.MediaDriverContext{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--archive")) {
            mode = .archive;
        } else if (std.mem.eql(u8, arg, "--cluster")) {
            mode = .cluster;
        } else if (std.mem.startsWith(u8, arg, "-Daeron.dir=")) {
            driver_ctx.aeron_dir = arg["-Daeron.dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "-Daeron.term.buffer.length=")) {
            if (std.fmt.parseInt(i32, arg["-Daeron.term.buffer.length=".len..], 10)) |val| {
                driver_ctx.term_buffer_length = val;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "-Daeron.mtu.length=")) {
            if (std.fmt.parseInt(i32, arg["-Daeron.mtu.length=".len..], 10)) |val| {
                driver_ctx.mtu_length = val;
            } else |_| {}
        }
    }

    switch (mode) {
        .driver => try runDriver(allocator, driver_ctx),
        .archive => try runArchive(allocator),
        .cluster => try runCluster(allocator),
    }
}

fn runDriver(allocator: std.mem.Allocator, ctx: media_driver.MediaDriverContext) !void {
    std.log.info("Aeron Media Driver starting...", .{});

    const md = try media_driver.MediaDriver.create(allocator, ctx);
    defer md.destroy();

    std.log.info("MediaDriver initialized with aeron_dir={s}", .{ctx.aeron_dir});

    // Run duty-cycle loop until interrupted
    while (true) {
        _ = md.doWork();
        // Yield to avoid busy-spinning at 100% CPU in container
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

fn runArchive(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Archive starting...", .{});

    const archive_dir = std.posix.getenv("ARCHIVE_DIR") orelse "/tmp/aeron-archive";
    const control_channel = std.posix.getenv("ARCHIVE_CONTROL_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:8010";

    const ctx = archive_mod.ArchiveContext{
        .archive_dir = archive_dir,
        .control_channel = control_channel,
    };

    var archive = archive_mod.Archive.init(allocator, ctx);
    defer archive.deinit();

    archive.start();
    std.log.info("Archive running — dir={s} control={s}", .{ archive_dir, control_channel });

    // Run duty-cycle loop
    while (true) {
        _ = archive.doWork() catch |err| {
            std.log.err("Archive doWork error: {}", .{err});
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

fn runCluster(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Cluster node starting...", .{});

    // Parse member ID from POD_NAME (k8s StatefulSet ordinal: aeron-cluster-N → N)
    const member_id = blk: {
        if (std.posix.getenv("POD_NAME")) |pod_name| {
            if (std.mem.lastIndexOfScalar(u8, pod_name, '-')) |dash_pos| {
                break :blk std.fmt.parseInt(i32, pod_name[dash_pos + 1 ..], 10) catch 0;
            }
        }
        break :blk @as(i32, 0);
    };

    const ingress_channel = std.posix.getenv("INGRESS_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9010";
    const log_channel = std.posix.getenv("LOG_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9020";
    const consensus_channel = std.posix.getenv("CONSENSUS_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9030";

    const ctx = cluster_mod.ClusterContext{
        .member_id = member_id,
        .ingress_channel = ingress_channel,
        .log_channel = log_channel,
        .consensus_channel = consensus_channel,
    };

    var module = try cluster_mod.ConsensusModule.init(allocator, ctx);
    defer module.deinit();

    module.start();
    std.log.info("Cluster node {d} running — ingress={s} log={s} consensus={s}", .{
        member_id,
        ingress_channel,
        log_channel,
        consensus_channel,
    });

    // Run duty-cycle loop with cluster time
    var now_ns: i64 = 0;
    while (true) {
        now_ns += 10 * std.time.ns_per_ms; // advance cluster time by 10ms per tick
        _ = module.doWork(now_ns) catch |err| {
            std.log.err("Cluster doWork error: {}", .{err});
        };
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}
