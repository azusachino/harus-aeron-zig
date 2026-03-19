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

    /// Initialize a new catalog
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return Catalog{
            .allocator = allocator,
            .entries = .{},
            .next_recording_id = 1,
        };
    }

    /// Free catalog resources
    pub fn deinit(self: *Catalog) void {
        self.entries.deinit(self.allocator);
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
        return recording_id;
    }

    /// Update stop position for a recording
    pub fn updateStopPosition(self: *Catalog, recording_id: i64, stop_position: i64) void {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                entry.stop_position = stop_position;
                return;
            }
        }
    }

    /// Update stop timestamp for a recording
    pub fn updateStopTimestamp(self: *Catalog, recording_id: i64, stop_timestamp: i64) void {
        for (self.entries.items) |*entry| {
            if (entry.recording_id == recording_id) {
                entry.stop_timestamp = stop_timestamp;
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
    catalog.updateStopPosition(id, 12345);

    const entry = catalog.recordingDescriptor(id);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(12345, entry.?.stop_position);
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
