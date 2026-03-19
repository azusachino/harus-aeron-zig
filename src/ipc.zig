// IPC (inter-process communication) modules for Aeron
// - ring_buffer: client→driver commands
// - broadcast: driver→client notifications

pub const ring_buffer = @import("ipc/ring_buffer.zig");
pub const broadcast = @import("ipc/broadcast.zig");
pub const counters = @import("ipc/counters.zig");
