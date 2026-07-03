// IPC (inter-process communication) modules for Aeron
// - ring_buffer: client→driver commands
// - broadcast: driver→client notifications

const agrona = @import("agrona");

pub const ring_buffer = agrona.ring_buffer;
pub const broadcast = agrona.broadcast;
pub const counters = agrona.counters;
pub const idle_strategy = agrona.idle_strategy;
