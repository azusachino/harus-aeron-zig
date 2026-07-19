//! Durable recovery snapshot handling for ClusterConductor: the
//! snapshot_begin/snapshot_end command lifecycle, Archive-backed
//! take/load, and the little-endian serialize/deserialize blob format.
//!
//! This is an internal persistence format — read back only by
//! `deserialize` on recovery, never exchanged with another Aeron
//! implementation — so the byte layout is our own rather than the SBE
//! ConsensusModuleSnapshot codec. Field selection mirrors the durable
//! state captured by io.aeron.cluster.ConsensusModuleAgent.takeSnapshot.

const std = @import("std");
const time = @import("../../time.zig");
const io_mod = @import("../../io.zig");
const recorder_mod = @import("../../archive/recorder.zig");
const log_mod = @import("../log.zig");
const types = @import("types.zig");
const conductor_mod = @import("../conductor.zig");
const ClusterConductor = conductor_mod.ClusterConductor;

/// Magic prefix identifying a ClusterConductor snapshot blob ("CLSN").
const SNAPSHOT_MAGIC: u32 = 0x4E534C43;
/// On-disk snapshot layout version. Bump on any incompatible field change.
const SNAPSHOT_VERSION: u32 = 1;

/// Handle snapshot_begin command.
/// Mark snapshot in progress and capture current conductor state.
pub fn handleBegin(self: *ClusterConductor, cmd: types.SnapshotBeginCmd) !void {
    self.snapshot_state = .taking;
    if (self.pending_snapshot) |*old| old.deinit(self.allocator);
    self.pending_snapshot = try self.captureState(self.allocator);

    // If an archive is wired, serialize the state and write it directly to the archive directory
    if (self.archive) |arc| {
        const blob = try serialize(self, self.allocator);
        defer self.allocator.free(blob);

        const rec = arc.conductor.recorder orelse return error.RecorderNotInitialized;
        const timestamp = time.milliTimestamp();
        const recording_id = try rec.onStartRecording(
            cmd.member_id,
            2, // stream_id
            "aeron:ipc?stream-id=2", // channel
            "snapshot", // source_identity
            .{
                .initial_term_id = 0,
                .segment_file_length = 128 * 1024 * 1024,
                .term_buffer_length = 65536,
                .mtu_length = 1408,
                .start_position = 0,
                .start_timestamp = timestamp,
            },
        );

        // Find the active recording session and write the blob directly to it
        var written = false;
        for (rec.sessions.items) |*session| {
            if (session.recording_id == recording_id) {
                try session.onFragment(blob);
                written = true;
                break;
            }
        }
        if (!written) return error.RecordingSessionNotFound;

        // Stop recording
        try rec.onStopRecording(recording_id, time.milliTimestamp());

        std.log.info("ClusterConductor member={d} successfully wrote snapshot to recording_id={d}", .{ self.member_id, recording_id });
    }
}

/// Handle snapshot_end command.
/// Snapshot complete — clear pending snapshot and resume normal operation.
pub fn handleEnd(self: *ClusterConductor, cmd: types.SnapshotEndCmd) !void {
    _ = cmd;
    self.snapshot_state = .completed;
    if (self.pending_snapshot) |*snap| {
        snap.deinit(self.allocator);
        self.pending_snapshot = null;
    }
}

/// Load the last successful snapshot from the Archive, if wired up.
pub fn loadLast(self: *ClusterConductor) !void {
    const arc = self.archive orelse return;
    if (arc.conductor.catalog.findLastMatchingRecording(0, "aeron:ipc?stream-id=2", 2)) |recording_id| {
        const path = try recorder_mod.RecordingWriter.segmentFilePath(self.allocator, arc.ctx.archive_dir, recording_id, 0);
        defer self.allocator.free(path);

        var file = std.Io.Dir.cwd().openFile(io_mod.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (file) |*f| {
            defer f.close(io_mod.io());
            const size = @as(usize, @intCast(try f.length(io_mod.io())));
            if (size > 0) {
                const buf = try self.allocator.alloc(u8, size);
                defer self.allocator.free(buf);
                const read_len = try f.readPositionalAll(io_mod.io(), buf, 0);
                if (read_len == size) {
                    try load(self, buf);
                    std.log.info("ClusterConductor member={d} successfully restored snapshot from recording_id={d}", .{ self.member_id, recording_id });
                }
            }
        }
    }
}

/// Serialize durable conductor state (role, term/session ids, commit
/// position, open sessions, and the replicated log) into a self-describing
/// little-endian blob suitable for writing to an Archive recording. The
/// caller owns the returned slice.
pub fn serialize(self: *const ClusterConductor, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendInt(&buf, allocator, u32, SNAPSHOT_MAGIC);
    try appendInt(&buf, allocator, u32, SNAPSHOT_VERSION);
    try appendInt(&buf, allocator, u8, @intFromEnum(self.role));
    try appendInt(&buf, allocator, i32, self.leader_member_id);
    try appendInt(&buf, allocator, i64, self.leader_ship_term_id);
    try appendInt(&buf, allocator, i64, self.next_session_id);
    try appendInt(&buf, allocator, i64, self.commit_position);

    try appendInt(&buf, allocator, u32, @intCast(self.sessions.items.len));
    for (self.sessions.items) |session| {
        try appendInt(&buf, allocator, i64, session.cluster_session_id);
        try appendInt(&buf, allocator, i32, session.response_stream_id);
        try appendInt(&buf, allocator, u8, @intFromBool(session.is_open));
        try appendBytes(&buf, allocator, session.response_channel);
    }

    try appendInt(&buf, allocator, i64, self.log.leader_ship_term_id);
    try appendInt(&buf, allocator, i64, self.log.append_position);
    try appendInt(&buf, allocator, i64, self.log.commit_position);
    try appendInt(&buf, allocator, u32, @intCast(self.log.entries.items.len));
    for (self.log.entries.items) |entry| {
        try appendInt(&buf, allocator, i64, entry.position);
        try appendInt(&buf, allocator, i64, entry.timestamp);
        try appendBytes(&buf, allocator, entry.data);
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse a blob produced by `serialize` into an owned recovery-state
/// struct. Returns an error on truncation, bad magic, an unknown version, or
/// an invalid role tag — the input is trusted archive data, but a corrupt or
/// partially written recording must fail cleanly rather than panic.
/// The returned state is owned by the caller (call `deinit`).
pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !types.ClusterConductorState {
    var reader: SnapshotReader = .{ .bytes = bytes };

    if (try reader.readInt(u32) != SNAPSHOT_MAGIC) return error.InvalidSnapshotMagic;
    if (try reader.readInt(u32) != SNAPSHOT_VERSION) return error.UnsupportedSnapshotVersion;

    const role_int = try reader.readInt(u8);
    if (role_int >= 3) return error.InvalidSnapshotRole;
    const role: types.ClusterRole = @enumFromInt(role_int);
    const leader_member_id = try reader.readInt(i32);
    const leader_ship_term_id = try reader.readInt(i64);
    const next_session_id = try reader.readInt(i64);
    const commit_position = try reader.readInt(i64);

    const session_count = try reader.readInt(u32);
    const sessions = try allocator.alloc(types.SessionState, session_count);
    var s_built: usize = 0;
    errdefer {
        for (sessions[0..s_built]) |sess| allocator.free(sess.response_channel);
        allocator.free(sessions);
    }
    while (s_built < session_count) : (s_built += 1) {
        const cluster_session_id = try reader.readInt(i64);
        const response_stream_id = try reader.readInt(i32);
        const is_open = (try reader.readInt(u8)) != 0;
        const response_channel = try reader.readBytes(allocator);
        sessions[s_built] = .{
            .cluster_session_id = cluster_session_id,
            .response_stream_id = response_stream_id,
            .response_channel = response_channel,
            .is_open = is_open,
        };
    }

    const log_term = try reader.readInt(i64);
    const log_append = try reader.readInt(i64);
    const log_commit = try reader.readInt(i64);
    const entry_count = try reader.readInt(u32);
    const entries = try allocator.alloc(log_mod.LogEntryState, entry_count);
    var e_built: usize = 0;
    errdefer {
        for (entries[0..e_built]) |entry| allocator.free(entry.data);
        allocator.free(entries);
    }
    while (e_built < entry_count) : (e_built += 1) {
        const position = try reader.readInt(i64);
        const timestamp = try reader.readInt(i64);
        const data = try reader.readBytes(allocator);
        entries[e_built] = .{ .position = position, .timestamp = timestamp, .data = data };
    }

    return .{
        .role = role,
        .leader_member_id = leader_member_id,
        .leader_ship_term_id = leader_ship_term_id,
        .next_session_id = next_session_id,
        .commit_position = commit_position,
        .sessions = sessions,
        .log_state = .{
            .leader_ship_term_id = log_term,
            .append_position = log_append,
            .commit_position = log_commit,
            .entries = entries,
        },
    };
}

/// Recover conductor state from a serialized snapshot blob. Deserializes,
/// restores the durable state, and frees the temporary owned state. This is
/// the recovery entry point a restarting conductor calls with the last
/// successful snapshot read back from the Archive.
pub fn load(self: *ClusterConductor, bytes: []const u8) !void {
    var state = try deserialize(self.allocator, bytes);
    defer state.deinit(self.allocator);
    try self.restoreState(&state);
}

/// Append a fixed-width little-endian integer to the snapshot buffer.
fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Append a length-prefixed (u32) byte slice to the snapshot buffer.
fn appendBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try appendInt(buf, allocator, u32, @intCast(data.len));
    try buf.appendSlice(allocator, data);
}

/// Cursor over a snapshot blob that bounds-checks every read, returning
/// error.SnapshotTruncated rather than reading past the end of trusted-but-
/// possibly-corrupt archive data.
const SnapshotReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readInt(self: *SnapshotReader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.bytes.len) return error.SnapshotTruncated;
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..n], .little);
        self.pos += n;
        return value;
    }

    fn readBytes(self: *SnapshotReader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.readInt(u32);
        if (self.pos + len > self.bytes.len) return error.SnapshotTruncated;
        const out = try allocator.dupe(u8, self.bytes[self.pos..][0..len]);
        self.pos += len;
        return out;
    }
};
