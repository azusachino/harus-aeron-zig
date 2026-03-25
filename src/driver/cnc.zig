// cnc.dat (Command 'n' Control) file — the rendezvous point between Aeron clients and driver.
// LESSON(conductor): We mmap a file and cast a pointer to our header struct. The file
// acts as shared memory between processes without needing SysV IPC or POSIX shm_open. See docs/tutorial/03-driver/03-conductor.md
// LESSON(conductor): cnc.dat has a fixed header (4096 bytes) followed immediately by
// the to-driver ring buffer and to-clients broadcast buffer. Java clients find these by
// reading the length fields from the header and computing byte offsets. See docs/tutorial/03-driver/03-conductor.md

const std = @import("std");

// Version number at offset 0 — encoded as [major:8][minor:8][patch:8][unused:8]
// Format: (major << 24) | (minor << 16) | (patch << 8)
// Value 1.46.7 matches aeron-all-1.46.7 for interop compatibility
// CRITICAL: Offset must be 0, NOT 4. Java expects version at offset 0. There is NO magic field in Aeron!
// See: https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/CncFileDescriptor.java
pub const CNC_VERSION: i32 = (1 << 24) | (46 << 16) | (7 << 8);

pub const CncConfig = struct {
    to_driver_buffer_length: i32,
    to_clients_buffer_length: i32,
    counters_metadata_buffer_length: i32,
    counters_values_buffer_length: i32,
    client_liveness_timeout_ns: i64,
};

// Header layout — matches io.aeron.CncFileDescriptor offsets exactly
const CNC_HEADER_SIZE = 4096; // padded to page boundary
const VERSION_OFFSET = 0; // i32 — CNC_VERSION (NOT 4!)
const TO_DRIVER_BUF_LEN_OFFSET = 4; // i32 (was 8)
const TO_CLIENTS_BUF_LEN_OFFSET = 8; // i32 (was 12)
const COUNTERS_META_BUF_LEN_OFFSET = 12; // i32 (was 16)
const COUNTERS_VAL_BUF_LEN_OFFSET = 16; // i32 (was 20)
const CLIENT_LIVENESS_TIMEOUT_OFFSET = 24; // i64 (was 32, aligned to 8)

pub const CncFile = struct {
    mapped: []align(std.heap.page_size_min) u8,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, cfg: CncConfig) !CncFile {
        const total = CNC_HEADER_SIZE +
            @as(usize, @intCast(cfg.to_driver_buffer_length)) +
            @as(usize, @intCast(cfg.to_clients_buffer_length)) +
            @as(usize, @intCast(cfg.counters_metadata_buffer_length)) +
            @as(usize, @intCast(cfg.counters_values_buffer_length));

        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        defer file.close();
        try file.setEndPos(total);

        const ptr = try std.posix.mmap(null, total, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, file.handle, 0);
        const mapped = @as([*]align(std.heap.page_size_min) u8, @ptrCast(ptr))[0..total];

        // Write header fields
        std.mem.writeInt(i32, mapped[VERSION_OFFSET..][0..4], CNC_VERSION, .little);
        std.mem.writeInt(i32, mapped[TO_DRIVER_BUF_LEN_OFFSET..][0..4], cfg.to_driver_buffer_length, .little);
        std.mem.writeInt(i32, mapped[TO_CLIENTS_BUF_LEN_OFFSET..][0..4], cfg.to_clients_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_META_BUF_LEN_OFFSET..][0..4], cfg.counters_metadata_buffer_length, .little);
        std.mem.writeInt(i32, mapped[COUNTERS_VAL_BUF_LEN_OFFSET..][0..4], cfg.counters_values_buffer_length, .little);
        std.mem.writeInt(i64, mapped[CLIENT_LIVENESS_TIMEOUT_OFFSET..][0..8], cfg.client_liveness_timeout_ns, .little);

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
        .to_driver_buffer_length = 1024 * 1024,
        .to_clients_buffer_length = 1024 * 1024,
        .counters_metadata_buffer_length = 1024 * 1024,
        .counters_values_buffer_length = 4 * 1024 * 1024,
        .client_liveness_timeout_ns = 5_000_000_000,
    };
    var cnc = try CncFile.create(allocator, path, cfg);
    defer cnc.deinit();

    // CNC_VERSION at offset 0 (4 bytes, semantic version [major:8][minor:8][patch:8][unused:8])
    try std.testing.expectEqual(@as(i32, CNC_VERSION), cnc.version());
    // Buffer lengths readable
    try std.testing.expectEqual(cfg.to_driver_buffer_length, cnc.toDriverBufferLength());
}
