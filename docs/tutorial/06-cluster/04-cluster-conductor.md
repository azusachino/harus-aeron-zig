# 6.4 Cluster Conductor

## What you'll learn

- How the cluster conductor manages client sessions
- Message routing: client ingress → leader → committed log → service
- Timer service with deterministic cluster time

## Background

The `ClusterConductor` is the central coordinator for a cluster node.
It manages three interfaces:

1. **Client ingress**: accepts `SessionConnectRequest`, routes messages to leader
2. **Service interface**: delivers committed log entries to `ClusteredService`
3. **Timer service**: schedules timers in cluster time for deterministic replay

### Client session lifecycle

```
Client                    Conductor (Leader)         Service
  |                            |                        |
  |-- SessionConnectRequest -->|                        |
  |<-- SessionEvent(ok) ------|                        |
  |-- SessionMessage -------->|                        |
  |                            |-- (commit via log) --->|
  |                            |<-- ServiceAck ---------|
  |-- SessionCloseRequest --->|                        |
  |<-- SessionEvent(close) ---|                        |
```

### Follower behavior

Followers redirect client connections to the current leader.
They process committed log entries identically to the leader
(deterministic state machine replication).

## Key operations

| Method | What it does |
|--------|-------------|
| `onSessionConnect(req)` | Create client session, send SessionEvent |
| `onSessionMessage(msg)` | Append to cluster log (if leader) |
| `onSessionClose(req)` | Clean up session state |
| `deliverCommittedEntries()` | Send committed entries to service |
| `onServiceAck(ack)` | Track service progress |

## Exercise

Open `tutorial/cluster/conductor.zig` and implement the conductor.

Run `make tutorial-check` to verify.

## Reference

- `src/cluster/conductor.zig` — reference implementation
- `aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModuleAgent.java`
