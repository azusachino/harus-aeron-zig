// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/LossHandlerTest.java
//                    aeron-driver/src/test/java/io/aeron/driver/RetransmitHandlerTest.java
// Aeron version: 1.50.2
// Coverage: NAK receipt adds to retransmit queue, Sender drains queue

const std = @import("std");
const aeron = @import("aeron");

test "Sender: retransmit adds to queue" {
    const allocator = std.testing.allocator;

    const meta_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(meta_buf);
    const values_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(values_buf);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const dummy_socket: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_socket };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    // Directly test onRetransmit
    try sender.onRetransmit(1, 10, 5, 100, 256);
    try std.testing.expectEqual(@as(usize, 1), sender.retransmit_queue.items.len);
    try std.testing.expectEqual(@as(i32, 1), sender.retransmit_queue.items[0].session_id);
}

test "LossReport: records observation" {
    const allocator = std.testing.allocator;
    const buf = try allocator.alignedAlloc(u8, .@"64", 4096);
    defer allocator.free(buf);
    @memset(buf, 0);

    var lr = aeron.loss_report.LossReport.init(buf);
    lr.recordObservation(256, 1000000, 1, 10, "127.0.0.1:20121");

    try std.testing.expect(lr.entryCount() > 0);
}

test "Sender: retransmit queue drains on doWork" {
    const allocator = std.testing.allocator;

    const meta_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(meta_buf);
    const values_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(values_buf);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const dummy_socket: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_socket };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    // Add multiple retransmit requests
    try sender.onRetransmit(1, 10, 5, 100, 256);
    try sender.onRetransmit(1, 10, 5, 356, 256);
    try sender.onRetransmit(1, 10, 5, 612, 256);

    try std.testing.expectEqual(@as(usize, 3), sender.retransmit_queue.items.len);

    // doWork should drain the queue (though it won't actually send without a real socket)
    _ = sender.doWork();

    // Queue should be empty after processing
    try std.testing.expectEqual(@as(usize, 0), sender.retransmit_queue.items.len);
}

test "Sender: multiple retransmit entries processed in sequence" {
    const allocator = std.testing.allocator;

    const meta_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(meta_buf);
    const values_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(values_buf);
    var cm = aeron.ipc.counters.CountersMap.init(meta_buf, values_buf);

    const dummy_socket: std.posix.socket_t = 0;
    var send_endpoint = aeron.transport.SendChannelEndpoint{ .socket = dummy_socket };
    var sender = try aeron.driver.Sender.init(allocator, &send_endpoint, &cm);
    defer sender.deinit();

    // Add 5 retransmit requests
    try sender.onRetransmit(1, 10, 5, 0, 256);
    try sender.onRetransmit(1, 10, 5, 256, 256);
    try sender.onRetransmit(1, 10, 5, 512, 256);
    try sender.onRetransmit(2, 11, 6, 0, 256);
    try sender.onRetransmit(2, 11, 6, 256, 256);

    try std.testing.expectEqual(@as(usize, 5), sender.retransmit_queue.items.len);

    // Process all retransmits
    _ = sender.doWork();

    try std.testing.expectEqual(@as(usize, 0), sender.retransmit_queue.items.len);
}
