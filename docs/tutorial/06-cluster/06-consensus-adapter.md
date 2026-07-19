# Java consensus adapter

The reference implementation separates Java Aeron Cluster's SBE consensus
frames from the election state machine. The exercise is to decode schema 111,
dispatch templates 50-57, and map RequestVote/Vote messages without putting
network or Compose policy into the adapter.

Reference implementation: `src/cluster/aeron_consensus_adapter.zig`.
