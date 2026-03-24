// LESSON(conductor/aeron): CnC (Command and Control) file reader and descriptor.
// LESSON(conductor/zig): Maps the driver's shared memory to read counters, errors, loss reports, and events.
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const counters_mod = @import("ipc/counters.zig");
const driver_cnc = @import("driver/cnc.zig");

/// CnC (Command and Control) file descriptor.
/// Manages paths to driver shared memory files (cnc.dat, error.log, loss-report.dat, etc).
pub const CncDescriptor = struct {
    aeron_dir: []const u8,

    pub const MappedCounters = struct {
        cnc_file: driver_cnc.CncFile,
        counters_map: counters_mod.CountersMap,

        pub fn deinit(self: *MappedCounters) void {
            self.cnc_file.deinit();
        }
    };

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

    pub fn openMappedCounters(self: CncDescriptor, allocator: std.mem.Allocator) !MappedCounters {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const preferred_path = self.cncFilePath(&path_buf);

        var cnc_file = driver_cnc.CncFile.open(allocator, preferred_path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const legacy_path = self.legacyCncFilePath(&path_buf);
                break :blk try driver_cnc.CncFile.open(allocator, legacy_path);
            },
            else => return err,
        };

        return .{
            .counters_map = counters_mod.CountersMap.init(cnc_file.countersMetadataBuffer(), cnc_file.countersValuesBuffer()),
            .cnc_file = cnc_file,
        };
    }

    /// Get the path to the CnC file
    pub fn cncFilePath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/CnC.dat", .{self.aeron_dir}) catch self.aeron_dir;
    }

    /// Get the path to the error log
    pub fn errorLogPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/error.log", .{self.aeron_dir}) catch self.aeron_dir;
    }

    /// Get the path to the loss report
    pub fn lossReportPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/loss-report.dat", .{self.aeron_dir}) catch self.aeron_dir;
    }

    fn legacyCncFilePath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/cnc.dat", .{self.aeron_dir}) catch self.aeron_dir;
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
    try std.testing.expectEqualStrings("/dev/shm/aeron/CnC.dat", path);
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
    try std.testing.expectEqualStrings("/tmp/aeron/CnC.dat", cnc_path);

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

test "CncDescriptor: openMappedCounters opens live CnC.dat" {
    const allocator = std.testing.allocator;
    const aeron_dir = "/tmp/harus-aeron-cnc-open";
    defer std.fs.deleteTreeAbsolute(aeron_dir) catch {};
    try std.fs.makeDirAbsolute(aeron_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/CnC.dat", .{aeron_dir});
    defer allocator.free(path);

    var cnc = try driver_cnc.CncFile.create(allocator, path, .{
        .to_driver_buffer_length = 1024,
        .to_clients_buffer_length = 1024,
        .counters_metadata_buffer_length = counters_mod.METADATA_LENGTH * 2,
        .counters_values_buffer_length = counters_mod.COUNTER_LENGTH * 2,
        .client_liveness_timeout_ns = 5_000_000_000,
    });
    cnc.deinit();

    const desc = CncDescriptor.init(aeron_dir);
    var mapped = try desc.openMappedCounters(allocator);
    defer mapped.deinit();

    try std.testing.expect(mapped.counters_map.max_counters >= 2);
}
