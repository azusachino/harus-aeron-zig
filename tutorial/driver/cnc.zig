// EXERCISE: Chapter 3.3 — Command and Control (CnC)
// Reference: docs/tutorial/03-driver/C-6-conductor.md
//
// Your task: implement `CncFile.create` to memory-map the CnC file
// and write the appropriate header fields.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const CNC_MAGIC: i32 = 0x4e445253;
pub const CNC_VERSION: i32 = 207;

pub const CncConfig = struct {
    to_driver_buffer_length: i32,
    to_clients_buffer_length: i32,
    counters_metadata_buffer_length: i32,
    counters_values_buffer_length: i32,
    client_liveness_timeout_ns: i64,
};

const CNC_HEADER_SIZE = 4096;
const MAGIC_OFFSET = 0;
const VERSION_OFFSET = 4;
const TO_DRIVER_BUF_LEN_OFFSET = 8;
const TO_CLIENTS_BUF_LEN_OFFSET = 12;
const COUNTERS_META_BUF_LEN_OFFSET = 16;
const COUNTERS_VAL_BUF_LEN_OFFSET = 20;
const CLIENT_LIVENESS_TIMEOUT_OFFSET = 32;

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
        std.mem.writeInt(i32, mapped[MAGIC_OFFSET..][0..4], CNC_MAGIC, .little);
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

    pub fn deinit(self: *CncFile) void {
        std.posix.munmap(self.mapped);
        self.allocator.free(self.path);
    }
};

test "CncFile learner stub" {
    // Tests for learner stub
}
