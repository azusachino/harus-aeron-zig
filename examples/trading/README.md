# BTC_USDT cluster samples

These samples model one instrument only: `BTC_USDT`.

The order event shape is intentionally small and language-neutral:

```text
BTC_USDT|order_id|side|price_ticks|quantity
```

`side` is `BID` or `ASK`. Prices and quantities are positive integer ticks,
so the example has no floating-point behavior to hide in cross-language tests.

The intended deployments are three-member clusters, each with external
clients:

- `zig`: three Zig cluster members plus Zig and Java clients.
- `java`: three upstream Java Aeron Cluster members plus Java and Zig clients.
- `mixed`: two Java members and one Zig member plus both client languages.

The Java files now include a working three-member Aeron Cluster baseline and
client smoke. The Java topology also exercises the Zig client against a real
Java cluster, including the follower-to-leader redirect. Zig and mixed remain
blocked until their three-process cluster topologies and client failover
assertions exist. See
`docs/specs/2026-07-19-btc-usdt-cluster-sample.md` for the acceptance matrix.

Run the baseline tests with `uv run scripts/trading.py test --mode java` and
run the sustained Java-cluster smoke with:

```bash
uv run scripts/trading.py soak --mode java
```

`soak` clears stale Compose containers, builds the Zig examples as
`ReleaseFast`, starts three Java cluster members, and runs both Java and Zig
clients. The default is 500 orders; `TRADING_SOAK_MESSAGES` changes it and
`TRADING_SOAK_START_DELAY_MS` controls the client startup delay (default
5,000 ms). The Java client remains alive for a 30-second grace period by
default (`TRADING_SOAK_HOLD_OPEN_MS`) so the faster client cannot tear down
the cluster while Zig is still draining its orders. Java order IDs start at
`1`, while Zig IDs start at `1_000_001`, so the two clients can run
concurrently without collisions.

The 500-order soak is currently green. A 2,100-order run exercises the
Java-cluster path past the previous burst-loss boundary:

```bash
TRADING_SOAK_MESSAGES=2100 uv run scripts/trading.py soak --mode java
```

The publisher rotates terms with stream-identifying padding and the sender
follows rotated partitions. The mixed Java/Zig 2,100-order Java-cluster run
completes with both `JAVA_CLUSTER_CLIENT_OK responses=2100` and
`ZIG_CLUSTER_CLIENT_OK responses=2100`. The embedded driver now uses a 4 MiB
UDP receive buffer and queues incoming NAKs for sender retransmission; sustained
multi-hour soak evidence is still part of the unreleased 0.9 hardening work.

Matching rules are deterministic:

1. A bid crosses the lowest resting ask at or below its limit price.
2. An ask crosses the highest resting bid at or above its limit price.
3. Equal-price orders are matched in arrival order.
4. A residual quantity rests on the book.
5. Invalid orders and duplicate order IDs are rejected.
