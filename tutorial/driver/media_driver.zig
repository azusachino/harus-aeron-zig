// EXERCISE: Chapter 3.4 — Media Driver
// Reference: docs/tutorial/03-driver/04-media-driver.md
//
// Your task: implement `MediaDriver.create` to orchestrate agents.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const MediaDriver = struct {
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, options: anytype) !*MediaDriver {
        _ = options;
        _ = allocator;
        @panic("TODO: implement MediaDriver.create");
    }

    pub fn destroy(self: *MediaDriver) void {
        self.allocator.destroy(self);
    }
};

test "MediaDriver creation" {
    // try MediaDriver.create(std.testing.allocator, .{});
}
