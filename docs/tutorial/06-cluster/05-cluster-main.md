# 6.5 Cluster Main

## What you'll learn

- How to compose Election + Log + Conductor into a ConsensusModule
- Cluster configuration via `ClusterContext`
- The standalone cluster node binary

## Background

The `ConsensusModule` is the top-level struct that owns all cluster
components: the `Election` state machine, `ClusterLog`, and
`ClusterConductor`. It drives their duty cycles and manages the
overall node lifecycle.

### Configuration

`ClusterContext` specifies everything a node needs to join a cluster:

| Field | Default | Purpose |
|-------|---------|---------|
| `member_id` | — | This node's unique ID |
| `cluster_members` | — | All member configs (id, host, ports) |
| `ingress_channel` | `aeron:udp?endpoint=localhost:9010` | Client ingress |
| `log_channel` | `aeron:udp?endpoint=localhost:9020` | Log replication |
| `consensus_channel` | `aeron:udp?endpoint=localhost:9030` | Election/consensus |

### Integration test

The ultimate test: spin up 3 cluster nodes (embedded), elect a leader,
send 1000 messages, kill the leader, verify new election completes and
all messages are committed correctly.

## Exercise

Open `tutorial/cluster/cluster.zig` and implement:

1. `ClusterContext` with member configuration
2. `ConsensusModule` with init/deinit/doWork
3. Integration test with 3-node cluster

Run `make tutorial-check` to verify.

## Reference

- `src/cluster/cluster.zig` — reference implementation
- `aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModule.java`
