# 6.1 Cluster Protocol

## What you'll learn

- The three message families in Aeron Cluster: client-facing, consensus, and service
- How Raft consensus messages map to `extern struct` codec types
- The relationship between leadership terms, log positions, and member IDs

## Background

Aeron Cluster implements Raft-based consensus for state machine replication.
The protocol has three distinct message families:

| Family | Direction | MSG_TYPE_ID range | Purpose |
|--------|-----------|-------------------|---------|
| Client | Client ↔ Cluster | 201–210 | Session management, message routing |
| Consensus | Node ↔ Node | 211–220 | Leader election, log replication, commit |
| Service | Cluster → Service | 221–230 | Committed log delivery, snapshots |

### Key Raft concepts in the protocol

- **Leadership term** (`leader_ship_term_id`): monotonically increasing epoch number
- **Log position** (`log_position`): byte offset in the replicated log
- **Member ID** (`member_id`): unique node identifier within the cluster
- **Candidate term** (`candidate_term_id`): term proposed during an election

## Message catalog

### Client-facing
| Struct | Fields | Purpose |
|--------|--------|---------|
| `SessionConnectRequest` | correlation_id, cluster_session_id, response_stream_id | Client connects to cluster |
| `SessionCloseRequest` | cluster_session_id, leader_ship_term_id | Client disconnects |
| `SessionMessageHeader` | cluster_session_id, timestamp, correlation_id | Wraps client messages |
| `SessionEvent` | cluster_session_id, correlation_id, leader_ship_term_id, event_code | Cluster notifications |

### Consensus (Raft)
| Struct | Fields | Purpose |
|--------|--------|---------|
| `RequestVoteHeader` | candidate_term_id, log_position, candidate_member_id | Raft vote request |
| `VoteHeader` | candidate_term_id, candidate_member_id, follower_member_id, vote | Raft vote response |
| `AppendRequestHeader` | leader_ship_term_id, log_position, timestamp, leader_member_id | Log append from leader |
| `AppendPositionHeader` | leader_ship_term_id, log_position, follower_member_id | Follower ACK |
| `CommitPositionHeader` | leader_ship_term_id, log_position, leader_member_id | Leader commit broadcast |
| `NewLeadershipTermHeader` | leader_ship_term_id, log_position, leader_member_id | Term transition |

### Service
| Struct | Fields | Purpose |
|--------|--------|---------|
| `ServiceAck` | log_position, timestamp, service_id | Service acknowledges committed entry |

## Exercise

Open `tutorial/cluster/protocol.zig` and implement all message types.

Run `make tutorial-check` to verify.

## Reference

- `src/cluster/protocol.zig` — reference implementation
- `aeron-cluster/src/main/java/io/aeron/cluster/codecs/` — upstream Java SBE codecs
