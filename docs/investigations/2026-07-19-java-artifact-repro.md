# Local Java Aeron Artifact Reproducibility

The Java cluster sample uses the authentic Aeron sources already vendored at
`vendor/aeron`, not a Maven URL and not a jar downloaded during every Compose
build.

The preparation path is:

```text
uv run scripts/trading.py ensure-java-artifact
  -> test/interop/aeron-all.jar (no-op when cached)
  -> vendor/aeron/gradlew aeron-all:jar --no-daemon (only when cache is absent)
  -> copy the generated jar into test/interop/aeron-all.jar
  -> Compose build context
  -> Containerfile COPY /aeron-all.jar
```

The current local build is `aeron-all-1.50.5-SNAPSHOT.jar`, produced from the
checked-out `release/1.50.x` source. The glob is intentional: the source tree
is the version authority, so the runner does not duplicate a version string
that can drift from the vendored checkout.

`.dockerignore` excludes the vendor tree by default and allows only the stable
cache into the Compose build context. This keeps source and unrelated Gradle
output out of the image build while retaining a completely local, offline
artifact after the first preparation.

Verification:

```bash
uv run scripts/trading.py ensure-java-artifact
COMPOSE=podman-compose uv run scripts/trading.py config --mode java
```

The first command is a no-op when `test/interop/aeron-all.jar` exists. Removing
the cache requires rebuilding it from the vendored source; normal repeated
test, smoke, and soak runs do not download or rebuild it.

## Runtime evidence captured with the cached artifact

The official Java baseline completed 10,000 orders in 167 ms on a fresh
three-member cluster (`59,880 orders/sec`). After fixing stale committed frames
in reused term partitions, the Zig client completed 10,000 orders in 225 ms
(`44,444 orders/sec`) against a fresh three-member Java cluster. The run had
valid egress payloads and no zero-filled frames; the sender skipped stale
partition frames instead of transmitting them, and NAK recovery advanced the
Java receiver. This is the 0.9 10k parity gate, not a 1.0 maturity claim.

The next bounded gate also passed on 2026-07-19 using a fresh cluster project,
one active `aeron-trading` alias set, and a 5-second client startup delay:

| client | orders | publish | total | throughput | result |
| --- | ---: | ---: | ---: | ---: | --- |
| Java | 100,000 | 69 ms | 438 ms | 228,310/s | 100,000 responses |
| Zig | 100,000 | 1,724 ms | 1,726 ms | 57,937/s | 100,000 responses |

The reproducible shape of the Zig run is:

```bash
COMPOSE=podman-compose \
  podman-compose -p aeron-java-cluster-task2b \
  -f deploy/trading/docker-compose.java-cluster.yml up --build -d

ORDER_COUNT=100000 START_DELAY_MS=5000 \
  CONNECT_TIMEOUT_MS=60000 CONNECT_MAX_ITERATIONS=10000000 \
  OFFER_TIMEOUT_MS=300000 RESPONSE_TIMEOUT_MS=300000 \
  COMPOSE=podman-compose \
  podman-compose -p aeron-java-clients-task2b \
  -f deploy/trading/docker-compose.java.yml run --rm --no-deps zig-client
```

The Java client uses the same cluster and client Compose files with
`ORDER_COUNT=100000` and `QUIET=1`. A client launched before cluster election
readiness can exhaust its connect deadline without a ClusterSession; the
startup delay and explicit timeout above are therefore part of the evidence,
not incidental shell timing.

The checked-in uv runner was then exercised with both clients concurrently:

```bash
TRADING_PROJECT_SUFFIX=task2b \
TRADING_SOAK_MESSAGES=100000 \
TRADING_SOAK_START_DELAY_MS=5000 \
TRADING_SOAK_OFFER_TIMEOUT_MS=300000 \
TRADING_SOAK_RESPONSE_TIMEOUT_MS=300000 \
TRADING_SOAK_CONNECT_MAX_ITERATIONS=10000000 \
COMPOSE=podman-compose uv run scripts/trading.py soak --mode java
```

That run exited zero with Java `100000/100000` responses in `910 ms`
(`109890/s`) and Zig `100000/100000` responses in `2080 ms` (`48076/s`).

The key failure was that the sender treated any positive `frame_length` as
available. A recycled partition still contains old committed frames, so the
sender could transmit term-0 data at a term-3 position. The sender now requires
both the expected term ID and term offset before sending, with a regression test
covering the stale-partition case.

The cluster Compose file uses persistent node volumes. For a reproducible
fresh run, use one project/network alias set at a time; multiple Compose
projects publishing the same `java-node-*` aliases on `aeron-trading` can
cross-connect clients to different clusters. Use a new project name to
preserve old volumes while obtaining a clean data set.

## Pure-Zig three-member failover evidence

The same local binary/cache workflow was used for the Zig cluster sample on
2026-07-19:

```text
node 0 stopped after the initial leader heartbeat
node 1 -> ZIG_CLUSTER_LEADER_CHANGE ... leader=1
node 2 -> ZIG_CLUSTER_LEADER_CHANGE ... leader=1 source=heartbeat
node 2 -> ZIG_CLUSTER_INTERNAL_RX ... kind=order source=1 count=1..3
```

With node 0 unavailable, both the Java and Zig clients completed three orders
through the endpoint retry list. This validates source-aware peer images,
leader-heartbeat propagation, and order replication for the sample. It does
not validate durable consensus, replay, snapshots, or a mixed Java/Zig member
topology.
