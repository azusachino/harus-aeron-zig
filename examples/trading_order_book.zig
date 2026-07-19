//! Small trading-state example for the 0.9 validation line.
//!
//! The matching engine is deterministic and can be driven by a cluster command.
//! The example uses the real ConsensusModule and ClusterLog types, but keeps the
//! three nodes in one process so it is safe to run as a local example.

const std = @import("std");
const aeron = @import("aeron");

pub const Side = enum { bid, ask };
pub const SYMBOL = "BTC_USDT";

pub const Order = struct {
    order_id: u64,
    side: Side,
    price: i64,
    quantity: i64,
};

pub const SubmitResult = struct {
    filled_quantity: i64,
    resting_quantity: i64,
};

pub const OrderBookError = error{
    InvalidOrder,
    DuplicateOrder,
};

pub const OrderBook = struct {
    allocator: std.mem.Allocator,
    bids: std.ArrayList(Order),
    asks: std.ArrayList(Order),

    pub fn init(allocator: std.mem.Allocator) OrderBook {
        return .{
            .allocator = allocator,
            .bids = .{ .items = &.{}, .capacity = 0 },
            .asks = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *OrderBook) void {
        self.bids.deinit(self.allocator);
        self.asks.deinit(self.allocator);
    }

    pub fn submit(self: *OrderBook, order: Order) (OrderBookError || std.mem.Allocator.Error)!SubmitResult {
        if (order.order_id == 0 or order.price <= 0 or order.quantity <= 0) return error.InvalidOrder;
        if (self.contains(order.order_id)) return error.DuplicateOrder;

        var remaining = order.quantity;
        var filled: i64 = 0;
        while (remaining > 0) {
            const match_index = self.bestCrossingIndex(order.side, order.price) orelse break;
            var opposite = if (order.side == .bid) self.asks.items[match_index] else self.bids.items[match_index];
            const matched = @min(remaining, opposite.quantity);
            remaining -= matched;
            filled += matched;

            if (matched == opposite.quantity) {
                if (order.side == .bid) {
                    _ = self.asks.swapRemove(match_index);
                } else {
                    _ = self.bids.swapRemove(match_index);
                }
            } else {
                opposite.quantity -= matched;
                if (order.side == .bid) {
                    self.asks.items[match_index] = opposite;
                } else {
                    self.bids.items[match_index] = opposite;
                }
            }
        }

        if (remaining > 0) {
            var resting = order;
            resting.quantity = remaining;
            if (order.side == .bid) {
                try self.bids.append(self.allocator, resting);
            } else {
                try self.asks.append(self.allocator, resting);
            }
        }

        return .{ .filled_quantity = filled, .resting_quantity = remaining };
    }

    pub fn bestBid(self: *const OrderBook) ?Order {
        return best(self.bids.items, .bid);
    }

    pub fn bestAsk(self: *const OrderBook) ?Order {
        return best(self.asks.items, .ask);
    }

    fn contains(self: *const OrderBook, order_id: u64) bool {
        for (self.bids.items) |order| if (order.order_id == order_id) return true;
        for (self.asks.items) |order| if (order.order_id == order_id) return true;
        return false;
    }

    fn bestCrossingIndex(self: *const OrderBook, side: Side, limit_price: i64) ?usize {
        const orders = if (side == .bid) self.asks.items else self.bids.items;
        var selected: ?usize = null;
        for (orders, 0..) |order, index| {
            const crosses = if (side == .bid) order.price <= limit_price else order.price >= limit_price;
            if (!crosses) continue;
            if (selected == null or
                (side == .bid and order.price < orders[selected.?].price) or
                (side == .ask and order.price > orders[selected.?].price))
            {
                selected = index;
            }
        }
        return selected;
    }

    fn best(orders: []const Order, side: Side) ?Order {
        if (orders.len == 0) return null;
        var selected = orders[0];
        for (orders[1..]) |order| {
            if ((side == .bid and order.price > selected.price) or
                (side == .ask and order.price < selected.price))
            {
                selected = order;
            }
        }
        return selected;
    }
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const members = [_]aeron.cluster.consensus.MemberConfig{
        .{ .member_id = 0, .consensus_port = 9120, .log_port = 9130 },
        .{ .member_id = 1, .consensus_port = 9121, .log_port = 9131 },
        .{ .member_id = 2, .consensus_port = 9122, .log_port = 9132 },
    };
    var nodes: [3]aeron.cluster.consensus.ConsensusModule = undefined;
    for (&nodes, 0..) |*node, member_id| {
        node.* = try aeron.cluster.consensus.ConsensusModule.init(allocator, .{
            .member_id = @intCast(member_id),
            .cluster_members = &members,
        });
        node.start();
    }
    defer for (&nodes) |*node| node.deinit();

    var book = OrderBook.init(allocator);
    defer book.deinit();

    var log = aeron.cluster.log.ClusterLog.init(allocator);
    defer log.deinit();

    const orders = [_]Order{
        .{ .order_id = 1, .side = .ask, .price = 10100, .quantity = 10 },
        .{ .order_id = 2, .side = .bid, .price = 10100, .quantity = 4 },
        .{ .order_id = 3, .side = .bid, .price = 10050, .quantity = 8 },
        .{ .order_id = 4, .side = .ask, .price = 10050, .quantity = 6 },
    };

    for (orders) |order| {
        const result = try book.submit(order);
        var encoded: [40]u8 = undefined;
        const payload = try std.fmt.bufPrint(&encoded, "{d}:{d}:{d}:{d}", .{
            order.order_id,
            @intFromEnum(order.side),
            order.price,
            order.quantity,
        });
        _ = try log.append(payload, 0);
        std.debug.print("order={d} filled={d} resting={d}\n", .{
            order.order_id,
            result.filled_quantity,
            result.resting_quantity,
        });
    }

    var now_ns: i64 = 0;
    for (0..100) |_| {
        for (&nodes) |*node| _ = try node.doWork(now_ns);
        now_ns += 1_000_000;
    }

    if (book.bestBid()) |bid| {
        std.debug.print("best bid: {d} x {d}\n", .{ bid.price, bid.quantity });
    }
    if (book.bestAsk()) |ask| {
        std.debug.print("best ask: {d} x {d}\n", .{ ask.price, ask.quantity });
    }
    std.debug.print("symbol={s} cluster log position: {d}\n", .{ SYMBOL, log.appendPosition() });
}

test "order book happy path matches crossing orders" {
    var book = OrderBook.init(std.testing.allocator);
    defer book.deinit();

    _ = try book.submit(.{ .order_id = 1, .side = .ask, .price = 100, .quantity = 5 });
    const result = try book.submit(.{ .order_id = 2, .side = .bid, .price = 100, .quantity = 3 });
    try std.testing.expectEqual(@as(i64, 3), result.filled_quantity);
    try std.testing.expectEqual(@as(i64, 2), book.bestAsk().?.quantity);
}

test "order book evil path rejects invalid and duplicate orders" {
    var book = OrderBook.init(std.testing.allocator);
    defer book.deinit();

    try std.testing.expectError(error.InvalidOrder, book.submit(.{ .order_id = 1, .side = .bid, .price = 0, .quantity = 1 }));
    _ = try book.submit(.{ .order_id = 1, .side = .bid, .price = 100, .quantity = 1 });
    try std.testing.expectError(error.DuplicateOrder, book.submit(.{ .order_id = 1, .side = .ask, .price = 99, .quantity = 1 }));
}

test "order book edge path leaves non-crossing orders resting" {
    var book = OrderBook.init(std.testing.allocator);
    defer book.deinit();

    const result = try book.submit(.{ .order_id = 7, .side = .bid, .price = 99, .quantity = 2 });
    try std.testing.expectEqual(@as(i64, 0), result.filled_quantity);
    try std.testing.expectEqual(@as(i64, 2), result.resting_quantity);
    try std.testing.expectEqual(@as(i64, 99), book.bestBid().?.price);
    try std.testing.expect(book.bestAsk() == null);
}
