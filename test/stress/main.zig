// Stress Test Suite Main
// Long-running tests for soak and stress scenarios.

const std = @import("std");

comptime {
    _ = @import("ring_buffer_soak.zig");
    _ = @import("term_appender_soak.zig");
    _ = @import("conductor_soak.zig");
    _ = @import("receiver_invalid_soak.zig");
    _ = @import("pubsub_churn_soak.zig");
}

test "placeholder" {
    // Ensure at least one test compiles
}
