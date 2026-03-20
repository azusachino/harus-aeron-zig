// CnC (Command and Control) file reader and descriptor.
// Maps the driver's shared memory to read counters, errors, loss reports, and events.
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const counters_mod = @import("ipc/counters.zig");

/// CnC (Command and Control) file descriptor.
/// Manages paths to driver shared memory files (cnc.dat, error.log, loss-report.dat, etc).
pub const CncDescriptor = struct {
    aeron_dir: []const u8,

    pub fn init(aeron_dir: []const u8) CncDescriptor {
        return .{ .aeron_dir = aeron_dir };
    }

    /// Load counters from the CnC file.
    /// For now, returns a placeholder CountersMap since real mmap requires the driver
    /// to be running and the CnC file layout to match.
    pub fn loadCounters(self: CncDescriptor, meta_buf: []u8, values_buf: []u8) counters_mod.CountersMap {
        _ = self;
        return counters_mod.CountersMap.init(meta_buf, values_buf);
    }

    /// Get the path to the CnC file
    pub fn cncFilePath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/cnc.dat", .{self.aeron_dir}) catch self.aeron_dir;
    }

    /// Get the path to the error log
    pub fn errorLogPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/error.log", .{self.aeron_dir}) catch self.aeron_dir;
    }

    /// Get the path to the loss report
    pub fn lossReportPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/loss-report.dat", .{self.aeron_dir}) catch self.aeron_dir;
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "CncDescriptor: init" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    try std.testing.expectEqualStrings("/dev/shm/aeron", desc.aeron_dir);
}

test "CncDescriptor: cncFilePath" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.cncFilePath(&buf);
    try std.testing.expectEqualStrings("/dev/shm/aeron/cnc.dat", path);
}

test "CncDescriptor: errorLogPath" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.errorLogPath(&buf);
    try std.testing.expectEqualStrings("/dev/shm/aeron/error.log", path);
}

test "CncDescriptor: lossReportPath" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.lossReportPath(&buf);
    try std.testing.expectEqualStrings("/dev/shm/aeron/loss-report.dat", path);
}

test "CncDescriptor: paths with various aeron_dirs" {
    const desc = CncDescriptor.init("/tmp/aeron");
    var buf: [256]u8 = undefined;

    const cnc_path = desc.cncFilePath(&buf);
    try std.testing.expectEqualStrings("/tmp/aeron/cnc.dat", cnc_path);

    const err_path = desc.errorLogPath(&buf);
    try std.testing.expectEqualStrings("/tmp/aeron/error.log", err_path);

    const loss_path = desc.lossReportPath(&buf);
    try std.testing.expectEqualStrings("/tmp/aeron/loss-report.dat", loss_path);
}

test "CncDescriptor: loadCounters returns valid CountersMap" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var meta align(64) = [_]u8{0} ** (counters_mod.METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (counters_mod.COUNTER_LENGTH * 4);

    const cm = desc.loadCounters(&meta, &values);
    try std.testing.expect(cm.max_counters > 0);
}
