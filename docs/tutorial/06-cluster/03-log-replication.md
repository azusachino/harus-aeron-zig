# 6.3 Log Replication

## What you'll learn

- How the leader appends entries and replicates to followers
- Quorum-based commit advancement
- Integration with Archive for log persistence

## Background

Once a leader is elected, it accepts client messages and appends them to
the cluster log. Each entry gets a monotonically increasing `log_position`.

The leader sends `AppendRequest` messages to followers, who write entries
to their local log and reply with `AppendPosition` ACKs. When a quorum
of followers have acknowledged a position, the leader advances the
`commit_position` and broadcasts `CommitPosition` to all followers.

### Replication flow

```
Leader                    Follower 1              Follower 2
  |                          |                        |
  |-- AppendRequest(pos=100)->|                        |
  |-- AppendRequest(pos=100)--|----------------------->|
  |<- AppendPosition(100) ---|                        |
  |<- AppendPosition(100) ---|------------------------|
  |   (quorum reached)       |                        |
  |-- CommitPosition(100) -->|                        |
  |-- CommitPosition(100) ---|----------------------->|
```

### Archive integration

Log segments are stored as Archive recordings. This gives durability —
if a node crashes and restarts, it replays the log from the archive
to rebuild state.

## Key types

| Type | Role |
|------|------|
| `ClusterLog` | Leader-side log: append + commit position tracking |
| `LogFollower` | Follower-side: receive appends, send ACKs |
| `LogLeader` | Track follower positions, advance commit on quorum |

## Exercise

Open `tutorial/cluster/log.zig` and implement log replication.

Run `make tutorial-check` to verify.

## Reference

- `src/cluster/log.zig` — reference implementation
- `aeron-cluster/src/main/java/io/aeron/cluster/LogReplication.java`
