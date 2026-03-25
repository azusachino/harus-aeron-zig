const std = @import("std");
const image_mod = @import("image.zig");
const term_reader = @import("logbuffer/term_reader.zig");

// LESSON(subscriptions): Image list is []*Image (pointers, not values) because Images are large and have identity; use pointer indirection for stability. See docs/tutorial/04-client/02-subscriptions.md
pub const Subscription = struct {
    stream_id: i32,
    channel: []const u8,
    image_list: std.ArrayList(*image_mod.Image),
    allocator: std.mem.Allocator,
    is_closed: bool,

    pub fn init(allocator: std.mem.Allocator, stream_id: i32, channel: []const u8) !Subscription {
        return .{
            .stream_id = stream_id,
            .channel = try allocator.dupe(u8, channel),
            .image_list = .{
                .items = &.{},
                .capacity = 0,
            },
            .allocator = allocator,
            .is_closed = false,
        };
    }

    pub fn deinit(self: *Subscription) void {
        self.allocator.free(self.channel);
        self.image_list.deinit(self.allocator);
    }

    // LESSON(subscriptions): poll() iterates all Images, invoking handler on each frame until fragment budget exhausted; handler receives unpacked DataHeader + payload. See docs/tutorial/04-client/02-subscriptions.md
    pub fn poll(
        self: *Subscription,
        handler: term_reader.FragmentHandler,
        ctx: *anyopaque,
        fragment_limit: i32,
    ) i32 {
        var total_fragments_read: i32 = 0;
        // Simple round-robin-ish: just iterate all images.
        // In a more complex implementation, we'd remember where we left off.
        for (self.image_list.items) |img| {
            if (total_fragments_read >= fragment_limit) break;
            total_fragments_read += img.poll(handler, ctx, fragment_limit - total_fragments_read);
        }
        return total_fragments_read;
    }

    // LESSON(subscriptions): Image lifecycle: driver creates Image from SETUP frame (session_id, initial_term_id, log buffer); subscriber removes by session_id when sender closes. See docs/tutorial/04-client/02-subscriptions.md
    pub fn addImage(self: *Subscription, img: *image_mod.Image) !void {
        try self.image_list.append(self.allocator, img);
    }

    pub fn removeImage(self: *Subscription, session_id: i32) void {
        for (self.image_list.items, 0..) |img, i| {
            if (img.session_id == session_id) {
                _ = self.image_list.swapRemove(i);
                return;
            }
        }
    }

    // LESSON(subscriptions): Fragment reassembly is held in Image state; TermReader detects BEGIN/END flags and buffers intermediate frames before handler invocation. See docs/tutorial/04-client/02-subscriptions.md
    pub fn images(self: *const Subscription) []*image_mod.Image {
        return self.image_list.items;
    }

    pub fn isConnected(self: *const Subscription) bool {
        return self.image_list.items.len > 0;
    }

    pub fn close(self: *Subscription) void {
        self.is_closed = true;
    }
};

test "Subscription poll calls image poll" {
    const allocator = std.testing.allocator;
    const logbuffer = @import("logbuffer/log_buffer.zig");
    const frame = @import("protocol/frame.zig");

    var sub = try Subscription.init(allocator, 1, "aeron:udp?endpoint=localhost:40123");
    defer sub.deinit();

    var log_buf = try logbuffer.LogBuffer.init(allocator, 64 * 1024);
    defer log_buf.deinit();

    var image = image_mod.Image.init(1, 1, 100, &log_buf);
    try sub.addImage(&image);

    try std.testing.expect(sub.isConnected());

    var context = struct {
        count: i32 = 0,
    }{};

    const handler = struct {
        fn handle(_: *const frame.DataHeader, _: []const u8, ctx: *anyopaque) void {
            const c = @as(*@TypeOf(context), @ptrCast(@alignCast(ctx)));
            c.count += 1;
        }
    }.handle;

    const fragments = sub.poll(handler, &context, 10);
    try std.testing.expectEqual(@as(i32, 0), fragments);

    sub.removeImage(1);
    try std.testing.expect(!sub.isConnected());
}
