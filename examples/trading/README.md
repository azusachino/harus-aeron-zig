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
client smoke. The Java topology can also exercise the Zig client against a real
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
`ReleaseFast`, starts three Java cluster members, and runs the Java-only
baseline client. The default is 500 orders; `TRADING_SOAK_MESSAGES` changes it and
`TRADING_SOAK_START_DELAY_MS` controls the client startup delay (default
5,000 ms). The Java client remains alive for a 30-second grace period by
default (`TRADING_SOAK_HOLD_OPEN_MS`) so the faster client cannot tear down
the cluster while Zig is still draining its orders. Java order IDs start at
`1`, while Zig IDs start at `1_000_001`, so the two clients can run
concurrently without collisions.

The 500-order soak is currently green. A 100,000-order run exercises the
Java-cluster path well past the previous burst-loss boundary:

```bash
TRADING_SOAK_MESSAGES=100000 uv run scripts/trading.py soak --mode java
```

The publisher rotates terms with stream-identifying padding and the sender
follows rotated partitions. The mixed Java/Zig 100,000-order Java-cluster run
previously completed with both `JAVA_CLUSTER_CLIENT_OK responses=100000` and
`ZIG_CLUSTER_CLIENT_OK responses=100000`. The embedded driver now uses a 4 MiB
UDP receive buffer and queues incoming NAKs for sender retransmission; sustained
multi-hour soak evidence is still part of the unreleased 0.9 hardening work.

Both clients report `publish_ms`, `total_ms`, and `orders_per_sec`. Compare
those values only between runs with the same order count and topology.

Current performance evidence on the local host:

| scenario | orders | publish | total | throughput | result |
| --- | ---: | ---: | ---: | ---: | --- |
| Java cluster + Java client | 10,000 | 20 ms | 231 ms | 43,290/s | pass |
| Java cluster + Java client | 100,000 | 126 ms | 731 ms | 136,798/s | pass |
| Java cluster + Zig client | 10,000 | 11,447 ms | 11,528 ms | 867/s | pass, severe slowdown |
| Java cluster + Zig client | 100,000 | not emitted | publish completed, 99,939/100,000 responses | — | fail |

The 100,000-order Zig run completed publishing but stalled with 61 missing
responses despite a 10-minute response deadline. This is an open 0.9
interop/performance gap, not evidence of acceptable parity.

For larger runs, the soak runner gives the Zig client a 10-minute batch offer
deadline and 10 million connect iterations by default. Override
`TRADING_SOAK_OFFER_TIMEOUT_MS`, `TRADING_SOAK_RESPONSE_TIMEOUT_MS`, or
`TRADING_SOAK_CONNECT_MAX_ITERATIONS` when testing a slower host.

Matching rules are deterministic:

1. A bid crosses the lowest resting ask at or below its limit price.
2. An ask crosses the highest resting bid at or above its limit price.
3. Equal-price orders are matched in arrival order.
4. A residual quantity rests on the book.
5. Invalid orders and duplicate order IDs are rejected.
