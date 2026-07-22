const std = @import("std");

test {
    _ = @import("election_test.zig");
    _ = @import("failover_test.zig");
    _ = @import("log_replication_test.zig");
    _ = @import("snapshot_stress_test.zig");
    _ = @import("client_protocol_test.zig");
    _ = @import("aeron_consensus_codecs_test.zig");
    _ = @import("aeron_consensus_adapter_test.zig");
}
