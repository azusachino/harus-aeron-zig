// Aeron client library root
// Reference: https://github.com/aeron-io/aeron

pub const protocol = @import("protocol/frame.zig");
pub const logbuffer = @import("logbuffer/log_buffer.zig");
pub const ipc = @import("ipc/ring_buffer.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
