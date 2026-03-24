// Integration test entry point
// Reference: https://github.com/aeron-io/aeron
const std = @import("std");

pub const harness = @import("harness.zig");
pub const cluster_integration = @import("cluster_integration.zig");
pub const integration_test = @import("integration_test.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
