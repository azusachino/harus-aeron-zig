// Driver scenario tests root
const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("conductor_test.zig");
    _ = @import("loss_and_recovery_test.zig");
    _ = @import("media_driver_test.zig");
}

test "placeholder: session_establishment root" {}
