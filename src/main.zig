// Aeron Media Driver entry point
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

    std.log.info("Aeron Media Driver starting...", .{});
    // TODO: parse CLI args (aeron.dir, term-buffer-length, etc.)
    // TODO: initialize MediaDriver
    // TODO: run duty-cycle loop
}
