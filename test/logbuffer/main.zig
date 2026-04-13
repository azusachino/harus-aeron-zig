const std = @import("std");

comptime {
    _ = @import("term_appender_test.zig");
    _ = @import("term_reader_test.zig");
}

test "logbuffer tests placeholder" {
    // This placeholder ensures the test file compiles
}
