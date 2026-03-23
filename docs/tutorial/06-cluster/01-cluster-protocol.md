# Chapter 6.1: Cluster Protocol

Aeron Cluster provides Raft-based consensus for high-availability. This chapter covers the message protocol that coordinates a cluster of nodes.

## The Problem

How do you maintain a single consistent "truth" when multiple nodes in a cluster might fail at any time? How can a client be sure that a message was actually committed and replicated to a majority of nodes?

---

## Zig Track: Explicit Padding and Alignment

Cluster messages often involve 64-bit timestamps and positions. When these structs are shared via memory-mapped log buffers, alignment becomes critical for performance and correctness across architectures.

### The `_padding` Field

In Zig, we use `extern struct` to match the C ABI, but we also include explicit `_padding` fields to ensure that all 64-bit fields are aligned to 8-byte boundaries.

```zig
// LESSON(cluster/zig): Using extern structs with explicit _padding fields ensures the 64-bit alignment required for shared memory.
pub const AppendRequestHeader = extern struct {
    leader_ship_term_id: i64,
    log_position: i64,
    timestamp: i64,
    leader_member_id: i32,
    _padding: i32 = 0, // Padding to 8-byte boundary
};
```

This explicit padding avoids "implicit" compiler-inserted space, making the memory layout predictable and identical across all languages.

---

## Aeron Track: Consensus and Replication

Aeron Cluster uses the **Raft consensus algorithm** to manage a replicated log. The protocol is divided into three distinct message families:

### 1. Client Messages (MSG_TYPE 201–210)
Used for session lifecycle (`Connect`, `Close`) and routing client messages through the cluster.

### 2. Consensus Messages (MSG_TYPE 211–220)
The heart of the Raft algorithm. These coordinate:
- **Elections**: `RequestVote` and `Vote` headers.
- **Replication**: `AppendRequest` (leader sends data) and `AppendPosition` (follower acknowledges).
- **Commitment**: `CommitPosition` (leader announces that a majority have the data).

### 3. Service Messages (MSG_TYPE 221–230)
Notify the application service that a message has been safely committed and is ready to be processed.

---

## Implementation Walkthrough

- **`src/cluster/protocol.zig`**: Defines the `extern struct` layouts for the 3-family Cluster protocol.
- **`src/cluster/election.zig`**: Implements the Raft leader election state machine.
- **`src/cluster/log.zig`**: Manages the replicated log and commit progress.

## Exercise

1. Open `tutorial/cluster/protocol.zig` and implement the `AppendRequestHeader`.
2. Implement the `VoteHeader` struct, ensuring it has the correct `_padding` for 64-bit fields.
3. Verify with `make tutorial-check`.

Further reading: [Aeron Cluster Specification](https://github.com/aeron-io/aeron/tree/master/aeron-cluster)
