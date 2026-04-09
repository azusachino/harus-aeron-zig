// cnc.dat (Command 'n' Control) file — the rendezvous point between Aeron clients and driver.
// LESSON(conductor): We mmap a file and cast a pointer to our header struct. The file
// acts as shared memory between processes without needing SysV IPC or POSIX shm_open. See docs/tutorial/03-driver/03-conductor.md
// LESSON(conductor): cnc.dat has a fixed header (4096 bytes) followed immediately by
// the to-driver ring buffer and to-clients broadcast buffer. Java clients find these by
// reading the length fields from the header and computing byte offsets. See docs/tutorial/03-driver/03-conductor.md

const std = @import("std");

// Version number at offset 0 — SemanticVersion encoding: (major<<16)|(minor<<8)|patch
// CnC FILE FORMAT version is 0.2.0, NOT the Aeron library version.
// Java: CncFileDescriptor.CNC_VERSION = SemanticVersion.compose(0, 2, 0) = 0x00000200 = 512
// Spec confirms: bytes [00 02 00 00] at offset 0 (little-endian i32 = 512 = 0x0200)
// checkVersion() checks major equality only: major = (value>>16)&0xFF
// See: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/CncFileDescriptor.java
pub const CNC_VERSION: i32 = (0 << 16) | (2 << 8) | 0; // = 512 = 0x00000200

// Agrona trailer sizes that must be added to data capacity.
// ManyToOneRingBuffer (to-driver): 6 cache-line trailer = 6*128 = 768 bytes
// BroadcastTransmitter (to-clients): 1 cache-line trailer = 128 bytes
pub const RING_BUFFER_TRAILER_LENGTH: i32 = 768;
pub const BROADCAST_BUFFER_TRAILER_LENGTH: i32 = 128;

pub const CncConfig = struct {
    to_driver_buffer_length: i32,
    to_clients_buffer_length: i32,
    counters_metadata_buffer_length: i32,
    counters_values_buffer_length: i32,
    error_log_buffer_length: i32,
    client_liveness_timeout_ns: i64,
    start_timestamp_ms: i64,
    driver_pid: i64,
};

// Header layout — matches io.aeron.CncFileDescriptor offsets exactly
// Java static block (CncFileDescriptor):
//   VERSION=0, TO_DRIVER=4, TO_CLIENTS=8, COUNTERS_META=12,
//   COUNTERS_VALUES=16, ERROR_LOG=20, CLIENT_LIVENESS=24 (i64),
//   START_TIMESTAMP=32 (i64), PID=40 (i64), FILE_PAGE_SIZE=48 (i32)
//   END_OF_METADATA_OFFSET = align(52, 128) = 128
// Spec confirms: 48 bytes of fields, padded to 128 bytes. Total file = 8392704.
pub const CNC_HEADER_SIZE = 128; // END_OF_METADATA_OFFSET — NOT 4096!
pub const VERSION_OFFSET = 0; // i32
pub const TO_DRIVER_BUF_LEN_OFFSET = 4; // i32
pub const TO_CLIENTS_BUF_LEN_OFFSET = 8; // i32
pub const COUNTERS_META_BUF_LEN_OFFSET = 12; // i32
pub const COUNTERS_VAL_BUF_LEN_OFFSET = 16; // i32
pub const ERROR_LOG_BUF_LEN_OFFSET = 20; // i32
pub const CLIENT_LIVENESS_TIMEOUT_OFFSET = 24; // i64
pub const START_TIMESTAMP_OFFSET = 32; // i64
pub const PID_OFFSET = 40; // i64
pub const FILE_PAGE_SIZE_OFFSET = 48; // i32
pub const CONSUMER_HEARTBEAT_OFFSET = 640;

pub const CncFile = struct {
    mapped: []align(std.heap.page_size_min) u8,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, cfg: CncConfig) !CncFile {
        const total = CNC_HEADER_SIZE +
            @as(usize, @intCast(cfg.to_driver_buffer_length)) +
            @as(usize, @intCast(cfg.to_clients_buffer_length)) +
            @as(usize, @intCast(cfg.counters_metadata_buffer_length)) +
            @as(usize, @intCast(cfg.counters_values_buffer_length)) +
            @as(usize, @intCast(cfg.error_log_buffer_length));

        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        defer file.close();
        try file.setEndPos(total);

        const ptr = try std.posix.mmap(null, total, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, file.handle, 0);
        const mapped = @as([*]align(std.heap.page_size_min) u8, @ptrCast(ptr))[0..total];
        @memset(mapped, 0);

        // Write header fields
        std.mem.writeInt(i32, mapped[VERSION_OFFSET..][0..4], CNC_VERSION, .little);
        std.mem.writeInt(i32, mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], cfg.to_driver_buffer_length, .little);
        std.mem.writeInt(i32, mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], cfg.to_clients_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], cfg.counters_metadata_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_VAL_BUF_LEN_OFFSET..][0..4], cfg.counters_values_buffer_length, .little);
        std.mem.writeInt(i32, mapped[ERROR_LOG_BUF_LEN_OFFSET..][0..4], cfg.error_log_buffer_length, .little);
        std.mem.writeInt(i64, mapped[CLIENT_LIVENESS_TIMEOUT_OFFSET..][0..8], cfg.client_liveness_timeout_ns, .little);
        std.mem.writeInt(i64, mapped[START_TIMESTAMP_OFFSET..][0..8], cfg.start_timestamp_ms, .little);
        std.mem.writeInt(i64, mapped[PID_OFFSET..][0..8], cfg.driver_pid, .little);
        std.mem.writeInt(i32, mapped[FILE_PAGE_SIZE_OFFSET..][0..4], 4096, .little);

        return CncFile{
            .mapped = mapped,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !CncFile {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        defer file.close();
        const stat = try file.stat();
        const total = stat.size;

        const ptr = try std.posix.mmap(null, total, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, file.handle, 0);
        const mapped = @as([*]align(std.heap.page_size_min) u8, @ptrCast(ptr))[0..total];

        return CncFile{
            .mapped = mapped,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CncFile) void {
        std.posix.munmap(self.mapped);
        self.allocator.free(self.path);
    }

    // Write epoch-ms timestamp to the ring buffer trailer's CONSUMER_HEARTBEAT slot.
    // Java Aeron client checks this field to verify the driver is alive before connecting.
    // Layout: toDriverBuffer[data_capacity + 640], where:
    //   data_capacity = to_driver_buffer_length - RING_BUFFER_TRAILER_LENGTH = 1MB
    //   640 = CONSUMER_HEARTBEAT_OFFSET (5th 128-byte slot in the 768-byte trailer)
    pub fn setDriverHeartbeat(self: *CncFile, epoch_ms: i64) void {
        const data_capacity = @as(usize, @intCast(self.toDriverBufferLength())) - @as(usize, RING_BUFFER_TRAILER_LENGTH);
        const heartbeat_off = CNC_HEADER_SIZE + data_capacity + CONSUMER_HEARTBEAT_OFFSET;
        std.mem.writeInt(i64, self.mapped[heartbeat_off..][0..8], epoch_ms, .little);
    }

    pub fn getDriverHeartbeat(self: *const CncFile) i64 {
        const data_capacity = @as(usize, @intCast(self.toDriverBufferLength())) - @as(usize, RING_BUFFER_TRAILER_LENGTH);
        const heartbeat_off = CNC_HEADER_SIZE + data_capacity + CONSUMER_HEARTBEAT_OFFSET;
        return std.mem.readInt(i64, self.mapped[heartbeat_off..][0..8], .little);
    }

    pub fn version(self: *const CncFile) i32 {
        return std.mem.readInt(i32, self.mapped[VERSION_OFFSET..][0..4], .little);
    }

    pub fn toDriverBufferLength(self: *const CncFile) i32 {
        return std.mem.readInt(i32, self.mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], .little);
    }

    pub fn toDriverBuffer(self: *CncFile) []u8 {
        const len = @as(usize, @intCast(self.toDriverBufferLength()));
        return self.mapped[CNC_HEADER_SIZE..][0..len];
    }

    pub fn totalLength(self: *const CncFile) usize {
        return self.mapped.len;
    }

    pub fn toClientsBuffer(self: *CncFile) []u8 {
        const off = CNC_HEADER_SIZE + @as(usize, @intCast(self.toDriverBufferLength()));
        const len = @as(usize, @intCast(std.mem.readInt(i32, self.mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], .little)));
        return self.mapped[off..][0..len];
    }

    pub fn countersMetadataBuffer(self: *CncFile) []u8 {
        const off = CNC_HEADER_SIZE +
            @as(usize, @intCast(self.toDriverBufferLength())) +
            @as(usize, @intCast(std.mem.readInt(i32, self.mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], .little)));
        const len = @as(usize, @intCast(std.mem.readInt(i32, self.mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], .little)));
        return self.mapped[off..][0..len];
    }

    pub fn countersValuesBuffer(self: *CncFile) []u8 {
        const off = CNC_HEADER_SIZE +
            @as(usize, @intCast(self.toDriverBufferLength())) +
            @as(usize, @intCast(std.mem.readInt(i32, self.mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], .little))) +
            @as(usize, @intCast(std.mem.readInt(i32, self.mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], .little)));
        const len = @as(usize, @intCast(std.mem.readInt(i32, self.mapped[COUNTERS_VAL_BUF_LEN_OFFSET..][0..4], .little)));
        return self.mapped[off..][0..len];
    }
};

test "CnC: file created with correct magic, version, and buffer sizes" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-cnc.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const cfg = CncConfig{
        .to_driver_buffer_length = 1024 * 1024 + RING_BUFFER_TRAILER_LENGTH,
        .to_clients_buffer_length = 1024 * 1024 + BROADCAST_BUFFER_TRAILER_LENGTH,
        .counters_metadata_buffer_length = 4 * 1024 * 1024,
        .counters_values_buffer_length = 1024 * 1024,
        .error_log_buffer_length = 1024 * 1024,
        .client_liveness_timeout_ns = 5_000_000_000,
        .start_timestamp_ms = 0,
        .driver_pid = 0,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    // CNC_VERSION at offset 0 (4 bytes, semantic version [major:8][minor:8][patch:8][unused:8])
    try std.testing.expectEqual(@as(i32, CNC_VERSION), cnc.version());
    // Buffer lengths readable
    try std.testing.expectEqual(cfg.to_driver_buffer_length, cnc.toDriverBufferLength());
}

test "CnC: metadata header fields match descriptor offsets" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-cnc-header.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const cfg = CncConfig{
        .to_driver_buffer_length = 1024 * 1024 + RING_BUFFER_TRAILER_LENGTH,
        .to_clients_buffer_length = 1024 * 1024 + BROADCAST_BUFFER_TRAILER_LENGTH,
        .counters_metadata_buffer_length = 4 * 1024 * 1024,
        .counters_values_buffer_length = 1024 * 1024,
        .error_log_buffer_length = 1024 * 1024,
        .client_liveness_timeout_ns = 5_000_000_000,
        .start_timestamp_ms = 123456789,
        .driver_pid = 4242,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    try std.testing.expectEqual(@as(i32, CNC_VERSION), std.mem.readInt(i32, cnc.mapped[VERSION_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.to_driver_buffer_length, std.mem.readInt(i32, cnc.mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.to_clients_buffer_length, std.mem.readInt(i32, cnc.mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.counters_metadata_buffer_length, std.mem.readInt(i32, cnc.mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.counters_values_buffer_length, std.mem.readInt(i32, cnc.mapped[COUNTERS_VAL_BUF_LEN_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.error_log_buffer_length, std.mem.readInt(i32, cnc.mapped[ERROR_LOG_BUF_LEN_OFFSET..][0..4], .little));
    try std.testing.expectEqual(cfg.client_liveness_timeout_ns, std.mem.readInt(i64, cnc.mapped[CLIENT_LIVENESS_TIMEOUT_OFFSET..][0..8], .little));
    try std.testing.expectEqual(cfg.start_timestamp_ms, std.mem.readInt(i64, cnc.mapped[START_TIMESTAMP_OFFSET..][0..8], .little));
    try std.testing.expectEqual(cfg.driver_pid, std.mem.readInt(i64, cnc.mapped[PID_OFFSET..][0..8], .little));
    try std.testing.expectEqual(@as(i32, 4096), std.mem.readInt(i32, cnc.mapped[FILE_PAGE_SIZE_OFFSET..][0..4], .little));
}

test "CnC: section offsets and total size match configured layout" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-cnc-offsets.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const cfg = CncConfig{
        .to_driver_buffer_length = 4096 + RING_BUFFER_TRAILER_LENGTH,
        .to_clients_buffer_length = 8192 + BROADCAST_BUFFER_TRAILER_LENGTH,
        .counters_metadata_buffer_length = 16 * 1024,
        .counters_values_buffer_length = 8 * 1024,
        .error_log_buffer_length = 4 * 1024,
        .client_liveness_timeout_ns = 10,
        .start_timestamp_ms = 20,
        .driver_pid = 30,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    const to_driver_start = CNC_HEADER_SIZE;
    const to_clients_start = to_driver_start + @as(usize, @intCast(cfg.to_driver_buffer_length));
    const counters_meta_start = to_clients_start + @as(usize, @intCast(cfg.to_clients_buffer_length));
    const counters_values_start = counters_meta_start + @as(usize, @intCast(cfg.counters_metadata_buffer_length));
    const expected_total = counters_values_start + @as(usize, @intCast(cfg.counters_values_buffer_length)) + @as(usize, @intCast(cfg.error_log_buffer_length));

    try std.testing.expectEqual(expected_total, cnc.totalLength());
    try std.testing.expectEqual(@intFromPtr(cnc.mapped.ptr) + to_driver_start, @intFromPtr(cnc.toDriverBuffer().ptr));
    try std.testing.expectEqual(@intFromPtr(cnc.mapped.ptr) + to_clients_start, @intFromPtr(cnc.toClientsBuffer().ptr));
    try std.testing.expectEqual(@intFromPtr(cnc.mapped.ptr) + counters_meta_start, @intFromPtr(cnc.countersMetadataBuffer().ptr));
    try std.testing.expectEqual(@intFromPtr(cnc.mapped.ptr) + counters_values_start, @intFromPtr(cnc.countersValuesBuffer().ptr));
}

test "CnC: setDriverHeartbeat writes to consumer heartbeat slot" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-cnc-heartbeat.dat";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const cfg = CncConfig{
        .to_driver_buffer_length = 1024 * 1024 + RING_BUFFER_TRAILER_LENGTH,
        .to_clients_buffer_length = 1024 + BROADCAST_BUFFER_TRAILER_LENGTH,
        .counters_metadata_buffer_length = 1024,
        .counters_values_buffer_length = 1024,
        .error_log_buffer_length = 1024,
        .client_liveness_timeout_ns = 1,
        .start_timestamp_ms = 2,
        .driver_pid = 3,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    cnc.setDriverHeartbeat(987654321);
    const data_capacity = @as(usize, @intCast(cfg.to_driver_buffer_length - RING_BUFFER_TRAILER_LENGTH));
    const heartbeat_off = CNC_HEADER_SIZE + data_capacity + CONSUMER_HEARTBEAT_OFFSET;
    try std.testing.expectEqual(@as(i64, 987654321), std.mem.readInt(i64, cnc.mapped[heartbeat_off..][0..8], .little));
}
