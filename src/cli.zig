// CLI argument parser and subcommand dispatcher.
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub const Command = enum {
    driver,
    archive,
    cluster,
    stat,
    errors,
    loss,
    streams,
    events,
    cluster_tool,
    help,
};

pub const CliOptions = struct {
    command: Command = .driver,
    aeron_dir: []const u8 = "/dev/shm/aeron",
    term_buffer_length: ?i32 = null,
    mtu_length: ?i32 = null,
};

pub fn parse(args: []const []const u8) CliOptions {
    var opts = CliOptions{
        .aeron_dir = std.posix.getenv("AERON_DIR") orelse "/dev/shm/aeron",
    };

    if (args.len < 2) return opts;

    var i: usize = 1;

    // First arg might be a subcommand
    const first = args[1];
    if (std.mem.eql(u8, first, "stat")) {
        opts.command = .stat;
        i = 2;
    } else if (std.mem.eql(u8, first, "errors")) {
        opts.command = .errors;
        i = 2;
    } else if (std.mem.eql(u8, first, "loss")) {
        opts.command = .loss;
        i = 2;
    } else if (std.mem.eql(u8, first, "streams")) {
        opts.command = .streams;
        i = 2;
    } else if (std.mem.eql(u8, first, "events")) {
        opts.command = .events;
        i = 2;
    } else if (std.mem.eql(u8, first, "cluster-tool")) {
        opts.command = .cluster_tool;
        i = 2;
    } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        opts.command = .help;
        i = 2;
    } else if (std.mem.eql(u8, first, "--archive")) {
        opts.command = .archive;
        i = 2;
    } else if (std.mem.eql(u8, first, "--cluster")) {
        opts.command = .cluster;
        i = 2;
    } else if (std.mem.eql(u8, first, "--counters")) {
        opts.command = .stat;
        i = 2;
    }

    // Parse remaining flags
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--aeron-dir=")) {
            opts.aeron_dir = arg["--aeron-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "-Daeron.dir=")) {
            opts.aeron_dir = arg["-Daeron.dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "-Daeron.term.buffer.length=")) {
            opts.term_buffer_length = std.fmt.parseInt(i32, arg["-Daeron.term.buffer.length=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "-Daeron.mtu.length=")) {
            opts.mtu_length = std.fmt.parseInt(i32, arg["-Daeron.mtu.length=".len..], 10) catch null;
        }
    }

    return opts;
}

pub fn printUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: aeron-driver [command] [options]
        \\
        \\Commands:
        \\  (default)      Run the media driver
        \\  stat           Display live counters (refreshes every 1s)
        \\  errors         Display error log
        \\  loss           Display loss report
        \\  streams        Display per-stream positions
        \\  events         Display event log
        \\  cluster-tool   Display cluster status
        \\  help           Show this help
        \\
        \\Options:
        \\  --aeron-dir=PATH   Set aeron directory (default: /dev/shm/aeron)
        \\  --archive          Run in archive mode
        \\  --cluster          Run in cluster mode
        \\
    , .{});
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "parse: no arguments defaults to driver" {
    const args = &[_][]const u8{"aeron"};
    const opts = parse(args);
    try std.testing.expectEqual(Command.driver, opts.command);
    try std.testing.expectEqualStrings("/dev/shm/aeron", opts.aeron_dir);
}

test "parse: stat subcommand" {
    const args = &[_][]const u8{ "aeron", "stat" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.stat, opts.command);
}

test "parse: errors subcommand" {
    const args = &[_][]const u8{ "aeron", "errors" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.errors, opts.command);
}

test "parse: loss subcommand" {
    const args = &[_][]const u8{ "aeron", "loss" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.loss, opts.command);
}

test "parse: streams subcommand" {
    const args = &[_][]const u8{ "aeron", "streams" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.streams, opts.command);
}

test "parse: events subcommand" {
    const args = &[_][]const u8{ "aeron", "events" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.events, opts.command);
}

test "parse: cluster-tool subcommand" {
    const args = &[_][]const u8{ "aeron", "cluster-tool" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.cluster_tool, opts.command);
}

test "parse: help subcommand" {
    const args = &[_][]const u8{ "aeron", "help" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.help, opts.command);
}

test "parse: --help flag" {
    const args = &[_][]const u8{ "aeron", "--help" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.help, opts.command);
}

test "parse: -h flag" {
    const args = &[_][]const u8{ "aeron", "-h" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.help, opts.command);
}

test "parse: --aeron-dir flag" {
    const args = &[_][]const u8{ "aeron", "--aeron-dir=/tmp/aeron" };
    const opts = parse(args);
    try std.testing.expectEqualStrings("/tmp/aeron", opts.aeron_dir);
}

test "parse: -Daeron.dir flag" {
    const args = &[_][]const u8{ "aeron", "-Daeron.dir=/tmp/aeron" };
    const opts = parse(args);
    try std.testing.expectEqualStrings("/tmp/aeron", opts.aeron_dir);
}

test "parse: -Daeron.term.buffer.length flag" {
    const args = &[_][]const u8{ "aeron", "-Daeron.term.buffer.length=16777216" };
    const opts = parse(args);
    try std.testing.expectEqual(@as(?i32, 16777216), opts.term_buffer_length);
}

test "parse: -Daeron.mtu.length flag" {
    const args = &[_][]const u8{ "aeron", "-Daeron.mtu.length=1500" };
    const opts = parse(args);
    try std.testing.expectEqual(@as(?i32, 1500), opts.mtu_length);
}

test "parse: backward compat --archive flag" {
    const args = &[_][]const u8{ "aeron", "--archive" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.archive, opts.command);
}

test "parse: backward compat --cluster flag" {
    const args = &[_][]const u8{ "aeron", "--cluster" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.cluster, opts.command);
}

test "parse: backward compat --counters maps to stat" {
    const args = &[_][]const u8{ "aeron", "--counters" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.stat, opts.command);
}

test "parse: subcommand with flags" {
    const args = &[_][]const u8{ "aeron", "stat", "--aeron-dir=/tmp/aeron", "-Daeron.mtu.length=1500" };
    const opts = parse(args);
    try std.testing.expectEqual(Command.stat, opts.command);
    try std.testing.expectEqualStrings("/tmp/aeron", opts.aeron_dir);
    try std.testing.expectEqual(@as(?i32, 1500), opts.mtu_length);
}

test "parse: multiple flags in sequence" {
    const args = &[_][]const u8{
        "aeron",
        "stat",
        "-Daeron.dir=/custom",
        "-Daeron.term.buffer.length=8388608",
        "-Daeron.mtu.length=9000",
    };
    const opts = parse(args);
    try std.testing.expectEqual(Command.stat, opts.command);
    try std.testing.expectEqualStrings("/custom", opts.aeron_dir);
    try std.testing.expectEqual(@as(?i32, 8388608), opts.term_buffer_length);
    try std.testing.expectEqual(@as(?i32, 9000), opts.mtu_length);
}

test "printUsage outputs help text" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try printUsage(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stat") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "errors") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "loss") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--aeron-dir=PATH") != null);
}

test "parse: invalid term buffer length returns null" {
    const args = &[_][]const u8{ "aeron", "-Daeron.term.buffer.length=not_a_number" };
    const opts = parse(args);
    try std.testing.expectEqual(@as(?i32, null), opts.term_buffer_length);
}
