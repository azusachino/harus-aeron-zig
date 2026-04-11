const std = @import("std");

comptime {
    _ = @import("ring_buffer_test.zig");
    _ = @import("broadcast_test.zig");
    _ = @import("counters_test.zig");
}

test "placeholder IPC test suite" {}
