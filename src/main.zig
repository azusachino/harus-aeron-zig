// Aeron unified entry point — runs media driver, archive, cluster, or CLI tools
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const io_mod = @import("io.zig");
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

fn getenv(comptime name: [:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

fn makeDir(path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io_mod.io(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.CreateDirFailed,
    };
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    const opts = cli.parse(args);

    switch (opts.command) {
        .driver => {
            var ctx = media_driver.MediaDriverContext{};
            ctx.aeron_dir = opts.aeron_dir;
            if (opts.term_buffer_length) |v| ctx.term_buffer_length = v;
            if (opts.mtu_length) |v| ctx.mtu_length = v;

            const idle_mod = @import("ipc/idle_strategy.zig");
            if (std.mem.eql(u8, opts.idle_strategy, "busy")) {
                ctx.conductor_idle_strategy = idle_mod.IdleStrategy.initBusySpin();
                ctx.sender_idle_strategy = idle_mod.IdleStrategy.initBusySpin();
                ctx.receiver_idle_strategy = idle_mod.IdleStrategy.initBusySpin();
            } else if (std.mem.eql(u8, opts.idle_strategy, "yield")) {
                ctx.conductor_idle_strategy = idle_mod.IdleStrategy.initYielding();
                ctx.sender_idle_strategy = idle_mod.IdleStrategy.initYielding();
                ctx.receiver_idle_strategy = idle_mod.IdleStrategy.initYielding();
            } else if (std.mem.eql(u8, opts.idle_strategy, "sleep")) {
                ctx.conductor_idle_strategy = idle_mod.IdleStrategy.initSleeping(1_000_000); // 1ms
                ctx.sender_idle_strategy = idle_mod.IdleStrategy.initSleeping(1_000_000);
                ctx.receiver_idle_strategy = idle_mod.IdleStrategy.initSleeping(1_000_000);
            } else {
                ctx.conductor_idle_strategy = idle_mod.IdleStrategy.initDefaultBackoff();
                ctx.sender_idle_strategy = idle_mod.IdleStrategy.initDefaultBackoff();
                ctx.receiver_idle_strategy = idle_mod.IdleStrategy.initDefaultBackoff();
            }

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
            var stdout = std.Io.File.stdout().writer(io_mod.io(), &stdout_buf);
            cli.printUsage(&stdout.interface) catch {};
        },
    }
}

fn ensureAeronDir(aeron_dir: []const u8) void {
    makeDir(aeron_dir) catch |err| std.log.warn("Could not create aeron_dir={s}: {}", .{ aeron_dir, err });
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
    }
    std.log.info("MediaDriver shutting down.", .{});
}

fn runArchive(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Archive starting...", .{});
    signal.install();
    ensureAeronDir(getenv("AERON_DIR") orelse "/dev/shm/aeron");

    const archive_dir = getenv("ARCHIVE_DIR") orelse "/tmp/aeron-archive";
    const control_channel = getenv("ARCHIVE_CONTROL_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:8010";

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
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    std.log.info("Archive shutting down.", .{});
}

fn runCluster(allocator: std.mem.Allocator) !void {
    std.log.info("Aeron Cluster node starting...", .{});
    signal.install();
    ensureAeronDir(getenv("AERON_DIR") orelse "/dev/shm/aeron");

    const member_id = blk: {
        if (getenv("POD_NAME")) |pod_name| {
            if (std.mem.lastIndexOfScalar(u8, pod_name, '-')) |dash_pos| {
                break :blk std.fmt.parseInt(i32, pod_name[dash_pos + 1 ..], 10) catch 0;
            }
        }
        break :blk @as(i32, 0);
    };

    const ingress_channel = getenv("INGRESS_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9010";
    const log_channel = getenv("LOG_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9020";
    const consensus_channel = getenv("CONSENSUS_CHANNEL") orelse "aeron:udp?endpoint=0.0.0.0:9030";

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
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    std.log.info("Cluster node shutting down.", .{});
}
