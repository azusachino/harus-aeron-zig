// Aeron unified entry point — runs media driver, archive, cluster, or CLI tools
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const media_driver = @import("driver/media_driver.zig");
const archive_mod = @import("archive/archive.zig");
const cluster_mod = @import("cluster/cluster.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const signal = @import("signal.zig");
const health_mod = @import("health.zig");
const tools_stat = @import("tools/stat.zig");
const tools_errors = @import("tools/errors.zig");
const tools_loss = @import("tools/loss.zig");
const tools_streams = @import("tools/streams.zig");
const tools_events = @import("tools/events.zig");
const tools_cluster = @import("tools/cluster_tool.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = cli.parse(args);

    switch (opts.command) {
        .driver => {
            var ctx = media_driver.MediaDriverContext{};
            ctx.aeron_dir = opts.aeron_dir;
            if (opts.term_buffer_length) |v| ctx.term_buffer_length = v;
            if (opts.mtu_length) |v| ctx.mtu_length = v;
            try runDriver(allocator, ctx);
        },
        .archive => try runArchive(allocator),
        .cluster => try runCluster(allocator),
        .stat => tools_stat.run(opts.aeron_dir),
        .errors => tools_errors.run(opts.aeron_dir),
        .loss => tools_loss.run(opts.aeron_dir),
        .streams => tools_streams.run(opts.aeron_dir),
        .events => tools_events.run(opts.aeron_dir),
        .cluster_tool => tools_cluster.run(opts.aeron_dir),
        .help => {
            var stdout_buf: [4096]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&stdout_buf);
            cli.printUsage(&stdout.interface) catch {};
        },
    }
}

fn ensureAeronDir(aeron_dir: []const u8) void {
    std.fs.makeDirAbsolute(aeron_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => std.log.warn("Could not create aeron_dir={s}: {}", .{ aeron_dir, err }),
    };
}

fn runDriver(allocator: std.mem.Allocator, ctx: media_driver.MediaDriverContext) !void {
    std.log.info("Aeron Media Driver starting...", .{});
    signal.install();
    ensureAeronDir(ctx.aeron_dir);

    const cfg = config_mod.Config.fromEnv();
    var is_ready = std.atomic.Value(bool).init(false);
    var hs = health_mod.HealthServer.init(cfg.health_port, &is_ready);
    hs.start();

    const md = try media_driver.MediaDriver.create(allocator, ctx);
    defer md.destroy();

    std.log.info("MediaDriver initialized with aeron_dir={s}", .{ctx.aeron_dir});
    is_ready.store(true, .release);

    while (signal.isRunning()) {
        _ = md.doWork();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    std.log.info("MediaDriver shutting down.", .{});
}

fn runArchive(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Archive starting...", .{});
    signal.install();
    ensureAeronDir(std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron");

    const archive_dir = std.posix.getenv("ARCHIVE_DIR") orelse "/tmp/aeron-archive";
    const control_channel = std.posix.getenv("ARCHIVE_CONTROL_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:8010";

    const ctx = archive_mod.ArchiveContext{
        .archive_dir = archive_dir,
        .control_channel = control_channel,
    };

    var archive = try archive_mod.Archive.init(allocator, ctx);
    defer archive.deinit();

    archive.start();
    std.log.info("Archive running — dir={s} control={s}", .{ archive_dir, control_channel });

    while (signal.isRunning()) {
        _ = archive.doWork() catch |err| {
            std.log.err("Archive doWork error: {}", .{err});
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    std.log.info("Archive shutting down.", .{});
}

fn runCluster(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Cluster node starting...", .{});
    signal.install();
    ensureAeronDir(std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron");

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

    const cfg = config_mod.Config.fromEnv();
    var is_ready = std.atomic.Value(bool).init(false);
    var hs = health_mod.HealthServer.init(cfg.health_port, &is_ready);
    hs.start();

    module.start();
    std.log.info("Cluster node {d} running — ingress={s} log={s} consensus={s}", .{
        member_id,
        ingress_channel,
        log_channel,
        consensus_channel,
    });
    is_ready.store(true, .release);

    var now_ns: i64 = 0;
    while (signal.isRunning()) {
        now_ns += 10 * std.time.ns_per_ms;
        _ = module.doWork(now_ns) catch |err| {
            std.log.err("Cluster doWork error: {}", .{err});
        };
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.log.info("Cluster node shutting down.", .{});
}
