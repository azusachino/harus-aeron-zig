const std = @import("std");
const trading = @import("trading");

test "trading example exports a usable order book" {
    var book = trading.OrderBook.init(std.testing.allocator);
    defer book.deinit();

    _ = try book.submit(.{ .order_id = 10, .side = .ask, .price = 42, .quantity = 1 });
    const result = try book.submit(.{ .order_id = 11, .side = .bid, .price = 42, .quantity = 1 });
    try std.testing.expectEqual(@as(i64, 1), result.filled_quantity);
    try std.testing.expect(book.bestAsk() == null);
}
