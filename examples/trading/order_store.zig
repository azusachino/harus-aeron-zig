//! Archive-backed durable order log and snapshot storage for the trading
//! cluster sample, replacing the ad-hoc length-prefixed flat file with real
//! Aeron Archive recordings (catalog entries + segmented .dat files). Each
//! process lifetime records its accepted orders into one recording; restart
//! loads the latest snapshot (if any) and then replays every order-log
//! recording newer than that snapshot's cutoff, before opening a fresh
//! recording for further appends. Mirrors the snapshot blob pattern already
//! proven in src/cluster/conductor/snapshot.zig, but for this sample's
//! OrderBook + ClusterLog state rather than ClusterConductor.
const std = @import("std");
const aeron = @import("aeron");
const archive_mod = aeron.archive;
const recorder_mod = aeron.archive.recorder;
const log_mod = aeron.cluster.log;
const io_mod = aeron.io;
const time_mod = aeron.time;
const trading = @import("trading");

pub const ORDER_STREAM_ID: i32 = 900;
pub const SNAPSHOT_STREAM_ID: i32 = 901;
const ORDER_CHANNEL = "aeron:ipc?stream-id=900";
const SNAPSHOT_CHANNEL = "aeron:ipc?stream-id=901";
const MAX_ORDER_LENGTH: usize = 16 * 1024;
const SNAPSHOT_MAGIC: u32 = 0x544F4253; // "SBOT"
const SNAPSHOT_VERSION: u32 = 1;

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Real on-disk size of a recording's first segment, used when the
/// catalog's stop_position wasn't updated because the recording was still
/// open at process kill. Only the first segment is checked, matching this
/// sample's order logs, which never reach the 128MB rotation threshold.
fn onDiskStopPosition(allocator: std.mem.Allocator, archive_dir: []const u8, recording_id: i64, start_position: i64) !i64 {
    const path = try recorder_mod.RecordingWriter.segmentFilePath(allocator, archive_dir, recording_id, start_position);
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io_mod.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return start_position,
        else => return err,
    };
    defer file.close(io_mod.io());
    return start_position + @as(i64, @intCast(try file.length(io_mod.io())));
}

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Bounds-checked cursor over a snapshot blob; a truncated or corrupt
/// recording must fail cleanly rather than read past the buffer.
const SnapshotReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readIntField(self: *SnapshotReader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.bytes.len) return error.SnapshotTruncated;
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..n], .little);
        self.pos += n;
        return value;
    }
};

/// OrderStore — durable order-log + periodic snapshot storage backed by a
/// real Aeron Archive (catalog + segment files) instead of a private file.
pub const OrderStore = struct {
    allocator: std.mem.Allocator,
    // LESSON(archive-pinning): ArchiveConductor's lazily-created Recorder
    // stores a raw `&self.catalog` pointer captured on the first doWork()
    // call. If the Archive is ever copied by value afterward (as it would
    // be if this field held Archive directly and OrderStore itself got
    // copied into Node), that pointer dangles into stale memory. Heap-
    // allocating pins the Archive's address for its whole lifetime.
    archive: *archive_mod.Archive,
    order_recording_id: i64,
    /// Count of orders applied during startup (replayed from snapshot +
    /// order-log recordings), mirroring the old Journal's `replayed_orders`.
    replayed_orders: u64 = 0,
    /// Session id counter restored from the latest snapshot, or the
    /// caller's default if no snapshot exists yet.
    next_session_id: i64,

    /// Open (or create) the Archive under `archive_dir`, restore the latest
    /// snapshot into `book`/`log` if one exists, replay every order-log
    /// recording newer than that snapshot's cutoff via `parse_order` +
    /// `book.submit`/`log.append`, then start a fresh order-log recording
    /// for this run's appends.
    pub fn init(
        allocator: std.mem.Allocator,
        member_id: i32,
        archive_dir: []const u8,
        book: *trading.OrderBook,
        log: *log_mod.ClusterLog,
        default_next_session_id: i64,
        parse_order: anytype,
    ) !OrderStore {
        const archive = try allocator.create(archive_mod.Archive);
        errdefer allocator.destroy(archive);
        archive.* = try archive_mod.Archive.init(allocator, .{ .archive_dir = archive_dir });
        errdefer archive.deinit();
        archive.start();
        // Archive.conductor lazily creates its Recorder on the first
        // doWork() call; force that here so onStartRecording below has one.
        _ = try archive.doWork();

        var next_session_id = default_next_session_id;
        var last_order_recording_id: i64 = 0;
        if (try loadLatestSnapshot(archive, allocator, book, log)) |restored| {
            next_session_id = restored.next_session_id;
            last_order_recording_id = restored.last_order_recording_id;
        }

        var replayed_orders: u64 = 0;
        // Replay every order recording newer than the snapshot's cutoff, in
        // ascending recording_id order (catalog entries are always appended
        // in increasing-id order, so no separate sort is needed).
        for (archive.conductor.catalog.entries.items) |entry| {
            if (entry.recording_id <= last_order_recording_id) continue;
            if (entry.stream_id != ORDER_STREAM_ID) continue;
            const channel = archive_mod.catalog.Catalog.copyChannel(&entry);
            if (!std.mem.eql(u8, channel, ORDER_CHANNEL)) continue;

            // An ungraceful process kill never reaches OrderStore.deinit(),
            // so the catalog's stop_position for the still-open recording
            // is stale (never advanced past start_position). Crash-
            // consistent recovery must read the segment file's real size
            // from disk instead of trusting that stale catalog value.
            const stop_position = if (entry.stop_position > entry.start_position)
                entry.stop_position
            else
                try onDiskStopPosition(allocator, archive_dir, entry.recording_id, entry.start_position);

            const bytes = try recorder_mod.readAllSegmentsFromDisk(
                allocator,
                archive_dir,
                entry.recording_id,
                entry.start_position,
                stop_position,
                entry.segment_file_length,
            );
            defer allocator.free(bytes);

            var offset: usize = 0;
            while (offset < bytes.len) {
                // A trailing partial record means the process was killed
                // mid-write; stop cleanly rather than treating it as
                // corruption — everything before it is still durable.
                if (bytes.len - offset < 4) break;
                const order_length = @as(usize, @intCast(readU32(bytes[offset..][0..4])));
                offset += 4;
                if (order_length == 0 or order_length > MAX_ORDER_LENGTH or order_length > bytes.len - offset) {
                    break;
                }
                const order_payload = bytes[offset .. offset + order_length];
                const order = try parse_order(order_payload);
                _ = book.submit(order) catch return error.CorruptOrderRecording;
                _ = try log.append(order_payload, 0);
                replayed_orders += 1;
                offset += order_length;
            }
        }

        const order_recording_id = try archive.conductor.recorder.?.onStartRecording(
            member_id,
            ORDER_STREAM_ID,
            ORDER_CHANNEL,
            "order-log",
            .{ .start_timestamp = time_mod.milliTimestamp() },
        );

        return .{
            .allocator = allocator,
            .archive = archive,
            .order_recording_id = order_recording_id,
            .replayed_orders = replayed_orders,
            .next_session_id = next_session_id,
        };
    }

    /// Append one order payload to this run's active order-log recording.
    pub fn append(self: *OrderStore, order_payload: []const u8) !void {
        if (order_payload.len == 0 or order_payload.len > MAX_ORDER_LENGTH) return error.OrderTooLarge;
        const session = self.archive.conductor.recorder.?.findSession(self.order_recording_id) orelse return error.RecordingSessionNotFound;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(order_payload.len), .little);
        try session.onFragment(&length);
        try session.onFragment(order_payload);
        try session.writer.flush();
    }

    /// Serialize book + log state into a one-shot snapshot recording so a
    /// future restart can skip straight past every order recorded up to
    /// `self.order_recording_id`, then rotate to a fresh order-log
    /// recording. Rotation is required for correctness: the current
    /// order-log recording stays open and keeps growing for the rest of
    /// this run, so it cannot be marked "fully captured" by a snapshot
    /// unless it is actually closed at the same instant the snapshot is
    /// taken — otherwise orders appended after the snapshot but into the
    /// same still-open recording would be silently skipped on replay.
    pub fn takeSnapshot(
        self: *OrderStore,
        member_id: i32,
        book: *const trading.OrderBook,
        log: *const log_mod.ClusterLog,
        next_session_id: i64,
    ) !void {
        const recorder = self.archive.conductor.recorder.?;
        const timestamp = time_mod.milliTimestamp();

        try recorder.onStopRecording(self.order_recording_id, timestamp);
        const blob = try serializeSnapshot(self.allocator, book, log, next_session_id, self.order_recording_id);
        defer self.allocator.free(blob);

        const snapshot_recording_id = try recorder.onStartRecording(
            member_id,
            SNAPSHOT_STREAM_ID,
            SNAPSHOT_CHANNEL,
            "snapshot",
            .{ .start_timestamp = timestamp },
        );
        const snapshot_session = recorder.findSession(snapshot_recording_id) orelse return error.RecordingSessionNotFound;
        try snapshot_session.onFragment(blob);
        try recorder.onStopRecording(snapshot_recording_id, timestamp);

        self.order_recording_id = try recorder.onStartRecording(
            member_id,
            ORDER_STREAM_ID,
            ORDER_CHANNEL,
            "order-log",
            .{ .start_timestamp = timestamp },
        );
    }

    pub fn deinit(self: *OrderStore) void {
        self.archive.conductor.recorder.?.onStopRecording(self.order_recording_id, time_mod.milliTimestamp()) catch {};
        self.archive.deinit();
        self.allocator.destroy(self.archive);
    }
};

const RestoredCursor = struct {
    next_session_id: i64,
    last_order_recording_id: i64,
};

fn loadLatestSnapshot(
    archive: *archive_mod.Archive,
    allocator: std.mem.Allocator,
    book: *trading.OrderBook,
    log: *log_mod.ClusterLog,
) !?RestoredCursor {
    const recording_id = archive.conductor.catalog.findLastMatchingRecording(0, SNAPSHOT_CHANNEL, SNAPSHOT_STREAM_ID) orelse return null;
    const descriptor = archive.conductor.catalog.recordingDescriptor(recording_id) orelse return null;
    const path = try recorder_mod.RecordingWriter.segmentFilePath(allocator, archive.ctx.archive_dir, recording_id, descriptor.start_position);
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(io_mod.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.io());
    const size = @as(usize, @intCast(try file.length(io_mod.io())));
    if (size == 0) return null;

    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    const read_len = try file.readPositionalAll(io_mod.io(), bytes, 0);
    if (read_len != size) return null;

    return try deserializeInto(bytes, book, log);
}

fn serializeSnapshot(
    allocator: std.mem.Allocator,
    book: *const trading.OrderBook,
    log: *const log_mod.ClusterLog,
    next_session_id: i64,
    last_order_recording_id: i64,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendInt(&buf, allocator, u32, SNAPSHOT_MAGIC);
    try appendInt(&buf, allocator, u32, SNAPSHOT_VERSION);
    try appendInt(&buf, allocator, i64, next_session_id);
    try appendInt(&buf, allocator, i64, last_order_recording_id);
    try appendInt(&buf, allocator, i64, log.leader_ship_term_id);
    try appendInt(&buf, allocator, i64, log.append_position);
    try appendInt(&buf, allocator, i64, log.commit_position);

    try appendOrders(&buf, allocator, book.bids.items);
    try appendOrders(&buf, allocator, book.asks.items);

    return buf.toOwnedSlice(allocator);
}

fn appendOrders(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, orders: []const trading.Order) !void {
    try appendInt(buf, allocator, u32, @intCast(orders.len));
    for (orders) |order| {
        try appendInt(buf, allocator, u64, order.order_id);
        try appendInt(buf, allocator, u8, @intFromEnum(order.side));
        try appendInt(buf, allocator, i64, order.price);
        try appendInt(buf, allocator, i64, order.quantity);
    }
}

/// Restore book + log state from a snapshot blob written by `takeSnapshot`.
/// Returns the session-id counter and the order-recording cutoff so the
/// caller knows which order recordings are already reflected in `book`.
fn deserializeInto(bytes: []const u8, book: *trading.OrderBook, log: *log_mod.ClusterLog) !RestoredCursor {
    var reader: SnapshotReader = .{ .bytes = bytes };
    if (try reader.readIntField(u32) != SNAPSHOT_MAGIC) return error.InvalidSnapshotMagic;
    if (try reader.readIntField(u32) != SNAPSHOT_VERSION) return error.UnsupportedSnapshotVersion;

    const next_session_id = try reader.readIntField(i64);
    const last_order_recording_id = try reader.readIntField(i64);
    log.leader_ship_term_id = try reader.readIntField(i64);
    log.append_position = try reader.readIntField(i64);
    log.commit_position = try reader.readIntField(i64);

    try readOrdersInto(&reader, book.allocator, &book.bids);
    try readOrdersInto(&reader, book.allocator, &book.asks);

    return .{ .next_session_id = next_session_id, .last_order_recording_id = last_order_recording_id };
}

fn readOrdersInto(reader: *SnapshotReader, allocator: std.mem.Allocator, list: *std.ArrayList(trading.Order)) !void {
    const count = try reader.readIntField(u32);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const order_id = try reader.readIntField(u64);
        const side_byte = try reader.readIntField(u8);
        if (side_byte > 1) return error.InvalidSnapshotSide;
        const price = try reader.readIntField(i64);
        const quantity = try reader.readIntField(i64);
        try list.append(allocator, .{
            .order_id = order_id,
            .side = @enumFromInt(side_byte),
            .price = price,
            .quantity = quantity,
        });
    }
}
