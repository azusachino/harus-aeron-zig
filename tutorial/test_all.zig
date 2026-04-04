// Tutorial test runner
// This file imports all tutorial stubs to verify they compile.

comptime {
    _ = @import("protocol/frame.zig");
    _ = @import("logbuffer/log_buffer.zig");
    _ = @import("logbuffer/metadata.zig");
    _ = @import("logbuffer/term_appender.zig");
    _ = @import("logbuffer/term_reader.zig");
    _ = @import("ipc/ring_buffer.zig");
    _ = @import("ipc/broadcast.zig");
    _ = @import("ipc/counters.zig");
    _ = @import("transport/uri.zig");
    _ = @import("transport/udp_channel.zig");
    _ = @import("transport/endpoint.zig");
    _ = @import("transport/poller.zig");
    _ = @import("driver/media_driver.zig");
    _ = @import("driver/sender.zig");
    _ = @import("driver/receiver.zig");
    _ = @import("driver/conductor.zig");
    _ = @import("driver/cnc.zig");
    _ = @import("publication.zig");
    _ = @import("subscription.zig");
    _ = @import("archive/protocol.zig");
    _ = @import("archive/catalog.zig");
    _ = @import("archive/recorder.zig");
    _ = @import("archive/replayer.zig");
    _ = @import("archive/conductor.zig");
    _ = @import("cluster/protocol.zig");
    _ = @import("cluster/election.zig");
    _ = @import("cluster/log.zig");
}
