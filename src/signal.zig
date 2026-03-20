const std = @import("std");

pub var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

pub fn install() void {
    const handler = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &handler, null);
    std.posix.sigaction(std.posix.SIG.INT, &handler, null);
}

fn handleSignal(_: c_int) callconv(.c) void {
    running.store(false, .release);
}

pub fn isRunning() bool {
    return running.load(.acquire);
}

// ============================================================================
// UNIT TESTS
// ============================================================================

const testing = std.testing;

test "signal: initial state is true" {
    // Reset to known state
    running.store(true, .release);
    try testing.expect(running.load(.acquire) == true);
}

test "signal: store and load" {
    running.store(false, .release);
    try testing.expect(running.load(.acquire) == false);
    running.store(true, .release);
    try testing.expect(running.load(.acquire) == true);
}

test "signal: isRunning reflects state" {
    running.store(true, .release);
    try testing.expect(isRunning() == true);
    running.store(false, .release);
    try testing.expect(isRunning() == false);
}
