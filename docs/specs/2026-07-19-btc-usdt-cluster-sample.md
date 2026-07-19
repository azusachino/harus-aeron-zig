# BTC_USDT three-cluster sample

This sample is a cluster exercise, not a pub/sub showcase. It uses one fixed
instrument, `BTC_USDT`, so every implementation can be checked against the
same deterministic order stream and book state.

## Required deployments

Each mode is a three-member cluster plus clients:

| Mode | Members | Clients | Purpose |
| --- | --- | --- | --- |
| `zig` | three Zig cluster nodes | Zig and Java clients | validate the Zig cluster process boundary |
| `java` | three Java Aeron Cluster nodes | Java and Zig clients | validate against upstream Aeron Cluster (baseline now green) |
| `mixed` | two Java members and one Zig consensus/log observer | Java and Zig clients | prove consensus/log ingress and client interoperability; full service/replay parity remains open |

The mixed mode is the acceptance target. Its current smoke proves Java/Zig
consensus/log-stream exchange and client traffic through the Java leader. The
Zig member journals received Java log frames and survives a member restart. A Java
client talking to a standalone Zig MediaDriver is only a lower-level
prerequisite; it is not full mixed-cluster evidence.

## Client flow

Clients submit an ordered event stream:

```text
BTC_USDT|order_id|side|price_ticks|quantity
```

The cluster service applies events in log order and emits execution results.
Clients assert:

- the same leader is observed by all clients;
- committed order positions are monotonic;
- each implementation produces the same fills and residual book;
- a leader failure causes a new leader to accept orders;
- replay after restart reproduces the exact `BTC_USDT` book.

The first scenario uses three orders: an ask at `10100`, a crossing bid at
`10100`, and a non-crossing bid at `10050`. Evil and edge scenarios add an
invalid order, a duplicate ID, a wrong symbol, a zero quantity, and a leader
failure between append and commit.

## Java baseline evidence

The Java baseline is implemented under `examples/trading/java/` and runs with
the split Compose files under `deploy/trading/`. It uses the authentic
`aeron-all` artifact built from the vendored `vendor/aeron` source,
`ClusteredMediaDriver`,
`ClusteredServiceContainer`, and `AeronCluster`.

The verified smoke result is three ready members and three client responses:

```text
JAVA_CLIENT BTC_USDT|1|FILLED|0|RESTING|10
JAVA_CLIENT BTC_USDT|2|FILLED|4|RESTING|0
JAVA_CLIENT BTC_USDT|3|FILLED|0|RESTING|8
JAVA_CLUSTER_CLIENT_OK responses=3
```

The baseline required these concrete fixes: Java 21 module opens for Agrona,
explicit Archive control and replication channels, delimiter-preserving
`CLUSTER_MEMBERS`, a local client MediaDriver, a matching Aeron directory, and
a routable client egress hostname.

## Current implementation boundary

The repository's Zig `--cluster` entrypoint still owns one local
`ConsensusModule`, and `examples/cluster_demo.zig` remains an in-process
simulation. The trading sample now also has a networked three-process Zig
topology (`zig_cluster_node.zig`) that speaks the Java-compatible client
session/egress protocol and passes Java/Zig client smokes. It deliberately uses
a fixed leader and a local order book backed by an append-only journal. Peer
publications and internal heartbeat/order framing are wired. The source-aware receiver path has now been
verified with a three-member smoke: node 1 becomes leader after node 0 stops,
node 2 follows node 1's heartbeat, and replicated orders are observed on node
2. This is deterministic sample-level failover, not Raft/consensus parity.
Each Zig member now persists accepted order inputs into a real Aeron Archive
recording under `/data/archive` on its named Compose volume (catalog +
segmented `.dat` files, not a private flat file) and replays it before
`ZIG_CLUSTER_READY`; a restart proof restored six replicated orders on member
1. Members also take periodic Archive-backed snapshots of book + log state,
so restart replay only needs to cover order recordings newer than the latest
snapshot rather than the full order history, and crash recovery (no graceful
shutdown) still replays durably-written orders by reading the still-open
recording's real on-disk size. The three-process smoke does support multiple concurrent client
sessions and follower-to-leader redirect. The Java Compose topology remains the
upstream reference; mixed mode now has a consensus/client smoke, while Zig
member-to-member log application, catchup, archive, ingress ownership, and
replay boundaries remain open. The exact SBE/member-protocol gap is recorded in
`docs/investigations/2026-07-19-mixed-cluster-boundary.md`.

Run the orchestration planner with:

```bash
uv run scripts/trading.py plan
```

The pure-Zig durable replay gate is:

```bash
TRADING_SOAK_MESSAGES=3 uv run scripts/trading.py replay-proof --mode zig
```

The runner restarts member 1 without removing its named volume and requires
`ZIG_CLUSTER_REPLAY member=1 orders=6` before it passes. This proves Archive-
backed durable replay across a restart, including the still-open recording
case where no graceful shutdown ran.

Once a topology is real, use `--mode zig`, `--mode java`, or `--mode mixed`
with `config`, `up`, and `down`.
