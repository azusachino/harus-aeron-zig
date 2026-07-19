//! ClusteredService-style lifecycle callbacks for the BTC_USDT trading
//! sample, mirroring io.aeron.cluster.service.ClusteredService's contract
//! (onSessionOpen/onSessionClose/onSessionMessage/onTakeSnapshot/
//! onNewLeadershipTerm). This is the layer that separates "what changes
//! when a command commits" from cluster replication/consensus mechanics
//! (election.zig, log.zig, and the AppendRequest/AppendPosition/
//! CommitPosition wiring in zig_cluster_node.zig).
//!
//! Every member — leader and followers alike — applies committed orders
//! through `onSessionMessage`: the leader calls it directly from a live
//! client message, a follower calls it from a validated AppendRequest.
//! Routing both paths through one entry point is what makes a follower a
//! real service replica instead of a passive log observer that merely
//! mirrors bytes.
const std = @import("std");
const aeron = @import("aeron");
const log_mod = aeron.cluster.log;
const order_store = @import("order_store.zig");
const trading = @import("trading");

pub const TradingService = struct {
    allocator: std.mem.Allocator,
    book: trading.OrderBook,
    store: order_store.OrderStore,
    /// Cluster session ids currently open, per onSessionOpen/onSessionClose.
    /// Membership here (not the response-routing table in Node) is what a
    /// real ClusteredService tracks; Node's session list additionally
    /// carries the publication needed to reply to that session.
    open_sessions: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        member_id: i32,
        archive_dir: []const u8,
        log: *log_mod.ClusterLog,
        default_next_session_id: i64,
        parse_order: anytype,
    ) !TradingService {
        var book = trading.OrderBook.init(allocator);
        errdefer book.deinit();
        const store = try order_store.OrderStore.init(allocator, member_id, archive_dir, &book, log, default_next_session_id, parse_order);
        return .{ .allocator = allocator, .book = book, .store = store };
    }

    pub fn deinit(self: *TradingService) void {
        self.open_sessions.deinit(self.allocator);
        self.store.deinit();
        self.book.deinit();
    }

    /// ClusteredService.onSessionOpen — a client session has been admitted.
    pub fn onSessionOpen(self: *TradingService, cluster_session_id: i64) !void {
        try self.open_sessions.put(self.allocator, cluster_session_id, {});
    }

    /// ClusteredService.onSessionClose — a client session has ended.
    pub fn onSessionClose(self: *TradingService, cluster_session_id: i64) void {
        _ = self.open_sessions.swapRemove(cluster_session_id);
    }

    /// ClusteredService.onSessionMessage — apply one committed order to the
    /// book and record it durably. Called for both leader-originated and
    /// follower-replicated orders, so book state and durable storage stay
    /// identical regardless of which member is applying the command.
    pub fn onSessionMessage(
        self: *TradingService,
        order_payload: []const u8,
        parse_order: anytype,
    ) !trading.SubmitResult {
        const order = try parse_order(order_payload);
        const result = try self.book.submit(order);
        try self.store.append(order_payload);
        return result;
    }

    /// ClusteredService.onTakeSnapshot — durably capture book + log state.
    pub fn onTakeSnapshot(
        self: *TradingService,
        member_id: i32,
        log: *const log_mod.ClusterLog,
        next_session_id: i64,
    ) !void {
        try self.store.takeSnapshot(member_id, &self.book, log, next_session_id);
    }

    /// ClusteredService.onNewLeadershipTerm — informs the service a new
    /// leader/term has been established. The BTC_USDT matching logic has
    /// no per-term state of its own, so this only logs today, but the hook
    /// is wired the same way a real Aeron Cluster service would receive it.
    pub fn onNewLeadershipTerm(member_id: i32, leadership_term_id: i64, leader_member_id: i32) void {
        std.debug.print("ZIG_CLUSTER_SERVICE_NEW_TERM member={d} term={d} leader={d}\n", .{ member_id, leadership_term_id, leader_member_id });
    }
};
