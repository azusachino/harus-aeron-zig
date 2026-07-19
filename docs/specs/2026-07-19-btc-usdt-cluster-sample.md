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
| `mixed` | two Java members and one Zig member | Java and Zig clients | prove wire-compatible election, log, snapshot, and client behavior |

The mixed mode is the acceptance target. A Java client talking to a Zig
MediaDriver is only a lower-level prerequisite; it is not cluster evidence.

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
`deploy/trading/docker-compose.java.yml`. It uses `aeron-all` 1.50.4 from the
vendored-compatible Maven artifact, `ClusteredMediaDriver`,
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

The repository's Zig `--cluster` entrypoint currently owns one local
`ConsensusModule`, and `examples/cluster_demo.zig` simulates three nodes with
direct calls. Neither is yet a networked three-process cluster. The Java
Compose topology is the working reference; Zig and mixed Compose files remain
blocked until the Zig cluster transport, archive/replay boundary, and
Java-compatible cluster protocol are implemented.

Run the orchestration planner with:

```bash
uv run scripts/trading.py plan
```

Once a topology is real, use `--mode zig`, `--mode java`, or `--mode mixed`
with `config`, `up`, and `down`.
