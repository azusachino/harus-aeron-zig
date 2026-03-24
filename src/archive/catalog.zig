// Aeron Archive Recording Catalog
// Maps recording_id → RecordingDescriptorEntry
// Reference: https://github.com/aeron-io/aeron/blob/master/aeron-archive/src/main/java/io/aeron/archive/Catalog.java

const std = @import("std");

/// Fixed-size recording descriptor entry (1024 bytes on disk)
pub const RecordingDescriptorEntry = extern struct {
    recording_id: i64,
    start_timestamp: i64,
    stop_timestamp: i64, // 0 = still recording
    start_position: i64,
    stop_position: i64,
    initial_term_id: i32,
    segment_file_length: i32,
    term_buffer_length: i32,
    mtu_length: i32,
    session_id: i32,
    stream_id: i32,
    channel_length: i32,
    channel: [256]u8,
    source_identity_length: i32,
    source_identity: [256]u8,
    _reserved: [440]u8, // padding to 1024 bytes (1024 - 584 = 440)

    comptime {
        std.debug.assert(@sizeOf(RecordingDescriptorEntry) == 1024);
    }
};

/// In-memory recording catalog
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(RecordingDescriptorEntry),
    next_recording_id: i64,
    path: ?[]u8,

    /// Initialize a new catalog
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return Catalog{
            .allocator = allocator,
            .entries = .{},
            .next_recording_id = 1,
            .path = null,
        };
    }

    /// Initialize a catalog that persists its entries under the given archive directory.
    pub fn initWithArchiveDir(allocator: std.mem.Allocator, archive_dir: []const u8) !Catalog {
        try std.fs.cwd().makePath(archive_dir);

        const path = try std.fmt.allocPrint(allocator, "{s}/catalog.dat", .{archive_dir});
        errdefer allocator.free(path);

        var catalog = Catalog{
            .allocator = allocator,
            .entries = .{},
            .next_recording_id = 1,
            .path = path,
        };
        errdefer catalog.deinit();

        try catalog.loadFromDisk();
        return catalog;
    }

    /// Free catalog resources
    pub fn deinit(self: *Catalog) void {
        self.entries.deinit(self.allocator);
        if (self.path) |path| {
            self.allocator.free(path);
        }
    }

    /// Add a new recording and return its recording_id
    pub fn addNewRecording(
        self: *Catalog,
        session_id: i32,
        stream_id: i32,
        channel: []const u8,
        source_identity: []const u8,
        initial_term_id: i32,
        segment_file_length: i32,
        term_buffer_length: i32,
        mtu_length: i32,
        start_position: i64,
        start_timestamp: i64,
    ) !i64 {
        var entry: RecordingDescriptorEntry = undefined;
        @memset(std.mem.asBytes(&entry), 0);

        entry.recording_id = self.next_recording_id;
        entry.session_id = session_id;
        entry.stream_id = stream_id;
        entry.initial_term_id = initial_term_id;
        entry.segment_file_length = segment_file_length;
        entry.term_buffer_length = term_buffer_length;
        entry.mtu_length = mtu_length;
        entry.start_position = start_position;
        entry.start_timestamp = start_timestamp;
        entry.stop_timestamp = 0;
        entry.stop_position = 0;

        // Copy channel
        if (channel.len > 256) return error.ChannelTooLong;
        @memcpy(entry.channel[0..channel.len], channel);
        entry.channel_length = @intCast(channel.len);

        // Copy source identity
        if (source_identity.len > 256) return error.SourceIdentityTooLong;
        @memcpy(entry.source_identity[0..source_identity.len], source_identity);
        entry.source_identity_length = @intCast(source_identity.len);

        try self.entries.append(self.allocator, entry);
        const recording_id = self.next_recording_id;
        self.next_recording_id += 1;
        try self.persist();
        return recording_id;
    }

    /// Update stop position for a recording
    pub fn updateStopPosition(self: *Catalog, recording_id: i64, stop_position: i64) !void {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                entry.stop_position = stop_position;
                try self.persist();
                return;
            }
        }
    }

    /// Update stop timestamp for a recording
    pub fn updateStopTimestamp(self: *Catalog, recording_id: i64, stop_timestamp: i64) !void {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                entry.stop_timestamp = stop_timestamp;
                try self.persist();
                return;
            }
        }
    }

    /// Update final stop state for a recording in a single persisted write.
    pub fn updateStopState(self: *Catalog, recording_id: i64, stop_position: i64, stop_timestamp: i64) !void {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                entry.stop_position = stop_position;
                entry.stop_timestamp = stop_timestamp;
                try self.persist();
                return;
            }
        }
    }

    /// Lookup recording descriptor by ID
    pub fn recordingDescriptor(self: *const Catalog, recording_id: i64) ?*const RecordingDescriptorEntry {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                return entry;
            }
        }
        return null;
    }

    /// List recordings in range, calling handler for each
    /// Returns count of entries processed
    pub fn listRecordings(
        self: *const Catalog,
        from_id: i64,
        count: i32,
        handler: *const fn (entry: *const RecordingDescriptorEntry) void,
    ) i32 {
        var processed: i32 = 0;
        for (self.entries.items) |*entry| {
            if (entry.recording_id >= from_id and processed < count) {
                handler(entry);
                processed += 1;
            }
        }
        return processed;
    }

    /// Find last matching recording by channel and stream_id
    /// Returns recording_id or null if not found
    pub fn findLastMatchingRecording(
        self: *const Catalog,
        min_id: i64,
        channel: []const u8,
        stream_id: i32,
    ) ?i64 {
        var result: ?i64 = null;
        for (self.entries.items) |entry| {
            if (entry.recording_id >= min_id and
                entry.stream_id == stream_id and
                @as(usize, @intCast(entry.channel_length)) == channel.len and
                std.mem.eql(u8, entry.channel[0..@intCast(entry.channel_length)], channel))
            {
                result = entry.recording_id;
            }
        }
        return result;
    }

    /// Extract channel string from entry
    pub fn copyChannel(entry: *const RecordingDescriptorEntry) []const u8 {
        return entry.channel[0..@intCast(entry.channel_length)];
    }

    /// Extract source identity string from entry
    pub fn copySourceIdentity(entry: *const RecordingDescriptorEntry) []const u8 {
        return entry.source_identity[0..@intCast(entry.source_identity_length)];
    }

    fn loadFromDisk(self: *Catalog) !void {
        const path = self.path orelse return;
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const file_size = (try file.stat()).size;
        if (file_size == 0) {
            return;
        }
        if (file_size % @sizeOf(RecordingDescriptorEntry) != 0) {
            return error.CorruptCatalog;
        }

        const bytes = try file.readToEndAlloc(self.allocator, file_size);
        defer self.allocator.free(bytes);

        var offset: usize = 0;
        var max_recording_id: i64 = 0;
        while (offset < bytes.len) : (offset += @sizeOf(RecordingDescriptorEntry)) {
            var entry: RecordingDescriptorEntry = undefined;
            @memcpy(std.mem.asBytes(&entry), bytes[offset .. offset + @sizeOf(RecordingDescriptorEntry)]);
            try self.entries.append(self.allocator, entry);
            max_recording_id = @max(max_recording_id, entry.recording_id);
        }
        self.next_recording_id = max_recording_id + 1;
    }

    fn persist(self: *Catalog) !void {
        const path = self.path orelse return;
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        if (self.entries.items.len > 0) {
            try file.writeAll(std.mem.sliceAsBytes(self.entries.items));
        }
        try file.sync();
    }
};

// Tests
test "RecordingDescriptorEntry is exactly 1024 bytes" {
    try std.testing.expectEqual(1024, @sizeOf(RecordingDescriptorEntry));
}

test "addNewRecording returns sequential IDs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    const id1 = try catalog.addNewRecording(1, 1, "aeron:udp", "test1", 0, 0, 0, 0, 0, 0);
    const id2 = try catalog.addNewRecording(2, 2, "aeron:udp", "test2", 0, 0, 0, 0, 0, 0);
    const id3 = try catalog.addNewRecording(3, 3, "aeron:udp", "test3", 0, 0, 0, 0, 0, 0);

    try std.testing.expectEqual(1, id1);
    try std.testing.expectEqual(2, id2);
    try std.testing.expectEqual(3, id3);
}

test "recordingDescriptor lookup by ID" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 10, "ch1", "src1", 0, 0, 0, 0, 0, 0);
    const id2 = try catalog.addNewRecording(2, 20, "ch2", "src2", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(3, 30, "ch3", "src3", 0, 0, 0, 0, 0, 0);

    const entry = catalog.recordingDescriptor(id2);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(2, entry.?.recording_id);
    try std.testing.expectEqual(20, entry.?.stream_id);
}

test "updateStopPosition updates correct entry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    const id = try catalog.addNewRecording(1, 1, "ch", "src", 0, 0, 0, 0, 0, 0);
    try catalog.updateStopPosition(id, 12345);

    const entry = catalog.recordingDescriptor(id);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(12345, entry.?.stop_position);
}

test "persistent catalog survives re-init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const archive_dir = try std.fmt.allocPrint(allocator, "/tmp/harus-aeron-catalog-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(archive_dir);
    defer std.fs.cwd().deleteTree(archive_dir) catch {};

    {
        var catalog = try Catalog.initWithArchiveDir(allocator, archive_dir);
        defer catalog.deinit();

        const id1 = try catalog.addNewRecording(11, 22, "ch1", "src1", 1, 4096, 65536, 1408, 0, 100);
        try catalog.updateStopState(id1, 64, 200);
        _ = try catalog.addNewRecording(33, 44, "ch2", "src2", 2, 8192, 131072, 1408, 64, 300);
    }

    {
        var catalog = try Catalog.initWithArchiveDir(allocator, archive_dir);
        defer catalog.deinit();

        try std.testing.expectEqual(@as(i64, 3), catalog.next_recording_id);
        const first = catalog.recordingDescriptor(1).?;
        try std.testing.expectEqual(@as(i64, 64), first.stop_position);
        try std.testing.expectEqual(@as(i64, 200), first.stop_timestamp);
        const second = catalog.recordingDescriptor(2).?;
        try std.testing.expectEqual(@as(i32, 44), second.stream_id);
    }
}

test "listRecordings iterates range" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "ch1", "src", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(2, 2, "ch2", "src", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(3, 3, "ch3", "src", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(4, 4, "ch4", "src", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(5, 5, "ch5", "src", 0, 0, 0, 0, 0, 0);

    const handler = struct {
        pub fn handle(entry: *const RecordingDescriptorEntry) void {
            _ = entry;
        }
    }.handle;

    const count = catalog.listRecordings(2, 2, &handler);
    try std.testing.expectEqual(2, count);
}

test "findLastMatchingRecording finds by channel and stream_id" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "aeron:udp|endpoints=localhost:40123", "src1", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(2, 2, "aeron:udp|endpoints=localhost:40124", "src2", 0, 0, 0, 0, 0, 0);
    const id3 = try catalog.addNewRecording(3, 2, "aeron:udp|endpoints=localhost:40124", "src3", 0, 0, 0, 0, 0, 0);

    const found = catalog.findLastMatchingRecording(0, "aeron:udp|endpoints=localhost:40124", 2);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(id3, found.?);
}

test "findLastMatchingRecording returns null for no match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = Catalog.init(allocator);
    defer catalog.deinit();

    _ = try catalog.addNewRecording(1, 1, "ch1", "src", 0, 0, 0, 0, 0, 0);
    _ = try catalog.addNewRecording(2, 2, "ch2", "src", 0, 0, 0, 0, 0, 0);

    const found = catalog.findLastMatchingRecording(0, "nonexistent", 999);
    try std.testing.expect(found == null);
}
