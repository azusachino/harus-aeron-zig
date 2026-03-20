# 6.2 Raft Election

## What you'll learn

- How Raft leader election works as a state machine
- Quorum calculation and vote granting rules
- Timeout-driven state transitions

## Background

Aeron Cluster uses a Raft-inspired election protocol. Each node runs an
`Election` state machine that transitions through these states:

```
INIT → CANVASS → CANDIDATE_BALLOT → LEADER_READY
                                   ↘ (timeout) → CANVASS
                 ↘ (vote granted) → FOLLOWER_BALLOT → FOLLOWER_READY
```

### Election rules (from Raft)

1. **Term monotonicity**: a node only votes for candidates with term ≥ its own
2. **Log completeness**: a node only votes for candidates whose log is at least as up-to-date
3. **Quorum**: a candidate needs `(cluster_size / 2) + 1` votes to become leader
4. **Single vote per term**: each node grants at most one vote per term
5. **Timeout randomization**: prevents split votes (simplified here to fixed timeout)

### State descriptions

| State | What happens |
|-------|-------------|
| `init` | Initial state, immediately transitions to canvass |
| `canvass` | Waits for election timeout, then starts ballot |
| `candidate_ballot` | Votes for self, solicits votes, waits for quorum |
| `follower_ballot` | Voted for another candidate, waiting for outcome |
| `leader_log_replication` | Won election, replicating log (transient) |
| `leader_ready` | Stable leader state |
| `follower_ready` | Stable follower state |

## Exercise

Open `tutorial/cluster/election.zig` and implement:

1. `ElectionState` enum and `MemberState` struct
2. `Election` struct with state machine logic in `doWork()`
3. Vote handling: `onRequestVote()`, `onVote()`
4. Leadership acceptance: `onNewLeadershipTerm()`
5. Quorum calculation

Test with a 3-node election simulation.

Run `make tutorial-check` to verify.

## Reference

- `src/cluster/election.zig` — reference implementation
- `aeron-cluster/src/main/java/io/aeron/cluster/Election.java`
- Raft paper: https://raft.github.io/raft.pdf
