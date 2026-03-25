// LESSON(conductor/aeron): CnC (Command and Control) file reader and descriptor.
// LESSON(conductor/zig): Maps the driver's shared memory to read counters, errors, loss reports, and events.
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");
const counters_mod = @import("ipc/counters.zig");
const driver_cnc = @import("driver/cnc.zig");

/// Metadata read from the CnC file header.
pub const CncMetadata = struct {
    magic: i32,
    version: i32,
    to_driver_buffer_length: i32,
    client_liveness_timeout_ns: i64,
};

/// CnC (Command and Control) file descriptor.
/// Manages paths to driver shared memory files (cnc.dat, error.log, loss-report.dat, etc).
/// Also provides methods to read version and metadata from the CnC file.
pub const CncDescriptor = struct {
    aeron_dir: []const u8,

    pub const MappedCounters = struct {
        cnc_file: driver_cnc.CncFile,
        counters_map: counters_mod.CountersMap,

        pub fn deinit(self: *MappedCounters) void {
            self.cnc_file.deinit();
        }

        /// Read metadata from the mapped CnC header.
        pub fn metadata(self: *const MappedCounters) CncMetadata {
            return .{
                .magic = self.cnc_file.magic(),
                .version = self.cnc_file.version(),
                .to_driver_buffer_length = self.cnc_file.toDriverBufferLength(),
                .client_liveness_timeout_ns = 0, // not yet in CncFile header
            };
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

    /// Get version from the mapped CnC file.
    /// Returns version number or 0 if file not accessible.
    pub fn getCncVersion(self: CncDescriptor, allocator: std.mem.Allocator) i32 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const preferred_path = self.cncFilePath(&path_buf);

        var cnc_file = driver_cnc.CncFile.open(allocator, preferred_path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const legacy_path = self.legacyCncFilePath(&path_buf);
                break :blk driver_cnc.CncFile.open(allocator, legacy_path) catch return 0;
            },
            else => return 0,
        };
        defer cnc_file.deinit();
        return cnc_file.version();
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

    /// Get the path to the driver event log
    pub fn eventLogPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/event.log", .{self.aeron_dir}) catch self.aeron_dir;
    }

    /// Get the path to a cluster members file (if cluster is running)
    pub fn clusterMembersPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/cluster-members.dat", .{self.aeron_dir}) catch self.aeron_dir;
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

test "CncDescriptor: eventLogPath" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.eventLogPath(&buf);
    try std.testing.expectEqualStrings("/dev/shm/aeron/event.log", path);
}

test "CncDescriptor: MappedCounters metadata reads version and magic" {
    const allocator = std.testing.allocator;
    const aeron_dir = "/tmp/harus-aeron-cnc-meta";
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

    const meta = mapped.metadata();
    try std.testing.expectEqual(driver_cnc.CNC_MAGIC, meta.magic);
    try std.testing.expectEqual(driver_cnc.CNC_VERSION, meta.version);
    try std.testing.expect(meta.to_driver_buffer_length > 0);
}

test "CncDescriptor: getCncVersion reads from live CnC file" {
    const allocator = std.testing.allocator;
    const aeron_dir = "/tmp/harus-aeron-cnc-version";
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
    const version = desc.getCncVersion(allocator);
    try std.testing.expectEqual(@as(i32, driver_cnc.CNC_VERSION), version);
}

test "CncDescriptor: clusterMembersPath" {
    const desc = CncDescriptor.init("/dev/shm/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.clusterMembersPath(&buf);
    try std.testing.expectEqualStrings("/dev/shm/aeron/cluster-members.dat", path);
}
